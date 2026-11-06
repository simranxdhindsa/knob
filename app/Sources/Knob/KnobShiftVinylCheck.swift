import AppKit
import Foundation

/// `--knobshift-vinyl-check SONG SONG` runs the record deck on the Mac through the real audio
/// engine, muted: a hand turning the record, the arm moved and dropped, a pause under a hand and
/// the arm dropped at the very end of the song. Exits nonzero on any failure.
@MainActor
enum KnobShiftVinylCheck {
    private static var failed = 0

    private static func expect(_ passed: Bool, _ what: String) {
        print("  \(passed ? "ok  " : "FAIL") \(what)")
        if !passed { failed += 1 }
    }

    static func run(first: URL, second: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = KnobShiftModel(restoresQueue: false)
            await model.addTracks([first, second])
            guard model.tracks.count == 2 else {
                print("Could not add both songs")
                exit(1)
            }
            model.playForCheck(volume: 0, bySelecting: model.tracks[0])
            let deck = KnobShiftTurntable.shared(for: model)
            deck.start()
            model.seek(to: 30)
            for _ in 0..<60 where !deck.isReady { try? await Task.sleep(for: .milliseconds(100)) }
            expect(deck.isReady, "the song is on the record")

            let held = hold(deck)
            let start = model.playbackTime
            try? await Task.sleep(for: .milliseconds(300))
            for (degrees, count) in [(12.0, 30), (-12.0, 15)] {
                for _ in 0..<count {
                    deck.turn(by: degrees)
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let moved = model.playbackTime - start
            expect(held && abs(moved - 0.9) < 0.05, String(format: "one turn forward and half back moves the song %.2f s (wanted 0.90)", moved))
            expect(model.isPlaying, "the song still counts as playing under the hand")
            deck.handUp()
            try? await Task.sleep(for: .seconds(1.5))
            expect(!deck.isActive && model.primaryDeck.player.isPlaying, "letting go hands back to the deck")
            model.updatePlaybackTime()
            let after = model.playbackTime
            try? await Task.sleep(for: .seconds(1))
            model.updatePlaybackTime()
            expect(abs(model.playbackTime - after - 1) < 0.1, "the song plays on at normal speed")

            deck.armLifted(progress: 0.2)
            deck.armMoved(progress: 0.5)
            deck.armDropped()
            try? await Task.sleep(for: .seconds(1.5))
            model.updatePlaybackTime()
            expect(!deck.isActive && abs(model.playbackTime / model.playbackDuration - 0.5) < 0.03, "the arm lands the song at the middle")

            _ = hold(deck)
            try? await Task.sleep(for: .milliseconds(200))
            model.pauseOrResume()
            try? await Task.sleep(for: .milliseconds(300))
            expect(!deck.isActive && !model.isPlaying && !model.primaryDeck.player.isPlaying, "pause under a hand pauses, with nothing left sounding")
            model.pauseOrResume()
            try? await Task.sleep(for: .milliseconds(500))
            expect(model.primaryDeck.player.isPlaying, "play carries on")

            let song = model.nowPlaying
            deck.armLifted(progress: 0.5)
            deck.armMoved(progress: 1)
            deck.armDropped()
            try? await Task.sleep(for: .seconds(3))
            expect(!deck.isActive && model.nowPlaying != song, "the arm dropped at the very end moves to the next song")

            deck.stop()
            print(failed == 0 ? "Vinyl check passed" : "Vinyl check FAILED: \(failed)")
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
    }

    private static func hold(_ deck: KnobShiftTurntable) -> Bool {
        deck.handDown(at: CGPoint(x: 100, y: 0), center: .zero)
        return deck.isHolding
    }
}
