import Foundation

/// Signing in to YouTube the way TV apps do (Google's device flow): Knob shows a short code, the
/// person enters it at google.com/device, and Google gives Knob read only access to their YouTube
/// (scope youtube.readonly). The Google key is the person's own, made once in Google Cloud as a
/// "TVs and Limited Input devices" client, so the same key a TV launcher uses works here too.
/// The key and the sign in live in one file only this Mac user can read, inside Knob's own
/// Application Support folder, like the Spotify key. Nothing is read from any browser.
enum KnobShiftGoogleAuth {
    static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    static let consoleURL = URL(string: "https://console.cloud.google.com/apis/credentials")!

    /// What the sign in shows: enter `userCode` at `verificationURL`.
    struct DeviceCode: Equatable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: Int
        let expiresIn: Int
    }

    enum Problem: Error, Equatable {
        case noKey, badKey, wrongKeyType, denied, expired, signedOut, offline, failed

        /// Plain sentences for the player; no dashes.
        var message: String {
            switch self {
            case .noKey: return "Add your Google key first."
            case .badKey: return "Google did not accept this key. Check the Client ID and the Client secret."
            case .wrongKeyType: return "This key is for another kind of app. Make a key of the type TVs and Limited Input devices."
            case .denied: return "The sign in was turned down on Google's page."
            case .expired: return "The code ran out before it was entered. Sign in again."
            case .signedOut: return "Your YouTube sign in ran out. Sign in with Google again."
            case .offline: return "No internet connection. Try again when you are back online."
            case .failed: return "Signing in with Google did not work. Try again."
            }
        }
    }

    /// One poll of the token endpoint while the person enters the code.
    enum Poll: Equatable {
        case approved(Data), pending, slowDown, failed(Problem)
    }

    // MARK: The key and the sign in

    private struct Stored: Codable {
        var clientId: String
        var clientSecret: String
        var refreshToken: String?
        var signedAt: Date?
    }

    /// Beside yt-dlp's folder, not inside it, so yt-dlp never sees the sign in.
    static var file: URL { KnobShiftYouTube.home.deletingLastPathComponent().appendingPathComponent("google-youtube.json") }

    private static func stored() -> Stored? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// Written to a new private file, then moved into place, so the file is never readable by others.
    private static func write(_ value: Stored?) throws {
        guard let value else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = file.deletingLastPathComponent().appendingPathComponent("google-\(UUID().uuidString).json")
        // Gone after a successful move; removed here when anything fails, so no copy is left behind.
        defer { try? FileManager.default.removeItem(at: fresh) }
        guard FileManager.default.createFile(atPath: fresh.path, contents: try JSONEncoder().encode(value),
                                             attributes: [.posixPermissions: 0o600]) else { throw Problem.failed }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: fresh)
        } else {
            try FileManager.default.moveItem(at: fresh, to: file)
        }
    }

    static var hasKey: Bool { stored() != nil }
    static var isSignedIn: Bool { stored()?.refreshToken?.isEmpty == false }

    /// Checks the key with Google (asking for a code, which costs nothing) before keeping it.
    static func saveKey(id: String, secret: String, session: URLSession = .shared) async throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines), secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { throw Problem.badKey }
        _ = try await requestCode(clientId: id, session: session)
        try write(Stored(clientId: id, clientSecret: secret))
    }

    /// Deletes the key and the sign in at once; returns the sign in, for `revoke`.
    static func removeKey() -> String? {
        let refresh = stored()?.refreshToken
        try? write(nil)
        Tokens.shared.set(nil, expiresIn: nil)
        return refresh
    }

    // MARK: Signing in

    /// Asks Google for a code to show.
    static func start(session: URLSession = .shared) async throws -> DeviceCode {
        guard let key = stored() else { throw Problem.noKey }
        return try await requestCode(clientId: key.clientId, session: session)
    }

    private static func requestCode(clientId: String, session: URLSession) async throws -> DeviceCode {
        let (data, _) = try await post("https://oauth2.googleapis.com/device/code",
                                       ["client_id": clientId, "scope": scope], session: session)
        if let code = deviceCode(from: data) { return code }
        throw keyProblem(data) ?? .failed
    }

    /// Waits for the person to enter the code, asking Google every few seconds as it requires.
    /// Throws CancellationError when the task is cancelled.
    static func waitForApproval(_ code: DeviceCode, session: URLSession = .shared) async throws {
        guard let started = stored() else { throw Problem.noKey }
        let until = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = code.interval
        while Date() < until {
            try await Task.sleep(for: .seconds(interval))
            let data: Data
            do {
                (data, _) = try await post("https://oauth2.googleapis.com/token", [
                    "client_id": started.clientId, "client_secret": started.clientSecret, "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ], session: session)
            } catch Problem.offline {
                continue
            }
            switch poll(from: data) {
            case .approved(let token):
                guard let refresh = field("refresh_token", in: token) else { throw Problem.failed }
                // Cancelled, or the key removed or changed while Google answered: the sign in is
                // not kept, and Google is asked to forget it.
                guard !Task.isCancelled, var key = stored(), key.clientId == started.clientId else {
                    _ = try? await post("https://oauth2.googleapis.com/revoke", ["token": refresh], session: session)
                    throw CancellationError()
                }
                key.refreshToken = refresh
                key.signedAt = Date()
                try write(key)
                Tokens.shared.set(field("access_token", in: token), expiresIn: number("expires_in", in: token))
                return
            case .pending: continue
            case .slowDown: interval += 5
            case .failed(let problem): throw problem
            }
        }
        throw Problem.expired
    }

    /// Deletes the sign in here and asks Google to forget it; the key stays. False when Google
    /// could not be told (offline), so the person can remove Knob in their Google account.
    @discardableResult
    static func signOut(session: URLSession = .shared) async -> Bool {
        Tokens.shared.set(nil, expiresIn: nil)
        guard var key = stored(), let refresh = key.refreshToken else { return true }
        key.refreshToken = nil
        key.signedAt = nil
        try? write(key)
        return await revoke(refresh, session: session)
    }

    /// Asks Google to forget a sign in; 400 means it already had.
    static func revoke(_ refresh: String?, session: URLSession = .shared) async -> Bool {
        guard let refresh else { return true }
        let answer = try? await post("https://oauth2.googleapis.com/revoke", ["token": refresh], session: session)
        return answer.map { $0.1 == 200 || $0.1 == 400 } ?? false
    }

    // MARK: Access

    /// The short lived access token kept in memory only.
    final class Tokens: @unchecked Sendable {
        static let shared = Tokens()
        private let lock = NSLock()
        private var token: String?
        private var expires = Date.distantPast

        func set(_ value: String?, expiresIn: Double?) {
            lock.lock(); defer { lock.unlock() }
            token = value
            expires = Date().addingTimeInterval((expiresIn ?? 3600) - 60)
        }

        var current: String? {
            lock.lock(); defer { lock.unlock() }
            return Date() < expires ? token : nil
        }
    }

    /// A valid access token, refreshed when needed. A refused refresh (the person took the access
    /// back, or a test key's sign in ran out after 7 days) signs out and throws `.signedOut`.
    static func accessToken(session: URLSession = .shared) async throws -> String {
        if let token = Tokens.shared.current { return token }
        guard let key = stored(), let refresh = key.refreshToken else { throw Problem.signedOut }
        let (data, _) = try await post("https://oauth2.googleapis.com/token", [
            "client_id": key.clientId, "client_secret": key.clientSecret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ], session: session)
        // Signed out or the key removed while Google answered: the answer is not used.
        guard stored()?.refreshToken == refresh else { throw Problem.signedOut }
        guard let token = field("access_token", in: data) else {
            if field("error", in: data) == "invalid_grant", var current = stored() {
                current.refreshToken = nil
                current.signedAt = nil
                try? write(current)
                throw Problem.signedOut
            }
            throw keyProblem(data) ?? .failed
        }
        Tokens.shared.set(token, expiresIn: number("expires_in", in: data))
        return token
    }

    // MARK: Reading Google's answers

    static func deviceCode(from data: Data) -> DeviceCode? {
        guard let json = object(data), let device = json["device_code"] as? String, let user = json["user_code"] as? String,
              !device.isEmpty, !user.isEmpty else { return nil }
        // Only Google's own device page is opened, whatever the answer says.
        let url = (json["verification_url"] as? String).flatMap(URLComponents.init(string:)).flatMap { page -> URL? in
            guard page.scheme == "https", ["www.google.com", "google.com"].contains(page.host ?? ""), page.port == nil,
                  page.user == nil, page.password == nil, page.path == "/device" else { return nil }
            return URL(string: "https://www.google.com/device")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURL: url ?? URL(string: "https://www.google.com/device")!,
                          interval: max(5, (json["interval"] as? NSNumber)?.intValue ?? 5),
                          expiresIn: min(1800, max(60, (json["expires_in"] as? NSNumber)?.intValue ?? 1800)))
    }

    static func poll(from data: Data) -> Poll {
        if field("refresh_token", in: data) != nil { return .approved(data) }
        switch field("error", in: data) {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .failed(.denied)
        case "expired_token": return .failed(.expired)
        default: return .failed(keyProblem(data) ?? .failed)
        }
    }

    /// A problem with the key itself, from Google's error answer.
    static func keyProblem(_ data: Data) -> Problem? {
        let error = field("error", in: data) ?? ""
        let description = (field("error_description", in: data) ?? "").lowercased()
        if description.contains("client type") || error == "unauthorized_client" { return .wrongKeyType }
        if error == "invalid_client" || error == "deleted_client" { return .badKey }
        return nil
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func field(_ name: String, in data: Data) -> String? {
        (object(data)?[name] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func number(_ name: String, in data: Data) -> Double? {
        (object(data)?[name] as? NSNumber)?.doubleValue
    }

    // MARK: Requests

    /// A form POST; Google's answer, error bodies included (the device flow reports a code still
    /// waiting as an error).
    static func post(_ address: String, _ form: [String: String], session: URLSession) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(form).utf8)
        return try await send(request, session: session)
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { key in
            "\(key)=\(form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Problem.offline
        }
    }
}
