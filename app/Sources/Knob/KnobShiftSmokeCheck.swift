import AppKit
import Foundation

/// Command-line verification for local KnobShift playback. It uses muted output and exits with a
/// nonzero status on import, playback-state or cleanup failure.
@MainActor
enum KnobShiftSmokeCheck {
    /// `volume` is 0 (muted) for automated runs; a small value lets a person listen along.
    static func run(first: URL, second: URL, volume: Float = 0) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = KnobShiftModel(restoresQueue: false)
            await model.addTracks([first, second])
            guard model.tracks.count == 2 else { fail("could not import both local tracks") }
            let expectedNext = model.tracks[1]
            // Start the way people usually do: by clicking the song in the queue, not Play.
            model.playForCheck(style: .gentle, volume: volume, bySelecting: model.tracks[0])
            // Jump to a few seconds before the planned transition, so long real songs are quick
            // to check while the seek-then-plan path is exercised too.
            let plan = KnobShiftPlan.make(from: model.tracks[0], to: expectedNext)
            let lead = min(plan.start, 6)
            if plan.start - lead > 1 { model.seek(to: plan.start - lead) }
            // Wait for the handoff itself rather than a fixed time, with a few seconds of slack.
            let deadline = Date().addingTimeInterval(lead + plan.duration + 3)
            while model.nowPlaying != expectedNext, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard model.isPlaying, model.nowPlaying == expectedNext else {
                fail("local playback did not advance into the next track")
            }
            // After a blend the incoming song has already played for the blend's length, so its
            // clock must carry on from there rather than restart at zero.
            let blended = model.diagnostics.contains { $0.stage == "KNOBMIX" && $0.message.hasPrefix("Completed") }
            if blended, model.playbackTime < 1 {
                fail("the clock restarted at zero after a blend")
            }
            print(String(format: "KnobShift handoff: %@, next song clock %.2fs", blended ? "blended" : "clean", model.playbackTime))
            if volume > 0 { try? await Task.sleep(for: .seconds(4)) }
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
