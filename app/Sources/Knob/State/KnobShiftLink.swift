import Foundation
import Network

/// The link between Knob on the Mac and Knob on the iPhone, over the home Wi-Fi. The Mac
/// (KnobShiftLinkServer.swift) offers its Spotify and YouTube playlists and their downloaded
/// songs; the iPhone (ios/Sources/PhoneMacLink.swift) finds it with Bonjour, reads the list,
/// copies the songs it is missing, and can hand the Mac a link to download. iPhone apps cannot
/// run the Mac's download helpers, so the Mac does the downloading and the iPhone the playing.
///
/// The wire is plain HTTP/1.1 with one request per connection, small enough to read here in full.
enum KnobShiftLink {
    /// The Bonjour service both apps use (Info.plist NSBonjourServices on the iPhone).
    static let service = "_knobshift._tcp"
    /// Bumped when the messages change in a way the other side cannot read.
    static let version = 1
    /// Requests are a line, a few headers and at most a pasted link: anything bigger is refused.
    static let requestLimit = 16 * 1024

    /// Everything the Mac has to offer, for one sync.
    struct Library: Codable, Equatable {
        var version: Int
        /// The Mac's name, shown on the iPhone ("Simran's MacBook Pro").
        var mac: String
        var playlists: [Entry]

        struct Entry: Codable, Equatable {
            var playlist: KnobShiftPlaylist
            /// The playlist's songs in its order: downloaded ones with their file, the rest still
            /// on their way on the Mac.
            var songs: [Song]
            /// The Mac is still downloading songs of this playlist.
            var downloading: Bool
        }

        struct Song: Codable, Equatable {
            var id: String
            /// The file's name in the Mac's playlist folder, once it is downloaded.
            var file: String?
            var size: Int64?
            var name: String?
            var artist: String?
            /// Why the Mac could not get it ("YouTube paused"), so it is not shown as on its way.
            var problem: String? = nil
        }
    }

    struct AddRequest: Codable { var link: String }
    struct AddReply: Codable {
        var ok: Bool
        var message: String
        var playlistId: String?
    }

    enum Failure: Error, Equatable {
        case notFound, lost, refused(String), newerMac, olderMac, badReply

        var message: String {
            switch self {
            case .notFound: return "Knob on your Mac was not found. Open Knob on your Mac, on the same Wi-Fi as this iPhone."
            case .lost: return "Lost the connection to your Mac. Songs already copied are kept. Tap Sync to carry on."
            case .refused(let reason): return reason
            case .newerMac: return "Knob on your Mac is newer than this app. Update Knob on your iPhone."
            case .olderMac: return "Knob on your Mac is older than this app. Update Knob on your Mac."
            case .badReply: return "Your Mac sent something this app could not read. Update Knob on both."
            }
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The path that asks the Mac for one song's file. Ids are percent encoded, so a playlist id
    /// like "yt:PL…" travels as one path part.
    static func filePath(playlistId: String, songId: String) -> String {
        "/v1/file/\(encode(playlistId))/\(encode(songId))"
    }

    static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? part
    }

    // MARK: HTTP framing

    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// A whole request from the bytes read so far, or nil while more are needed. Throws for
    /// anything that is not a small, well formed request.
    static func parseRequest(_ data: Data) throws -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > requestLimit { throw Failure.badReply }
            return nil
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw Failure.badReply }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { throw Failure.badReply }
        let headers = parseHeaders(lines)
        let length = Int(headers["content-length"] ?? "0") ?? -1
        let bodyStart = end.upperBound - data.startIndex
        guard length >= 0, bodyStart + length <= requestLimit else { throw Failure.badReply }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    static func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    static func responseHead(status: Int, type: String, length: Int64) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Splits a reply's head from its first body bytes: the status, the length and the rest.
    static func parseResponseHead(_ data: Data) -> (status: Int, length: Int64?, bodyStart: Data)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2, let status = Int(first[1]) else { return nil }
        let length = parseHeaders(lines)["content-length"].flatMap { Int64($0) }
        return (status, length, Data(data[end.upperBound...]))
    }

    // MARK: Who may connect

    /// Only devices on the same home network: private, link local or this machine's own
    /// addresses. Bonjour only reaches the local network, and this keeps it that way.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if address.isLoopback || address.isLinkLocal { return true }
            if (bytes[0] & 0xFE) == 0xFC { return true }
            // An IPv4 address carried in IPv6 (::ffff:a.b.c.d).
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF,
               let v4 = IPv4Address(Data(bytes[12..<16])) {
                return isLocal(.hostPort(host: .ipv4(v4), port: 1))
            }
            return false
        case .name(let name, _):
            return name.hasSuffix(".local") || name == "localhost"
        @unknown default:
            return false
        }
    }
}
