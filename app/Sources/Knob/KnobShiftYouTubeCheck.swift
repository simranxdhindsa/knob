import AppKit
import Foundation

/// `--knobshift-youtube-check selftest` checks KnobShift's YouTube import without the network
/// (KnobShiftYouTubeTests).
/// `--knobshift-youtube-check LINK` reads a real link through the bundled yt-dlp (no download)
/// and prints its songs in order; `LINK --download` also downloads the first song into a
/// temporary folder and prints the file. KNOB_YTDLP and KNOB_FFMPEG point at the helpers when
/// this runs outside Knob.app.
@MainActor
enum KnobShiftYouTubeCheck {
    static func run(_ arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            if arguments.first == "selftest" {
                KnobShiftYouTubeTests.run()
                exit(KnobShiftYouTubeTests.failures == 0 ? 0 : 1)
            } else if let text = arguments.first {
                await check(text, download: arguments.contains("--download"))
            }
            exit(0)
        }
        app.run()
    }

    private static func check(_ text: String, download: Bool) async {
        guard KnobShiftYouTube.isAvailable else { print(KnobShiftYouTubeParsing.Failure.missingHelper.message); exit(1) }
        guard let link = KnobShiftYouTubeParsing.parseLink(text) else { print("Not a YouTube link."); exit(1) }
        print("\(link.kind) \(link.id), signed in: \(KnobShiftYouTube.isSignedIn)")
        let started = Date()
        let read: KnobShiftYouTubeParsing.Read
        do {
            read = try await KnobShiftYouTube.shared.list(link, id: UUID())
        } catch let failure as KnobShiftYouTubeParsing.Failure {
            print("Could not read it: \(failure.message)")
            exit(1)
        } catch {
            print("Could not read it: \(error)")
            exit(1)
        }
        print("\(read.name ?? "?"): \(read.listing.songs.count) song(s), \(read.skipped) left out, read in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for song in read.listing.songs.prefix(10) {
            print("  \(song.list_position ?? 0). \(song.name) by \(song.artists.joined(separator: ", ")), \(Int(song.duration ?? 0))s, \(song.song_id)")
        }
        guard download, let first = read.listing.songs.first else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-youtube-\(UUID().uuidString)")
        print("Downloading \(first.name) into \(folder.path)")
        let result = await KnobShiftYouTube.shared.download(first, into: folder, search: false, id: UUID()) { line in
            if !line.hasPrefix("[download]") { print("  | \(line)") }
        }
        let file = KnobShiftPlaylists.files(in: folder)[first.song_id]
        if let problem = KnobShiftYouTubeParsing.classify(result.lines), file == nil {
            print("Download failed: \(problem.message)")
            exit(1)
        }
        print(file.map { "Saved \($0.lastPathComponent)" } ?? "No file was saved (status \(result.status)).")
    }
}
