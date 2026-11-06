import Darwin
import Foundation

/// Listen Together: one Knob plays and sends its finished mix over the Wi-Fi, and every Knob
/// listening plays it at the same moment. This file is the wire between them, with no I/O, so it
/// can be tested on its own.
///
/// One TCP connection per listener carries framed messages: four bytes of length, one of type,
/// then the body. Clock pings go over UDP (KnobShiftTogetherClock.swift), because a ping stuck
/// behind sound or a lost packet resent by TCP would make the clock look further away than it is.
enum KnobShiftTogether {
    /// The Bonjour service (Info.plist NSBonjourServices on the iPhone).
    static let service = "_knobtogether._tcp"
    /// Bumped when the messages change in a way the other side cannot read.
    static let version = 1
    static let mostListeners = 8
    /// How long after leaving the mix a sample reaches the speakers on every device. Measured
    /// Wi-Fi replies vary by up to 120 ms, so this leaves room for a bad moment.
    static let delay: TimeInterval = 0.5

    /// Sound travels at half level and every device turns it back up. Two loud songs in a mix add
    /// up past full scale: Jee Karuga into No Luck clipped 3,127 samples without this, which
    /// sounded crushed, while playing straight from the decks keeps those peaks.
    static let headroom: Float = 0.5

    /// Anything longer is refused and ends the connection: a whole cover is the longest message.
    static let longestMessage = 512 * 1024

    enum Kind: UInt8 {
        case hello = 1, sound = 2, anchor = 3, state = 4, command = 5, cover = 6, effects = 7, queue = 8
    }

    /// What a listener may send: small, and never sound.
    static let longestRequest = 4 * 1024
    /// A listener this far behind loses sound rather than the whole connection.
    static let mostWaiting = 1_000_000

    /// First message each way.
    struct Hello: Codable, Equatable {
        var version: Int
        var name: String
        /// Host only: the UDP port that answers clock pings.
        var clockPort: UInt16?
        var full: Bool?
    }

    /// What's playing, about once a second and on every change.
    struct State: Codable, Equatable {
        var title: String?
        var artist: String?
        var time: Double
        var duration: Double
        var isPlaying: Bool
        var ended: Bool?
        var song: String?
        var isShuffled: Bool?
        var canMix: Bool?
    }

    /// One row of the host's queue. Only names travel, never a file or its path.
    struct Song: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String?
    }

    /// More than this and the rest of the host's queue isn't shown on the others.
    static let longestQueue = 1_000

    /// A fixed list: anything else from a listener is ignored.
    enum Action: String, Codable { case playPause, next, previous, seek, shuffle, mixNow, pick }

    struct Command: Codable, Equatable {
        var action: Action
        var time: Double?
        var song: String?
    }

    /// Knob's own sound for the whole session: it can't travel in the mix, because each device
    /// adds it after the mix, so every device applies the same settings.
    struct Effects: Codable, Equatable {
        var effects: [Double]
        var eq: [Double]
        var preset: String?

        /// Only sane values from another device: known lengths, and each within its range.
        var isValid: Bool {
            effects.count <= 16 && eq.count <= 64 && (preset?.count ?? 0) <= 120 && effects.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10 }
                && eq.allSatisfy { $0.isFinite && abs($0) <= 1 }
        }

        func isClose(to other: Effects) -> Bool {
            preset == other.preset && effects.count == other.effects.count && eq.count == other.eq.count
                && zip(effects + eq, other.effects + other.eq).allSatisfy { abs($0 - $1) < 0.001 }
        }
    }

    static func json<Value: Encodable>(_ kind: Kind, _ value: Value) -> Message? {
        (try? JSONEncoder().encode(value)).map { Message(kind: kind, body: $0) }
    }

    /// This device's clock in nanoseconds, the one every audio timestamp uses.
    static func now() -> Int64 { nanoseconds(mach_absolute_time()) }

    private static let scale: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    static func nanoseconds(_ ticks: UInt64) -> Int64 { Int64(Double(ticks) * scale) }

    struct Message: Equatable {
        var kind: Kind
        var body: Data
    }

    static func encode(_ message: Message) -> Data {
        var data = Data(capacity: message.body.count + 5)
        let length = UInt32(message.body.count + 1).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(message.kind.rawValue)
        data.append(message.body)
        return data
    }

    /// Sound from `firstFrame` on, as 16 bit stereo.
    static func sound(firstFrame: Int64, samples: UnsafeBufferPointer<Int16>) -> Message {
        var body = Data(capacity: 8 + samples.count * 2)
        withUnsafeBytes(of: firstFrame.littleEndian) { body.append(contentsOf: $0) }
        body.append(contentsOf: UnsafeRawBufferPointer(samples))
        return Message(kind: .sound, body: body)
    }

    /// The frame number and body offset of a sound message, or nil if it is not one.
    static func soundFrame(_ body: Data) -> Int64? {
        guard body.count >= 12, (body.count - 8) % 4 == 0 else { return nil }
        return body.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
    }

    /// "This frame left the mix at this moment on the host's clock": the sound card's clock is
    /// not quite its stated rate, so counting frames alone would slowly drift.
    static func anchor(frame: Int64, hostNanoseconds: Int64, rate: Double) -> Message {
        var body = Data(capacity: 24)
        withUnsafeBytes(of: frame.littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: hostNanoseconds.littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: rate.bitPattern.littleEndian) { body.append(contentsOf: $0) }
        return Message(kind: .anchor, body: body)
    }

    static func readAnchor(_ body: Data) -> (frame: Int64, hostNanoseconds: Int64, rate: Double)? {
        guard body.count == 24 else { return nil }
        return body.withUnsafeBytes { bytes in
            let frame = Int64(littleEndian: bytes.loadUnaligned(as: Int64.self))
            let host = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: Int64.self))
            let rate = Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            return rate.isFinite && rate >= 8_000 && rate <= 192_000 ? (frame, host, rate) : nil
        }
    }

    /// Turns the bytes of a connection, in pieces of any size, back into messages.
    struct Reader {
        enum Failure: Error, Equatable { case tooLong, empty }
        private var buffer = Data()

        /// The messages finished by these bytes. Kinds this version doesn't know are skipped, so
        /// a newer Knob can add some. A failure means the connection should end.
        mutating func add(_ bytes: Data) throws -> [Message] {
            buffer.append(bytes)
            var found: [Message] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 4 {
                let length = buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
                guard length >= 1 else { throw Failure.empty }
                guard length <= longestMessage else { throw Failure.tooLong }
                guard buffer.endIndex - offset >= 4 + length else { break }
                let start = offset + 4
                if let kind = Kind(rawValue: buffer[start]) {
                    found.append(Message(kind: kind, body: Data(buffer[(start + 1)..<(start + length)])))
                }
                offset = start + length
            }
            buffer = Data(buffer[offset...])
            return found
        }
    }
}
