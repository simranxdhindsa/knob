import CryptoKit
import Foundation

/// Stand in until the tests have failed for the right reason.
enum KnobShiftPlayOn {
    static let service = "_knobplay._tcp"
    static let version = 1
    static let longestFile: Int64 = 300_000_000
    static let songsAhead = 5

    struct Hello: Codable, Equatable { var version: Int; var deviceId: String; var name: String }

    struct Playlist: Codable, Equatable { var id: String; var name: String; var link: String }

    struct Song: Codable, Equatable, Identifiable {
        var key: String
        var title: String
        var artist: String?
        var fileName: String
        var size: Int64
        var playlist: Playlist?
        var id: String { key }
    }

    struct Handover: Codable, Equatable {
        var songs: [Song]
        var current: Int
        var position: Double
        var isPlaying: Bool
        var isShuffled: Bool
        var sentAt: Int64
        var effects: KnobShiftTogether.Effects?
    }

    static func key(for url: URL) -> String? { nil }
    static func sendOrder(_ songs: [Song], current: Int, have: Set<String>) -> [Song] { [] }
    static func safeFileName(_ name: String, key: String) -> String? { name }
    static func isValid(_ handover: Handover) -> Bool { true }
    static func startPosition(_ handover: Handover, goAt: Int64, duration: Double) -> Double { 0 }

    struct Allowed: Equatable {
        var ids: Set<String> = []
        func contains(_ id: String) -> Bool { false }
        mutating func allow(_ id: String) {}
    }

    enum Stage: Equatable {
        case idle, waitingForAllow, copying(Double), gettingReady, waitingForMix, playingThere, failed(String), lost
        var text: String { "" }
        var musicIsHere: Bool { false }
    }

    enum Event: Equatable {
        case start, allowed, refused, needs(Int), copied(Double), ready, mixRunning, mixEnded, switched, connectionLost, noSpace, noOutput
    }

    struct Handoff: Equatable {
        var device: String
        var stage = Stage.idle
        mutating func handle(_ event: Event) {}
    }

    struct Incoming {
        enum Failure: Error, Equatable { case tooBig, noSpace, badName, wrongSize, tooLong }
        let url: URL
        init(name: String, key: String, size: Int64, folder: URL, freeSpace: Int64) throws { url = folder }
        mutating func add(_ data: Data) throws {}
        mutating func finish() throws -> URL { url }
        mutating func cancel() {}
    }
}
