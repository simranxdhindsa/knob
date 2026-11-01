import CryptoKit
import Foundation

/// Saved KnobShift analyses, so a song is analysed once instead of on every launch (4 to 6
/// seconds per song). One small JSON file per song in Knob's own Application Support folder,
/// kept apart for the dev and installed copies.
///
/// A saved result is used only when the song's path, size and modification date and the
/// analysis version all still match; otherwise the song is analysed again and the result
/// replaced. Bump `version` whenever the analysis itself changes, so old results are not reused.
enum KnobShiftAnalysisCache {
    static let version = 3

    struct Entry: Codable {
        let version: Int
        let path: String
        let size: Int64
        let modified: Date
        let duration: TimeInterval
        let tailSilence: TimeInterval
        let analysis: KnobShiftModel.Analysis
        let steps: [String]
    }

    static var folder: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        // Command-line checks have no bundle identifier; keep their results apart too.
        let app = Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob.check"
        return support.appendingPathComponent(app).appendingPathComponent("KnobShift Analysis")
    }

    /// The saved result for this file, if it is still valid.
    static func load(for url: URL) -> Entry? {
        guard let stamp = stamp(url), let file = entryURL(for: url),
              let data = try? Data(contentsOf: file),
              let entry = try? decoder.decode(Entry.self, from: data),
              entry.version == version, entry.path == stamp.path,
              entry.size == stamp.size, abs(entry.modified.timeIntervalSince(stamp.modified)) < 1 else { return nil }
        return entry
    }

    static func save(_ track: KnobShiftModel.Track, steps: [String]) {
        guard let stamp = stamp(track.url), let file = entryURL(for: track.url) else { return }
        let entry = Entry(version: version, path: stamp.path, size: stamp.size, modified: stamp.modified,
                          duration: track.duration, tailSilence: track.tailSilence, analysis: track.analysis, steps: steps)
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func stamp(_ url: URL) -> (path: String, size: Int64, modified: Date)? {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (path, size, modified)
    }

    /// File name from a hash of the song's path, so any file name is safe on disk.
    private static func entryURL(for url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent("\(name).json")
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
