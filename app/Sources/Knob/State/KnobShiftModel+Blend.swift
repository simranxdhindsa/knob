import AVFoundation
import Foundation

/// Planning and running KnobShift's transitions: when the next song comes in, the beat lock,
/// the tempo glide, the bass swap and the volume crossfade. Timing comes from KnobShiftPlan and
/// KnobShiftSync; this part only carries the plan out on the two decks and logs every step.
extension KnobShiftModel {
    func scheduleNext(style: Style) {
        guard let current = nowPlaying, tracks.count > 1 else {
            mixState = .ready
            transitionDescription = "Playing normally."
            log("PLAN", "No next track in the queue. Playing normally with no mix.")
            return
        }
        let next = tracks[(currentIndex + 1) % tracks.count]
        plannedNext = next
        let plan = KnobShiftPlan.make(from: current, to: next)
        let sync = plan.duration > 0 ? KnobShiftSync.make(outgoing: current.analysis, incoming: next.analysis) : .off
        logSection("\(current.title) → \(next.title)")
        log("PLAN", "Now at \(Self.seconds(playbackTime)) of \(Self.seconds(current.duration)), \(style.title) curve.")
        for line in plan.reasoning { log("PLAN", line) }
        for line in sync.notes { log("SYNC", line) }
        transitionDescription = plan.description + (sync.isOn ? String(format: " • tempo sync %.0f to %.0f BPM", sync.outgoingTempo, sync.incomingTempo) : "")
        mixState = plan.duration > 0 ? .ready : .preservingEnding

        // A seek past the planned start still blends over whatever music is left.
        let end = plan.start + plan.duration
        let startsAt = max(plan.start, playbackTime)
        let wait = max(0, startsAt - playbackTime)
        let blends = plan.duration > 0 && end - startsAt > 0
        if playbackTime > plan.start, plan.duration > 0 {
            log("PLAN", "Already past the planned start, so the blend begins now over the remaining \(Self.seconds(max(0, end - startsAt))).")
        }
        log("PLAN", blends
            ? "Decision: blend in \(Self.seconds(wait)), ending at \(Analysis.clock(end))."
            : "Decision: clean handoff in \(Self.seconds(wait)).")
        let scheduledAt = Date()
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            let late = Date().timeIntervalSince(scheduledAt) - wait
            self.log("TIMING", "Plan fired \(String(format: "%.0f", late * 1_000)) ms after its target. Clock reads \(Self.seconds(self.playbackTime)), \(self.primaryDeck.name) is at \(self.deckClock(self.primaryDeck)).")
            if blends {
                self.beginBlend(from: current, to: next, endingAt: end, offset: plan.incomingOffset, sync: sync, style: style)
            } else {
                self.advance(to: next, offset: plan.incomingOffset, style: style)
            }
        }
    }

    /// Lines the incoming song's first beat up with the outgoing song's next beat, so the two
    /// grids start together. Without tempo sync the incoming song simply starts now.
    private func beatLock(from current: Track, to next: Track, offset: TimeInterval,
                          sync: KnobShiftSync) -> (delay: TimeInterval, incomingStart: TimeInterval, note: String) {
        guard sync.isOn, let now = primaryDeck.position else {
            return (0, offset, "No beat lock: tempo sync is off, so \(next.title) starts now.")
        }
        // A little headroom so the scheduled start is never already in the past.
        let earliest = now + 0.05
        let beat = 60 / sync.outgoingTempo
        guard let outgoingBeat = current.analysis.beatGrid.first(where: { $0 >= earliest }),
              outgoingBeat - now <= beat + 0.05,
              let incomingBeat = next.analysis.beatGrid.first(where: { $0 >= offset }) else {
            return (0, offset, "No beat lock: no beat found close enough, so \(next.title) starts now.")
        }
        return (outgoingBeat - now, incomingBeat,
                "Beat lock: \(next.title)'s beat at \(Self.seconds(incomingBeat)) lands on \(current.title)'s beat at \(Analysis.clock(outgoingBeat)), \(String(format: "%.0f", (outgoingBeat - now) * 1_000)) ms from now.")
    }

    private func beginBlend(from current: Track, to next: Track, endingAt end: TimeInterval, offset: TimeInterval,
                            sync: KnobShiftSync, style: Style) {
        do {
            let lock = beatLock(from: current, to: next, offset: offset, sync: sync)
            let outgoingAt = (primaryDeck.position ?? playbackTime) + lock.delay
            let music = max(0.5, end - outgoingAt)
            let duration = sync.blendLength(forOutgoingMusic: music) { Self.shape($0, style) }
            mixState = .mixing
            transitionDescription = "MIXING • \(Int(duration.rounded())) second blend into \(next.title)" + (sync.isOn ? ", beats locked." : ".")
            log("KNOBMIX", "Starting \(Self.seconds(duration)) \(style.title) blend over \(Self.seconds(music)) of \(current.title)'s music. Outgoing \(primaryDeck.name), incoming \(secondaryDeck.name) with \(next.title).")
            log("SYNC", lock.note)

            let file = try AVAudioFile(forReading: next.url)
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition((lock.incomingStart * sampleRate).rounded())
            let frames = max(0, file.length - startFrame)
            guard frames > 0, frames <= AVAudioFramePosition(UInt32.max) else { throw PlayerError.invalidSegment }
            secondaryDeck.player.stop()
            secondaryDeck.resetEffects()
            secondaryDeck.volume = 0
            secondaryDeck.rate = sync.rates(at: 0).incoming
            secondaryDeck.bassCut = 1
            secondaryDeck.startOffset = lock.incomingStart
            secondaryDeck.player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(frames), at: nil)
            try startEngineIfNeeded()
            // Both decks share the engine's render clock, so a start time on the outgoing
            // deck's timeline is sample-accurate for the incoming deck too.
            if lock.delay > 0, let now = primaryDeck.player.lastRenderTime, now.isSampleTimeValid {
                let renderRate = now.sampleRate
                secondaryDeck.player.play(at: AVAudioTime(sampleTime: now.sampleTime + AVAudioFramePosition(lock.delay * renderRate),
                                                          atRate: renderRate))
            } else {
                secondaryDeck.player.play()
            }
            log("DECK", "\(secondaryDeck.name) loaded \(next.title) from \(Self.seconds(lock.incomingStart)) at volume 0, speed \(String(format: "%.3f", secondaryDeck.rate)), bass held back.")

            let started = Date().addingTimeInterval(lock.delay)
            // About 20 updates a second keep the volume, tempo and bass curves smooth.
            let steps = max(1, Int((duration * 20).rounded()))
            transitionTask = Task { [weak self] in
                var lastLogged = -1
                for step in 0...steps {
                    // Each step waits for its own deadline from the blend start, so small sleep
                    // overshoots never add up and the handoff lands on the planned end.
                    let delay = duration * Double(step) / Double(steps) - Date().timeIntervalSince(started)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard let self, !Task.isCancelled else { return }
                    let progress = Double(step) / Double(steps)
                    let shaped = self.applyBlend(progress, sync: sync, style: style)
                    let bucket = Int(progress * 20)
                    if bucket != lastLogged {
                        lastLogged = bucket
                        self.logBlendStep(progress: progress, shaped: shaped, elapsed: Date().timeIntervalSince(started), sync: sync)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.log("KNOBMIX", String(format: "Envelope took %.2fs (planned %.2fs).", Date().timeIntervalSince(started), duration))
                self.finishBlend(to: next, style: style)
            }
        } catch {
            mixState = .preservingEnding
            log("ERROR", "Next deck preparation failed: \(error.localizedDescription)")
            notice = "KnobShift could not prepare the next song."
            advance(to: next, offset: offset, style: style)
        }
    }

    /// The style's crossfade curve: how far through the blend the sound is at `progress`.
    nonisolated static func shape(_ progress: Double, _ style: Style) -> Double {
        switch style {
        case .gentle: progress * progress * (3 - 2 * progress)
        case .balanced: progress
        case .party: sqrt(progress)
        }
    }

    /// Sets volume, tempo and bass on both decks for this point of the blend.
    @discardableResult
    private func applyBlend(_ progress: Double, sync: KnobShiftSync, style: Style) -> Double {
        let shaped = Self.shape(progress, style)
        primaryDeck.volume = Float(cos(shaped * .pi / 2))
        secondaryDeck.volume = Float(sin(shaped * .pi / 2))
        let rates = sync.rates(at: shaped)
        primaryDeck.rate = rates.outgoing
        secondaryDeck.rate = rates.incoming
        // Bass swap around the middle of the blend, so two basslines never stack.
        let swap = min(max((shaped - 0.4) / 0.2, 0), 1)
        primaryDeck.bassCut = swap
        secondaryDeck.bassCut = 1 - swap
        return shaped
    }

    private func logBlendStep(progress: Double, shaped: Double, elapsed: TimeInterval, sync: KnobShiftSync) {
        let tempo = sync.isOn ? String(format: "  •  %.1f BPM, speeds %.3f / %.3f", sync.tempo(at: shaped), primaryDeck.rate, secondaryDeck.rate) : ""
        let bass = String(format: "  •  bass out %.0f%% in %.0f%%", (1 - primaryDeck.bassCut) * 100, (1 - secondaryDeck.bassCut) * 100)
        log("KNOBMIX", String(format: "+%.2fs  %3.0f%% done, curve %3.0f%%  •  out %@ %.2f  •  in %@ %.2f",
                              elapsed, progress * 100, shaped * 100,
                              primaryDeck.name, primaryDeck.volume, secondaryDeck.name, secondaryDeck.volume) + tempo + bass,
            blend: Diagnostic.Blend(progress: progress, outgoing: Double(primaryDeck.volume),
                                    incoming: Double(secondaryDeck.volume),
                                    tempo: sync.isOn ? sync.tempo(at: shaped) : nil))
    }

    private func finishBlend(to next: Track, style: Style) {
        // The incoming deck has been playing for the whole blend, so the clock continues from
        // where it really is instead of restarting at zero (which made the next mix late).
        let incomingPlayed = min(next.duration, secondaryDeck.position ?? secondaryDeck.startOffset)
        primaryDeck.player.stop()
        primaryDeck.resetEffects()
        let outgoing = primaryDeck
        primaryDeck = secondaryDeck
        secondaryDeck = outgoing
        primaryDeck.resetEffects()
        currentIndex = tracks.firstIndex(of: next) ?? 0
        nowPlaying = next
        playbackTime = incomingPlayed
        playbackDuration = next.duration
        playbackStartedAt = Date().addingTimeInterval(-incomingPlayed)
        log("KNOBMIX", "Completed. \(secondaryDeck.name) stopped, \(primaryDeck.name) is primary with \(next.title) at normal speed, full bass, volume 1.")
        log("TIMING", "\(next.title) continues from \(Self.seconds(incomingPlayed)), where its deck really is.")
        startProgressUpdates()
        scheduleNext(style: style)
    }

    func advance(to next: Track, offset: TimeInterval, style: Style) {
        primaryDeck.player.stop()
        secondaryDeck.player.stop()
        currentIndex = tracks.firstIndex(of: next) ?? 0
        log("HANDOFF", "No blend used. Both decks stopped, starting \(next.title) at \(Self.seconds(offset)).")
        do {
            try schedulePrimary(next, from: offset, play: true)
            scheduleNext(style: style)
        } catch {
            log("ERROR", "Handoff failed: \(error.localizedDescription)")
            notice = "KnobShift could not continue playback."
        }
    }

    func deckClock(_ deck: KnobShiftDeck) -> String {
        deck.position.map(Self.seconds) ?? "nothing (not rendering)"
    }
}
