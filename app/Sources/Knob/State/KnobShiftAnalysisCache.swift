import CryptoKit
import Foundation

/// Saved KnobShift analyses, so a song is analysed once instead of on every launch (4 to 6
/// seconds per song). One small JSON file per song in Knob's own Application Support folder,
/// kept apart for the dev and installed copies.
///
/// A saved result is used only when the song's path, size and modification date and the
/// analysis version all still match; otherwise the song is analysed again and the result
/// replaced. Bump `version` whenever the analysis itself changes, so old results are not reused.
/// Paths are kept in their portable form (`Platform.portable`), so an iPhone update, which moves
/// the app's folders, does not make every song look new.
enum KnobShiftAnalysisCache {
    static let version = 6

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
        _ = renamed
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
        let path = Platform.portable(url.standardizedFileURL.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (path, size, modified)
    }

    /// Results saved before paths were portable were filed under the app's old folder on the
    /// iPhone. Once per launch, each is moved under the song's portable path, so the songs
    /// prepared before an update stay prepared. Results whose song is gone are left as they are.
    private static let renamed: Void = {
        // On the Mac paths never moved, so there is nothing to look through.
        #if os(iOS)
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? decoder.decode(Entry.self, from: data),
                  entry.path != Platform.portable(entry.path) else { continue }
            let song = URL(fileURLWithPath: Platform.relocated(entry.path))
            guard let stamp = stamp(song), let target = entryURL(for: song),
                  entry.size == stamp.size, abs(entry.modified.timeIntervalSince(stamp.modified)) < 1 else { continue }
            let moved = Entry(version: entry.version, path: stamp.path, size: entry.size, modified: entry.modified,
                              duration: entry.duration, tailSilence: entry.tailSilence, analysis: entry.analysis, steps: entry.steps)
            guard let encoded = try? encoder.encode(moved), (try? encoded.write(to: target, options: .atomic)) != nil else { continue }
            if target != file { try? FileManager.default.removeItem(at: file) }
        }
        #endif
    }()

    /// File name from a hash of the song's path, so any file name is safe on disk.
    private static func entryURL(for url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(Platform.portable(url.standardizedFileURL.path).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent("\(name).json")
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
