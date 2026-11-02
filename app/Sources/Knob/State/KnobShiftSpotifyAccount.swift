import Foundation

/// The logged in Spotify account: its name and its playlists, read straight from Spotify's Web
/// API with the login spotDL saved (scope playlist-read-private), so listing a few hundred
/// playlists takes a second instead of a spotDL run. The token is refreshed the way spotDL's own
/// Spotify library does it and written back to the same file, so both keep working.
enum KnobShiftSpotifyAccount {
    struct Playlist: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let songs: Int
        let owner: String?
        var link: String { "https://open.spotify.com/playlist/\(id)" }
    }

    struct Account: Equatable, Sendable {
        let name: String?
        let playlists: [Playlist]
    }

    enum Problem: Error, Equatable {
        case loggedOut, offline, rateLimited, failed
    }

    /// Reads the account's name and every playlist it owns or follows, page by page.
    static func load(session: URLSession = .shared) async throws -> Account {
        var token = try await validToken(session: session)
        var name: String?
        if let me: Me = try? await get("https://api.spotify.com/v1/me", token: &token, session: session) {
            name = me.display_name
        }
        var playlists: [Playlist] = []
        var next: String? = "https://api.spotify.com/v1/me/playlists?limit=50"
        var pages = 0
        while let url = next, pages < 100 {
            let page: Page = try await get(url, token: &token, session: session)
            playlists += page.items.compactMap { item in
                guard let item, let id = item.id, let title = item.name else { return nil }
                return Playlist(id: id, name: title, songs: item.tracks?.total ?? item.items?.total ?? 0,
                                owner: item.owner?.display_name)
            }
            next = page.next
            pages += 1
        }
        return Account(name: name, playlists: playlists)
    }

    // MARK: Spotify's daily limit

    /// Spotify answers QUOTA_EXCEEDED with a wait of up to a day once the Spotify key Knob uses
    /// (spotDL's own, shared by everyone who uses spotDL) has used its requests up. spotDL then
    /// sleeps through the whole wait without a word, so Knob asks Spotify first and remembers.
    nonisolated(unsafe) private static var paused: Date?

    /// When Spotify allows requests again, or nil when it allows them now (or the check fails,
    /// in which case spotDL tries anyway and reports what it finds).
    static func pausedUntil(userAuth: Bool, session: URLSession = .shared) async -> Date? {
        if let paused, paused > Date() { return paused }
        let token: String?
        if userAuth, let user = try? await validToken(session: session) {
            token = user.access_token
        } else {
            token = try? await appToken(session: session)
        }
        guard let token, let url = URL(string: "https://api.spotify.com/v1/markets") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await send(request, session: session) else { return nil }
        notePause(response)
        return paused.flatMap { $0 > Date() ? $0 : nil }
    }

    /// Remembers a long wait Spotify asked for; short waits are only retried.
    private static func notePause(_ response: HTTPURLResponse) {
        guard response.statusCode == 429,
              let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? ""), wait > 60 else { return }
        paused = Date().addingTimeInterval(wait)
    }

    /// The sentence for the player while Spotify is paused, with when it opens again.
    static var pausedMessage: String {
        guard let paused, paused > Date() else { return "Spotify is busy. Try again in a minute." }
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(paused) ? "h:mm a" : "EEEE h:mm a"
        let when = "Try again after \(clock.string(from: paused))"
        return hasOwnKey ? "Spotify has paused requests from your key. \(when)."
            : "Spotify has paused the shared key for now. \(when), or add your own key below."
    }

    // MARK: Your own key

    /// spotDL's own Spotify key, shared by everyone who uses spotDL.
    private static let sharedClientId = "5f573c9620494bae87890c0f08a60293"

    /// True when spotDL uses a key of the person's own instead of the shared one.
    static var hasOwnKey: Bool {
        guard let id = config()["client_id"] as? String else { return false }
        return !id.isEmpty && id != sharedClientId
    }

    enum KeyProblem: Error { case wrong, offline, failed }

    /// Checks a Client ID and secret with Spotify, then saves them where spotDL reads them.
    /// Spotify answers 400 or 401 for a key that is not right.
    static func saveOwnKey(id: String, secret: String, session: URLSession = .shared) async throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 32, secret.count == 32, id.allSatisfy(\.isHexDigit), secret.allSatisfy(\.isHexDigit) else {
            throw KeyProblem.wrong
        }
        do {
            _ = try await appToken(session: session, id: id, secret: secret)
        } catch Problem.offline {
            throw KeyProblem.offline
        } catch Problem.loggedOut {
            throw KeyProblem.wrong
        } catch {
            throw KeyProblem.failed
        }
        try writeKey(id: id, secret: secret)
    }

    /// Goes back to the shared key: spotDL falls back to its own when the file names none.
    static func removeOwnKey() throws {
        try writeKey(id: nil, secret: nil)
    }

    private static func config() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]) ?? [:]
    }

    /// Updates only the key in spotDL's settings, keeping everything else as it was. A new
    /// file gets load_config, without which spotDL ignores it.
    private static func writeKey(id: String?, secret: String?) throws {
        var settings = config()
        if settings.isEmpty { settings["load_config"] = true }
        settings["client_id"] = id
        settings["client_secret"] = secret
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        paused = nil
    }

    /// A token for the app itself, for public lists when nobody is logged in, as spotDL gets one.
    private static func appToken(session: URLSession, id: String? = nil, secret: String? = nil) async throws -> String {
        let settings = config()
        guard let clientId = id ?? settings["client_id"] as? String, let secret = secret ?? settings["client_secret"] as? String else {
            throw Problem.failed
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Basic " + Data("\(clientId):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, response) = try await send(request, session: session)
        if response.statusCode == 400 || response.statusCode == 401 { throw Problem.loggedOut }
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else { throw Problem.failed }
        return token
    }

    // MARK: Spotify's answers

    private struct Me: Decodable { let display_name: String? }
    private struct Page: Decodable {
        let items: [Item?]
        let next: String?
    }
    private struct Item: Decodable {
        struct Count: Decodable { let total: Int? }
        struct Owner: Decodable { let display_name: String? }
        let id: String?
        let name: String?
        let tracks: Count?
        let items: Count?
        let owner: Owner?
    }

    // MARK: Token

    private struct Token: Codable {
        var access_token: String
        var token_type: String?
        var expires_in: Int?
        var scope: String?
        var expires_at: Double
        var refresh_token: String?
    }

    private static var tokenURL: URL { KnobShiftSpotDL.home.appendingPathComponent(".spotdl/.spotipy") }
    private static var configURL: URL { KnobShiftSpotDL.home.appendingPathComponent(".spotdl/config.json") }

    private static func validToken(session: URLSession) async throws -> Token {
        guard let data = try? Data(contentsOf: tokenURL), let token = try? JSONDecoder().decode(Token.self, from: data) else {
            throw Problem.loggedOut
        }
        if token.expires_at - Date().timeIntervalSince1970 > 60 { return token }
        return try await refresh(token, session: session)
    }

    private static func refresh(_ old: Token, session: URLSession) async throws -> Token {
        guard let refreshToken = old.refresh_token,
              let config = try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              let clientId = config["client_id"] as? String, let secret = config["client_secret"] as? String else {
            throw Problem.loggedOut
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Basic " + Data("\(clientId):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await send(request, session: session)
        guard response.statusCode == 200, var token = try? JSONDecoder().decode(Token.self, from: addExpiry(data)) else {
            throw response.statusCode == 400 || response.statusCode == 401 ? Problem.loggedOut : Problem.failed
        }
        // Spotify may leave the refresh token out of a refresh; keep the one we had.
        if token.refresh_token == nil { token.refresh_token = refreshToken }
        if let saved = try? JSONEncoder().encode(token) { try? saved.write(to: tokenURL, options: .atomic) }
        return token
    }

    /// Spotify answers with expires_in; spotipy's file also needs expires_at.
    private static func addExpiry(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let seconds = (object["expires_in"] as? Double) ?? 3600
        object["expires_at"] = Date().timeIntervalSince1970 + seconds
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private static func get<T: Decodable>(_ address: String, token: inout Token, session: URLSession) async throws -> T {
        guard let url = URL(string: address) else { throw Problem.failed }
        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request, session: session)
            switch response.statusCode {
            case 200:
                guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw Problem.failed }
                return value
            case 401 where attempt == 0:
                token = try await refresh(token, session: session)
            case 429:
                // Spotify says how long to wait; wait up to 10 seconds, otherwise give up politely.
                notePause(response)
                let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                guard wait <= 10, attempt < 2 else { throw Problem.rateLimited }
                try await Task.sleep(for: .seconds(wait))
            case 401, 403:
                throw Problem.loggedOut
            default:
                throw Problem.failed
            }
        }
        throw Problem.failed
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Problem.failed }
            return (data, http)
        } catch let problem as Problem {
            throw problem
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Problem.offline
        }
    }
}
