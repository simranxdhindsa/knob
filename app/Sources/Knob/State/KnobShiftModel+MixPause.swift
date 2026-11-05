import AVFoundation

/// Pausing during a KnobMix: both songs stop on the same sample and the mix's clock stops with
/// them, and Play carries the same mix on from that moment. Parts still waiting for their start
/// time are held too, and get what was left of their wait back.
extension KnobShiftModel {
    struct MixPause {
        /// When the mix was paused; nil while it runs.
        var since: Date?
        /// How long this mix has been paused so far, taken off its clock.
        var total: TimeInterval = 0
        /// When the new song, and the leaving song's separated parts, are due to start.
        var incomingStarts = Date.distantPast
        var stemsStart = Date.distantPast
        /// Schedule those parts again from nothing: a part stopped before it began holds no
        /// reliable place, so it is cancelled at the pause and started afresh on resume.
        var restartIncoming: ((AVAudioTime) -> Void)?
        var restartStems: ((AVAudioTime) -> Void)?
        /// The whole engine was paused, which keeps every part on the same sample. Not used while
        /// a part still waits to start: a start time set after the engine restarts lands late by
        /// the length of the pause.
        var engineHeld = false
        /// What was left of those waits at the pause.
        var incomingLeft: TimeInterval = 0
        var stemsLeft: TimeInterval = 0
    }

    var isMixPaused: Bool { mixPause.since != nil }

    func pauseMix() {
        updatePlaybackTime()
        log("PLAY", String(format: "Paused %.0f%% into the mix, at %@.", blendProgress * 100, Self.seconds(playbackTime)))
        let now = Date()
        mixPause.since = now
        mixPause.incomingLeft = max(mixPause.incomingStarts.timeIntervalSince(now), 0)
        mixPause.stemsLeft = max(mixPause.stemsStart.timeIntervalSince(now), 0)
        mixPause.engineHeld = mixPause.incomingLeft <= 0 && mixPause.stemsLeft <= 0
        if mixPause.engineHeld {
            audioEngine.pause()
        } else {
            if mixPause.incomingLeft > 0 { secondaryDeck.stop() }
            if mixPause.stemsLeft > 0 {
                primaryDeck.musicStem.stop()
                primaryDeck.voice.stop()
            }
            primaryDeck.pause()
        }
        progressTask?.cancel()
        isPlaying = false
        rememberNowPlaying()
    }

    func resumeMix() throws {
        try startEngineIfNeeded()
        // Everything restarts from one moment, so what was in time stays in time.
        let lead = mixPause.engineHeld ? 0 : 0.05
        if !mixPause.engineHeld {
            let startAt = KnobShiftDeck.startTime(after: lead)
            primaryDeck.player.play(at: startAt)
            if mixPause.stemsLeft <= 0 {
                primaryDeck.voice.play(at: startAt)
                primaryDeck.musicStem.play(at: startAt)
            }
        }
        if mixPause.incomingLeft > 0 {
            mixPause.restartIncoming?(KnobShiftDeck.startTime(after: lead + mixPause.incomingLeft))
            mixPause.incomingStarts = Date().addingTimeInterval(lead + mixPause.incomingLeft)
        }
        if mixPause.stemsLeft > 0 {
            mixPause.restartStems?(KnobShiftDeck.startTime(after: lead + mixPause.stemsLeft))
            mixPause.stemsStart = Date().addingTimeInterval(lead + mixPause.stemsLeft)
        }
        if let since = mixPause.since { mixPause.total += Date().timeIntervalSince(since) + lead }
        mixPause.since = nil
        log("PLAY", String(format: "Resumed the mix %.0f%% in, at %@.", blendProgress * 100, Self.seconds(playbackTime)))
        isPlaying = true
        playbackStartedAt = Date().addingTimeInterval(-playbackTime)
        startProgressUpdates()
    }

    /// Waits until `seconds` of the mix have really played, not counting any pause.
    func waitForMix(until seconds: TimeInterval, from started: Date) async {
        while !Task.isCancelled {
            if isMixPaused {
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            let left = seconds - mixElapsed(since: started)
            guard left > 0 else { return }
            try? await Task.sleep(for: .seconds(left))
        }
    }

    func mixElapsed(since started: Date) -> TimeInterval {
        Date().timeIntervalSince(started) - mixPause.total
    }
}
