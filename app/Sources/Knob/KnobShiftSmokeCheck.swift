import AppKit
import Foundation

/// Command-line verification for local KnobShift playback. It uses muted output and exits with a
/// nonzero status on import, playback-state or cleanup failure.
@MainActor
enum KnobShiftSmokeCheck {
    static func run(first: URL, second: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = KnobShiftModel(restoresQueue: false)
            await model.addTracks([first, second])
            guard model.tracks.count == 2 else { fail("could not import both local tracks") }
            let expectedNext = model.tracks[1]
            model.playSilentlyForCheck(style: .gentle)
            try? await Task.sleep(for: .seconds(model.tracks[0].duration + 0.5))
            guard model.isPlaying, model.nowPlaying == expectedNext else {
                fail("local playback did not advance into the next track")
            }
            model.stop()
            guard !model.isPlaying, model.nowPlaying == nil else { fail("local playback did not stop cleanly") }
            print("KnobShift smoke check passed")
            exit(0)
        }
        app.run()
    }

    private static func fail(_ message: String) -> Never {
        fputs("KnobShift smoke check failed: \(message)\n", stderr)
        exit(1)
    }
}
