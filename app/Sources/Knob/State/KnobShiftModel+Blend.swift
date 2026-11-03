import AVFoundation
import Foundation

/// Planning and running KnobShift's transitions: when the next song comes in, the beat lock,
/// the tempo ease, the beats-only entry, the bass swap and the volume crossfade. Timing comes
/// from KnobShiftPlan and KnobShiftSync; this part carries the plan out on the two decks and
/// logs every step.
extension KnobShiftModel {
    private static let wallClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    /// Mixes into the next song at the next good moment rather than at once: the next four bar
    /// phrase or break in the music that leaves two bars for the new beats to come in first.
    func mixNow() {
        guard let current = nowPlaying, isPlaying, tracks.count > 1, mixState != .mixing, !mixNowWaiting else { return }
        guard abs(primaryDeck.rate - 1) < 0.001 else {
            log("KNOBMIX NOW", "The planned mix is already easing in, so it carries on as planned.")
            return
        }
        let now = primaryDeck.position ?? playbackTime
        let bar = current.analysis.tempo.map { 4 * 60 / $0 } ?? 2.5
        let audibleEnd = current.analysis.audibleEnd(duration: current.duration)
        guard let found = KnobShiftSections.mixNowPoint(after: now, lead: 2 * bar + 0.5, analysis: current.analysis,
                                                        audibleEnd: audibleEnd),
              found.point < (nextMix?.startsAt ?? .infinity) + 2 * bar else {
            log("KNOBMIX NOW", "The planned mix comes sooner than the next phrase, so it carries on as planned.")
            return
        }
        let point = found.point
        log("KNOBMIX NOW", "Pressed at \(Analysis.clock(now)). " + (found.lineEnd
            ? "The singer finishes a line at \(Analysis.clock(point)), \(Self.seconds(point - now)) away, so it mixes there and the old voice is not cut mid sentence."
            : "The next phrase or break is at \(Analysis.clock(point)), \(Self.seconds(point - now)) away."))
        cancelPlan("KnobMix Now was pressed")
        mixNowWaiting = true
        scheduleNext(handoffAt: point)
    }

    func scheduleNext(handoffAt: TimeInterval? = nil) {
        guard let current = nowPlaying, tracks.count > 1 else {
            mixState = .ready
            transitionDescription = "Playing normally."
            log("PLAN", "No next track in the queue. Playing normally with no mix.")
            return
        }
        let next = tracks[(currentIndex + 1) % tracks.count]
        plannedNext = next
        let plan = KnobShiftPlan.make(from: current, to: next, handoffAt: handoffAt)
        let sync = plan.duration > 0
            ? KnobShiftSync.make(outgoing: current.analysis, incoming: next.analysis, beatsBeforeVoice: plan.beatsBeforeVoice)
            : .off
        logSection("\(current.title) → \(next.title)")
        log("PLAN", "Now at \(Self.seconds(playbackTime)) of \(Self.seconds(current.duration)).")
        for line in plan.reasoning { log("PLAN", line) }
        for line in sync.notes { log("SYNC", line) }
        mixState = plan.duration > 0 ? .ready : .preservingEnding

        // A seek past the planned start still blends over whatever music is left.
        let end = plan.start + plan.duration
        let startsAt = max(plan.start, playbackTime)
        let wait = max(0, startsAt - playbackTime)
        let blends = plan.duration > 0 && end - startsAt > 0
        if playbackTime > plan.start, plan.duration > 0 {
            log("PLAN", "Already past the planned start, so the blend begins now over the remaining \(Self.seconds(max(0, end - startsAt))).")
        }
        // The old song first eases to the meeting tempo on its own over its last two bars
        // before the blend, when the songs meet away from its own tempo.
        let easeMusic = blends && sync.easesBeforeBlend ? min(8 * 60 / sync.outgoingTempo, wait) : 0
        let easeWall = easeMusic / ((1 + sync.easeRate(at: 1)) / 2)
        let easeStartsIn = max(0, wait - easeMusic)

        // The exact moments, as clock times, so the log says when the mix will happen.
        let now = Date()
        let mixAt = now.addingTimeInterval(easeStartsIn + easeWall)
        let mixClock = Self.wallClock.string(from: mixAt)
        if blends {
            let easeNote = easeMusic > 0
                ? String(format: " %@ starts easing from %.1f to %.1f BPM at %@.", current.title, sync.outgoingTempo, sync.meetingTempo,
                         Self.wallClock.string(from: now.addingTimeInterval(easeStartsIn)))
                : ""
            log("PLAN", "Decision: the mix starts at \(mixClock), in \(Self.duration(easeStartsIn + easeWall)), at \(Analysis.clock(startsAt)) of \(current.title), and ends at \(Analysis.clock(end))." + easeNote)
        } else {
            log("PLAN", "Decision: clean handoff at \(mixClock), in \(Self.duration(wait)).")
        }
        if blends { prepareStems(for: next, from: current, plan: plan) }
        nextMix = NextMix(next: next, startsAt: startsAt, endsAt: blends ? end : startsAt, at: mixAt, blends: blends)
        transitionDescription = plan.description + " • at \(mixClock)" +
            (sync.isOn ? String(format: " • tempo %.0f to %.0f BPM", sync.outgoingTempo, sync.incomingTempo) : "")

        let scheduledAt = now
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(easeStartsIn))
            guard let self, !Task.isCancelled else { return }
            if easeWall > 0 {
                self.log("SYNC", "Easing \(current.title) toward \(String(format: "%.1f", sync.meetingTempo)) BPM.")
                let easeStarted = Date()
                let steps = max(1, Int((easeWall * 20).rounded()))
                for step in 0...steps {
                    let delay = easeWall * Double(step) / Double(steps) - Date().timeIntervalSince(easeStarted)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled else { return }
                    self.primaryDeck.rate = sync.easeRate(at: Double(step) / Double(steps))
                }
            }
            let late = Date().timeIntervalSince(scheduledAt) - (easeStartsIn + easeWall)
            self.log("TIMING", "Plan fired \(String(format: "%.0f", late * 1_000)) ms after its target. Clock reads \(Self.seconds(self.playbackTime)), \(self.primaryDeck.name) is at \(self.deckClock(self.primaryDeck)).")
            if blends {
                self.beginBlend(from: current, to: next, endingAt: end, handoff: plan.handoff,
                                voiceEnd: plan.voiceEnd ?? plan.handoff, offset: plan.incomingOffset, sync: sync)
            } else {
                self.advance(to: next, offset: plan.incomingOffset)
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
        // The outgoing song may already be playing faster or slower, so its next beat arrives
        // after its music distance divided by its speed.
        let delay = (outgoingBeat - now) / max(primaryDeck.rate, 0.1)
        return (delay, incomingBeat,
                "Beat lock: \(next.title)'s beat at \(Self.seconds(incomingBeat)) lands on \(current.title)'s beat at \(Analysis.clock(outgoingBeat)), \(String(format: "%.0f", delay * 1_000)) ms from now.")
    }

    private func beginBlend(from current: Track, to next: Track, endingAt end: TimeInterval, handoff: TimeInterval,
                            voiceEnd: TimeInterval, offset: TimeInterval, sync: KnobShiftSync) {
        do {
            let lock = beatLock(from: current, to: next, offset: offset, sync: sync)
            let outgoingAt = (primaryDeck.position ?? playbackTime) + lock.delay * primaryDeck.rate
            let music = max(0.5, end - outgoingAt)
            // How far through the blend the voices hand over, as a share of the outgoing music.
            let pivot = min(max((handoff - outgoingAt) / music, 0), 1)
            // Where the old voice ends: the old song's fade and the new voice wait for it.
            let voiceDone = min(max((voiceEnd - outgoingAt) / music, pivot), 1)
            let duration = sync.blendLength(forOutgoingMusic: music, voice: pivot)
            // The effects begin on the old voice's last word (about a second before it ends),
            // are fullest as the old song is leaving (its slowdown deepest, its reverb widest)
            // and finish as it is gone, so they fill its short exit after the voice.
            // Beats that cannot lock echo out instead: the effects rise at once, while the old
            // song's own sound drops away, and their tail rings on after it.
            let quiet = sync.isOn ? min(1 / max(duration, 0.1), 0.25) : 0
            let effectsFrom = max(quiet, voiceDone - 1 / max(duration, 0.1))
            let peak = sync.isOn ? min(max(voiceDone + 0.6 * (1 - voiceDone), effectsFrom + 0.05), 0.95) : 0.25
            let keyframes = (start: effectsFrom, peak: peak, end: 1.0)
            exitSeconds = duration * (1 - voiceDone)
            log("EFFECT", String(format: "Keyframes: effects start %.1fs into the mix, on the old voice's last word, rise for %.1fs to full as the old song leaves, then fall for %.1fs as it is gone.",
                                 duration * keyframes.start, duration * (peak - keyframes.start), duration * (keyframes.end - peak)))
            mixState = .mixing
            mixNowWaiting = false
            mixingInto = next
            blendProgress = 0
            transitionDescription = "MIXING • \(Int(duration.rounded())) second blend into \(next.title)" + (sync.isOn ? ", beats locked." : ".")
            log("KNOBMIX", "Starting \(Self.seconds(duration)) blend over \(Self.seconds(music)) of \(current.title)'s music. Outgoing \(primaryDeck.name), incoming \(secondaryDeck.name) with \(next.title).")
            log("SYNC", lock.note)
            if pivot > 0.02 {
                log("KNOBMIX", String(format: "Voices hand over %.0f%% of the way in, at %@. Until then %@ keeps singing while only %@'s beats come in underneath.",
                                      pivot * 100, Self.wallClock.string(from: Date().addingTimeInterval(lock.delay + duration * pivot)),
                                      current.title, next.title))
            }

            let file = try AVAudioFile(forReading: next.url)
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition((lock.incomingStart * sampleRate).rounded())
            let frames = max(0, file.length - startFrame)
            guard frames > 0, frames <= AVAudioFramePosition(UInt32.max) else { throw PlayerError.invalidSegment }
            secondaryDeck.stop()
            secondaryDeck.resetEffects()
            secondaryDeck.resetTransitionEffects()
            armExitEffects(from: current, to: next, sync: sync)
            secondaryDeck.volume = 0
            secondaryDeck.rate = sync.rates(progress: 0, voice: pivot).incoming
            secondaryDeck.bassCut = 1
            secondaryDeck.startOffset = lock.incomingStart
            blendHasStems = scheduleIncoming(next, file: file, from: lock.incomingStart, startFrame: startFrame, frames: frames)
            outgoingOnStems = false
            _ = switchOutgoingToStems(current)
            // With its voice held back separately, the new song's melody can come through too.
            secondaryDeck.beatsOnly = pivot > 0.02 ? (blendHasStems ? 0.5 : 1) : 0
            try startEngineIfNeeded()
            // Both decks share the engine's render clock, so a start time on the outgoing
            // deck's timeline is sample-accurate for the incoming deck too.
            if lock.delay > 0, let now = primaryDeck.player.lastRenderTime, now.isSampleTimeValid {
                let renderRate = now.sampleRate
                let startAt = AVAudioTime(sampleTime: now.sampleTime + AVAudioFramePosition(lock.delay * renderRate), atRate: renderRate)
                secondaryDeck.player.play(at: startAt)
                secondaryDeck.voice.play(at: startAt)
            } else {
                secondaryDeck.player.play()
                secondaryDeck.voice.play()
            }
            log("DECK", "\(secondaryDeck.name) loaded \(next.title) from \(Self.seconds(lock.incomingStart)) at volume 0, speed \(String(format: "%.3f", secondaryDeck.rate)), bass and melody held back so only its beats come in.")

            let started = Date().addingTimeInterval(lock.delay)
            // About 20 updates a second keep the volume, tempo and EQ curves smooth.
            let steps = max(1, Int((duration * 20).rounded()))
            transitionTask = Task { [weak self] in
                var lastLogged = -1
                var handedOver = pivot <= 0.02
                for step in 0...steps {
                    // Each step waits for its own deadline from the blend start, so small sleep
                    // overshoots never add up and the handoff lands on the planned end.
                    let delay = duration * Double(step) / Double(steps) - Date().timeIntervalSince(started)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard let self, !Task.isCancelled else { return }
                    let progress = Double(step) / Double(steps)
                    self.applyBlend(progress, pivot: pivot, voiceDone: voiceDone, keyframes: keyframes, length: duration, sync: sync)
                    self.blendProgress = progress
                    if !handedOver, progress >= pivot {
                        handedOver = true
                        self.log("KNOBMIX", String(format: "Handoff: %@'s voice is done. %@ opens up fully at its own speed (%.3f), the basslines swap and %@ fades out.",
                                                   current.title, next.title, self.secondaryDeck.rate, current.title))
                    }
                    let bucket = Int(progress * 20)
                    if bucket != lastLogged {
                        lastLogged = bucket
                        self.logBlendStep(progress: progress, pivot: pivot, elapsed: Date().timeIntervalSince(started), sync: sync)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.log("KNOBMIX", String(format: "Envelope took %.2fs (planned %.2fs).", Date().timeIntervalSince(started), duration))
                self.finishBlend(to: next)
            }
        } catch {
            mixState = .preservingEnding
            log("ERROR", "Next deck preparation failed: \(error.localizedDescription)")
            notice = "KnobShift could not prepare the next song."
            advance(to: next, offset: offset)
        }
    }

    /// The two separated voices at a point of the blend: the old voice clears within half a
    /// second of its end, and the new one rises only in the mix's last 2 seconds, as the old
    /// song is going, so the two singers are never heard together.
    nonisolated static func voiceLevels(progress: Double, voiceDone: Double, length: TimeInterval) -> (old: Double, new: Double) {
        let seconds = max(length, 0.1)
        let old = progress < voiceDone ? 1 : max(0, 1 - (progress - voiceDone) * seconds / 0.5)
        let arrives = max(voiceDone + 0.5 / seconds, 1 - KnobShiftPlan.overlap / seconds)
        let new = progress < arrives ? 0 : min((progress - arrives) * seconds / 0.4, 1)
        return (old, new)
    }

    /// The crossfade curve: a smooth start and finish (smoothstep).
    nonisolated static func shape(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    /// Sets volume, tempo and EQ on both decks for this point of the blend.
    ///
    /// With a vocal handoff the blend has two stages. Before the handoff the outgoing voice stays
    /// up front (dipping only slightly) while only the incoming beats rise underneath: its bass
    /// and melody range are held back and its speed moves to its own. At the handoff the incoming
    /// song opens up fully, the basslines swap and the outgoing song fades out, thinning upward.
    /// Without a handoff it is one equal-power crossfade.
    private func applyBlend(_ progress: Double, pivot: Double, voiceDone: Double,
                            keyframes: (start: Double, peak: Double, end: Double), length: TimeInterval, sync: KnobShiftSync) {
        let outgoing: Double, incoming: Double, swap: Double, sweep: Double, beatsOnly: Double, voice: Double
        // The old singer's separated voice: it leaves before the new one arrives, never together.
        var oldVoice = 1.0
        // How far the leaving song is through its exit, 0...1: the lo-fi exit follows this.
        let exit: Double
        if pivot > 0.02 {
            if progress < pivot {
                let rise = Self.shape(progress / pivot)
                outgoing = 1 - 0.15 * rise
                incoming = 0.55 * sin(rise * .pi / 2)
                swap = 0
                sweep = 0
                beatsOnly = 1
                voice = 0
                exit = 0
            } else {
                let fall = pivot < 1 ? Self.shape((progress - pivot) / (1 - pivot)) : 1
                // The old song keeps its voice clear until its last line ends; only then does it
                // fade with its exit effects, and the new voice joins.
                let leaving = progress < voiceDone ? 0 : (voiceDone < 1 ? Self.shape((progress - voiceDone) / (1 - voiceDone)) : 1)
                // It holds on through the first part of its exit, so its exit effects are heard,
                // then drops away at the end.
                outgoing = 0.85 * cos(pow(leaving, 1.6) * .pi / 2)
                incoming = 0.55 + 0.45 * sin(fall * .pi / 2)
                swap = min(fall / 0.25, 1)
                sweep = leaving
                beatsOnly = max(0, 1 - fall / 0.25)
                let voices = Self.voiceLevels(progress: progress, voiceDone: voiceDone, length: length)
                oldVoice = voices.old
                voice = voices.new
                exit = leaving
            }
        } else if !sync.isOn {
            // Echo out: the old song's own sound is gone within the first 40% (its echo and
            // reverb ring on, after the volume), so its beats never clash with the new ones.
            let dropped = Self.shape(min(progress / 0.4, 1))
            outgoing = cos(dropped * .pi / 2)
            incoming = sin(Self.shape(min(progress / 0.6, 1)) * .pi / 2)
            swap = dropped
            sweep = dropped
            beatsOnly = 0
            let voices = Self.voiceLevels(progress: progress, voiceDone: 0, length: length)
            oldVoice = voices.old
            voice = voices.new
            exit = dropped
        } else {
            // One crossfade (the mix started at or after the old voice's end, after a seek or
            // a late start): the voices still follow the never together rule.
            let shaped = Self.shape(progress)
            outgoing = cos(shaped * .pi / 2)
            incoming = sin(shaped * .pi / 2)
            swap = min(max((shaped - 0.4) / 0.2, 0), 1)
            sweep = max(0, (shaped - 0.5) / 0.5)
            beatsOnly = 0
            let voices = Self.voiceLevels(progress: progress, voiceDone: voiceDone, length: length)
            oldVoice = voices.old
            voice = voices.new
            exit = max(0, (shaped - 0.5) / 0.5)
        }
        primaryDeck.volume = Float(outgoing)
        secondaryDeck.volume = Float(incoming)
        let rates = sync.rates(progress: progress, voice: pivot)
        primaryDeck.rate = rates.outgoing
        secondaryDeck.rate = rates.incoming
        // Bass swap so two basslines never stack.
        primaryDeck.bassCut = swap
        secondaryDeck.bassCut = 1 - swap
        secondaryDeck.beatsOnly = blendHasStems ? beatsOnly * 0.5 : beatsOnly
        // The separated voice of the new song stays silent under the old singer.
        if blendHasStems { secondaryDeck.voiceLevel = Float(voice) }
        // Once the leaving song plays as separated parts, its voice is let go as the new one
        // comes, so the two singers are never heard over each other.
        if outgoingOnStems { primaryDeck.voiceLevel = Float(oldVoice) }
        // The leaving song loses its treble first as it fades.
        primaryDeck.sweep = sweep
        // Keyframes: 0 until `start`, full at `peak`, 0 again from `end`, eased in and out at
        // both ends so nothing lurches in its first second.
        let clamped = min(max(progress, 0), 1)
        let envelope: Double
        if clamped <= keyframes.start || clamped >= keyframes.end {
            envelope = 0
        } else if clamped < keyframes.peak {
            envelope = 0.5 - 0.5 * cos((clamped - keyframes.start) / max(keyframes.peak - keyframes.start, 0.001) * .pi)
        } else {
            envelope = 0.5 + 0.5 * cos((clamped - keyframes.peak) / max(keyframes.end - keyframes.peak, 0.001) * .pi)
        }
        applyExitEffects(exit, envelope: exitStrength * envelope)
        logMilestones(clamped, keyframes: keyframes, pivot: pivot, length: length,
                      oldVoice: oldVoice, newVoice: voice, swap: swap)
    }

    /// Each moment of the mix, logged once as it happens, with the time into the mix, so the
    /// `npm run dev` terminal reads as a timeline of what is heard.
    private func logMilestones(_ progress: Double, keyframes: (start: Double, peak: Double, end: Double), pivot: Double,
                               length: TimeInterval, oldVoice: Double, newVoice: Double, swap: Double) {
        let at = String(format: "%.1fs into the mix", progress * length)
        announce("milestone effects start", when: progress > keyframes.start,
                 "Effects begin \(at), rising to \(Int((exitStrength * 100).rounded()))% at their peak.")
        announce("milestone effects peak", when: progress >= keyframes.peak,
                 "Effects at their peak \(at), where the old voice ends.")
        announce("milestone effects end", when: progress >= keyframes.end, "Effects gone \(at).")
        announce("milestone opens", when: progress >= pivot, "New song opens up fully \(at).")
        announce("milestone bass", when: swap >= 0.5, "Basslines swap \(at): the new bass takes over.")
        announce("milestone old voice", when: outgoingOnStems && oldVoice < 0.99, "Old voice starts to clear \(at).")
        announce("milestone old voice gone", when: outgoingOnStems && oldVoice <= 0.01, "Old voice gone \(at).")
        announce("milestone new voice", when: blendHasStems && newVoice > 0.01, "New voice comes in \(at).")
    }

    private func logBlendStep(progress: Double, pivot: Double, elapsed: TimeInterval, sync: KnobShiftSync) {
        let shared = sync.tempo(progress: progress, voice: pivot)
        let tempo = sync.isOn ? String(format: "  •  %.1f BPM, speeds %.3f / %.3f", shared, primaryDeck.rate, secondaryDeck.rate) : ""
        let eq = String(format: "  •  bass out %.0f%% in %.0f%%, new melody %.0f%%, sweep %.0f%%",
                        (1 - primaryDeck.bassCut) * 100, (1 - secondaryDeck.bassCut) * 100,
                        (1 - secondaryDeck.beatsOnly) * 100, primaryDeck.sweep * 100)
        let old = primaryDeck, new = secondaryDeck
        let effects = String(format: "  •  effects: reverb %.0f%%, echo %.0f%%, lofi %.0f%%, slowdown %.0f%% slower",
                             old.reverbMix * 100, old.echoMix * 100, old.lofiMix * 100, old.tape * 10)
        let voices = (outgoingOnStems ? String(format: "  •  old voice %.0f%% (hall %.0f%%)", old.voiceLevel * 100, old.voiceReverb * 100) : "")
            + (blendHasStems ? String(format: "  •  new voice %.0f%% (reverb %.0f%%)", new.voiceLevel * 100, new.voiceReverb * 100) : "")
        log("KNOBMIX", String(format: "+%.2fs  %3.0f%% done  •  out %@ %.2f  •  in %@ %.2f",
                              elapsed, progress * 100,
                              primaryDeck.name, primaryDeck.volume, secondaryDeck.name, secondaryDeck.volume) + tempo + eq + effects + voices,
            blend: Diagnostic.Blend(progress: progress, outgoing: Double(primaryDeck.volume),
                                    incoming: Double(secondaryDeck.volume),
                                    tempo: sync.isOn ? shared : nil))
    }

    private func finishBlend(to next: Track) {
        // The incoming deck has been playing for the whole blend, so the clock continues from
        // where it really is instead of restarting at zero (which made the next mix late).
        let incomingPlayed = min(next.duration, secondaryDeck.position ?? secondaryDeck.startOffset)
        blendHasStems = false
        outgoingOnStems = false
        primaryDeck.stop()
        primaryDeck.resetEffects()
        let outgoing = primaryDeck
        primaryDeck = secondaryDeck
        secondaryDeck = outgoing
        primaryDeck.resetEffects()
        currentIndex = tracks.firstIndex(of: next) ?? 0
        nowPlaying = next
        mixingInto = nil
        blendProgress = 0
        playbackTime = incomingPlayed
        playbackDuration = next.duration
        playbackStartedAt = Date().addingTimeInterval(-incomingPlayed)
        log("KNOBMIX", "Completed. \(secondaryDeck.name) stopped, \(primaryDeck.name) is primary with \(next.title) at normal speed, full bass, volume 1.")
        log("TIMING", "\(next.title) continues from \(Self.seconds(incomingPlayed)), where its deck really is.")
        startProgressUpdates()
        scheduleNext()
    }

    func advance(to next: Track, offset: TimeInterval) {
        primaryDeck.stop()
        secondaryDeck.stop()
        currentIndex = tracks.firstIndex(of: next) ?? 0
        mixNowWaiting = false
        log("HANDOFF", "No blend used. Both decks stopped, starting \(next.title) at \(Self.seconds(offset)).")
        do {
            try schedulePrimary(next, from: offset, play: true)
            scheduleNext()
        } catch {
            log("ERROR", "Handoff failed: \(error.localizedDescription)")
            notice = "KnobShift could not continue playback."
        }
    }

    func deckClock(_ deck: KnobShiftDeck) -> String {
        deck.position.map(Self.seconds) ?? "nothing (not rendering)"
    }

    /// "1m 23s" or "8s", for how long until a planned moment.
    static func duration(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
