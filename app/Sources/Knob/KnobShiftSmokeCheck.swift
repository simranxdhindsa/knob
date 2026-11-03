import AppKit
import Foundation

/// Command-line verification for local KnobShift playback. It uses muted output and exits with a
/// nonzero status on import, playback-state or cleanup failure.
@MainActor
enum KnobShiftSmokeCheck {
    /// `volume` is 0 (muted) for automated runs; a small value lets a person listen along.
    /// `mixNowAt` seeks there instead, presses KnobMix Now a second later and checks the mix
    /// waits for the chosen phrase or break rather than starting at once.
    static func run(first: URL, second: URL, volume: Float = 0, mixNowAt: TimeInterval? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = KnobShiftModel(restoresQueue: false)
            await model.addTracks([first, second])
            guard model.tracks.count == 2 else { fail("could not import both local tracks") }
            let expectedNext = model.tracks[1]
            // Start the way people usually do: by clicking the song in the queue, not Play.
            model.playForCheck(volume: volume, bySelecting: model.tracks[0])
            #if DEBUG
            // KNOB_RECORD=FILE.m4a records the mix as heard, muted, for listening afterwards.
            let recordTo = ProcessInfo.processInfo.environment["KNOB_RECORD"].map { URL(fileURLWithPath: $0) }
            let recorder = KnobShiftDemoRecorder()
            if recordTo != nil {
                model.primaryDeck.recordOutput(into: recorder, part: "old")
                model.secondaryDeck.recordOutput(into: recorder, part: "new")
                model.secondaryDeck.recordVoice(into: recorder, part: "new voice")
            }
            #endif
            // Jump to a few seconds before the planned transition, so long real songs are quick
            // to check while the seek-then-plan path is exercised too.
            let plan = KnobShiftPlan.make(from: model.tracks[0], to: expectedNext)
            // KNOB_CHECK_LEAD starts further back, giving vocal separation time to finish first.
            let lead = min(plan.start, Double(ProcessInfo.processInfo.environment["KNOB_CHECK_LEAD"] ?? "") ?? 6)
            if let mixNowAt {
                model.seek(to: mixNowAt)
                try? await Task.sleep(for: .seconds(1))
                let pressed = Date()
                model.mixNow()
                guard model.mixNowWaiting, let note = model.diagnostics.last(where: { $0.stage == "KNOBMIX NOW" }) else {
                    fail("KnobMix Now did not plan a mix")
                }
                print(note.message)
                while model.mixState != .mixing, Date().timeIntervalSince(pressed) < 30 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                print(String(format: "KnobMix Now: the blend began %.2fs after the press, at %.2fs of the song.",
                             Date().timeIntervalSince(pressed), model.playbackTime))
                for line in model.diagnostics where line.stage == "PLAN" && line.message.contains("KnobMix Now") { print(line.message) }
            } else if plan.start - lead > 1 { model.seek(to: plan.start - lead) }
            // Wait for the handoff itself rather than a fixed time, with a few seconds of slack.
            // Slowed-down blends take longer than their music, so allow for that too.
            let deadline = Date().addingTimeInterval(mixNowAt != nil ? 25 : lead * 1.3 + plan.duration * 1.3 + 4)
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
            #if DEBUG
            if let recordTo {
                // A few seconds of the new song after the mix, then the file.
                try? await Task.sleep(for: .seconds(6))
                do {
                    print(String(format: "Recorded %.1fs of the mix to %@", try recorder.write(to: recordTo), recordTo.path))
                    if ProcessInfo.processInfo.environment["KNOB_RECORD_PARTS"] != nil {
                        let base = recordTo.deletingPathExtension().path
                        for part in ["old", "new", "new voice"] {
                            _ = try recorder.write(to: URL(fileURLWithPath: "\(base) (\(part)).m4a"), parts: [part])
                        }
                    }
                } catch {
                    fail("could not write the recording: \(error.localizedDescription)")
                }
            }
            #endif
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
