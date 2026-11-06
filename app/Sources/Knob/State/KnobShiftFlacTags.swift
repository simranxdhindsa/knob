import Foundation

/// The names and cover inside FLAC files. Apple's players read their sound but not these, so
/// downloaded songs would show no cover without this.
enum KnobShiftFlacTags {
    struct Found: Equatable {
        var comments: [String: [String]] = [:]
        var cover: Data?

        func all(_ key: String) -> [String] { comments[key] ?? [] }
    }

    /// Tags and covers sit before the sound, so this much of a file is plenty, and a damaged
    /// file that claims to hold more is never read whole.
    private static let longestHeader = 16_000_000
    private static let commentBlock: UInt8 = 4
    private static let pictureBlock: UInt8 = 6
    private static let frontCover: UInt32 = 3

    static func isFlac(_ url: URL) -> Bool { url.pathExtension.lowercased() == "flac" }

    static func read(_ url: URL) -> Found? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: longestHeader) else { return nil }
        return parse([UInt8](data))
    }

    /// A FLAC file opens with blocks of one byte for the type, three for the size, then the
    /// block. A block cut off by the end of the data ends the search, keeping what came before.
    static func parse(_ bytes: [UInt8]) -> Found? {
        guard bytes.starts(with: Array("fLaC".utf8)) else { return nil }
        var found = Found()
        var covers: [(type: UInt32, data: Data)] = []
        var offset = 4
        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let size = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            guard size <= bytes.count - start else { break }
            let block = Array(bytes[start..<(start + size)])
            switch header & 0x7F {
            case commentBlock: readComments(block, into: &found)
            case pictureBlock: if let cover = picture(in: block) { covers.append(cover) }
            default: break
            }
            if header & 0x80 != 0 { break }
            offset = start + size
        }
        found.cover = (covers.first { $0.type == frontCover } ?? covers.first)?.data
        return found
    }

    private static func readComments(_ block: [UInt8], into found: inout Found) {
        var reader = Reader(bytes: block)
        guard let vendor = reader.littleEndian(), reader.skip(vendor), let count = reader.littleEndian() else { return }
        for _ in 0..<count {
            guard let size = reader.littleEndian(), let text = reader.take(size) else { return }
            guard let equals = text.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: text[..<equals], as: UTF8.self).uppercased()
            found.comments[key, default: []].append(String(decoding: text[(equals + 1)...], as: UTF8.self))
        }
    }

    /// Picture type, mime type, description, four sizes, then the image.
    private static func picture(in block: [UInt8]) -> (type: UInt32, data: Data)? {
        var reader = Reader(bytes: block)
        guard let type = reader.bigEndian(), let mime = reader.bigEndian(), reader.skip(mime),
              let description = reader.bigEndian(), reader.skip(description), reader.skip(16),
              let size = reader.bigEndian(), let image = reader.take(size), !image.isEmpty else { return nil }
        return (type, Data(image))
    }

    /// Steps through bytes from a file, refusing to run past the end whatever the file claims.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: UInt32) -> ArraySlice<UInt8>? {
            let size = Int(count)
            guard size <= bytes.count - offset else { return nil }
            defer { offset += size }
            return bytes[offset..<(offset + size)]
        }

        mutating func skip(_ count: UInt32) -> Bool { take(count) != nil }

        mutating func littleEndian() -> UInt32? { take(4)?.reversed().reduce(0) { $0 << 8 | UInt32($1) } }

        mutating func bigEndian() -> UInt32? { take(4)?.reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
