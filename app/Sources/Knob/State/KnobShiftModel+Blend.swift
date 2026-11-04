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
                                voiceEnd: plan.voiceEnd ?? plan.handoff, offset: plan.incomingOffset, sync: sync,
                                voiceThrow: plan.voiceThrow)
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
        // Strong beats meet strong beats (every second beat from where the drums come in), so a
        // song counted at double or half time never lands its kick on the other's snare.
        guard let outgoingBeat = Self.strongBeat(in: current.analysis, atOrAfter: earliest),
              outgoingBeat - now <= 2 * beat + 0.05,
              let incomingBeat = Self.strongBeat(in: next.analysis, atOrAfter: offset) else {
            return (0, offset, "No beat lock: no beat found close enough, so \(next.title) starts now.")
        }
        // The outgoing song may already be playing faster or slower, so its next beat arrives
        // after its music distance divided by its speed.
        let delay = (outgoingBeat - now) / max(primaryDeck.rate, 0.1)
        return (delay, incomingBeat,
                "Beat lock: \(next.title)'s beat at \(Self.seconds(incomingBeat)) lands on \(current.title)'s beat at \(Analysis.clock(outgoingBeat)), \(String(format: "%.0f", delay * 1_000)) ms from now.")
    }

    private func beginBlend(from current: Track, to next: Track, endingAt end: TimeInterval, handoff: TimeInterval,
                            voiceEnd: TimeInterval, offset: TimeInterval, sync: KnobShiftSync, voiceThrow: Bool = false) {
        do {
            // A sung mix starts the new song a little before it starts singing, not from the top
            // of its intro: from the beginning of the mix when its voice arrives within 2 seconds,
            // else 2 seconds ahead of the voice, with room for the beat lock, which moves forward
            // to its next strong beat. A sung intro well before the main verse is skipped, so the
            // song starts at its main verse. The analysis finds the first singing about 1.25
            // seconds early, so those first words are taken that much later; a main verse placed
            // on the phrase grid is not.
            var entryOffset = offset
            let singing = KnobShiftPlan.firstSinging(next.analysis)
            let firstWords = singing.map { $0.onGrid || $0.at < KnobShiftPlan.analysisSlack ? $0.at : $0.at + KnobShiftPlan.analysisSlack }
            if voiceThrow, let firstWords {
                let lockRoom = sync.isOn ? 2 * 60 / max(sync.incomingTempo, 1) : 0
                let position = primaryDeck.position ?? playbackTime
                let speed = sync.isOn ? max(sync.meetingTempo / sync.outgoingTempo, 0.1) : 1
                let wordsIn = max((voiceEnd - KnobShiftPlan.analysisSlack - position) / speed, 0)
                let voiceIn = KnobShiftPlan.newVoiceEntry(wordsEnd: wordsIn, bar: current.analysis.tempo.map { 4 * 60 / $0 } ?? 2.5)
                let lead = min(max(KnobShiftPlan.voiceLead + lockRoom, voiceIn), KnobShiftPlan.introLead)
                entryOffset = max(min(next.analysis.leadingSilence, firstWords), firstWords - lead)
                log("KNOBMIX", String(format: "%@ sings from about %.2fs, so it starts from %.2fs, not from its intro.", next.title, firstWords, entryOffset))
            }
            let lock = beatLock(from: current, to: next, offset: entryOffset, sync: sync)
            // When no beat could be lined up, the beats are treated as unlocked: never stretched
            // and never played together, rather than stretched at a random phase.
            let lined = !sync.isOn || lock.delay > 0 || lock.incomingStart != entryOffset
            let mixSync = voiceThrow && !lined
                ? KnobShiftSync(isOn: false, outgoingTempo: sync.outgoingTempo, incomingTempo: sync.incomingTempo,
                                meetingTempo: sync.outgoingTempo, notes: sync.notes)
                : sync
            let outgoingAt = (primaryDeck.position ?? playbackTime) + lock.delay * primaryDeck.rate
            let music = max(0.5, end - outgoingAt)
            // How far through the blend the voices hand over, as a share of the outgoing music.
            let pivot = min(max((handoff - outgoingAt) / music, 0), 1)
            // Where the old voice ends: the old song's fade and the new voice wait for it.
            let voiceDone = min(max((voiceEnd - outgoingAt) / music, pivot), 1)
            // Where the shared tempo reaches the new song's own: at the handoff, except in a
            // vocal throw between tempos far apart, where it waits until the old song is almost
            // silent, so the old voice is never rushed or dragged by the whole gap.
            let tempoAt = voiceThrow && sync.wide ? max(pivot, 0.9) : pivot
            // A sung mix holds the old song at the meeting tempo throughout (see applyHookMix).
            let duration = voiceThrow
                ? music / (mixSync.isOn ? max(sync.meetingTempo / sync.outgoingTempo, 0.1) : 1)
                : sync.blendLength(forOutgoingMusic: music, voice: tempoAt)
            // The effects begin on the old voice's last word (about a second before it ends),
            // are fullest as the old song is leaving (its slowdown deepest, its reverb widest)
            // and finish as it is gone, so they fill its short exit after the voice.
            // Beats that cannot lock echo out instead: the effects rise at once, while the old
            // song's own sound drops away, and their tail rings on after it.
            let quiet = sync.isOn ? min(1 / max(duration, 0.1), 0.25) : 0
            var keyframes: (start: Double, peak: Double, end: Double)
            if sync.isOn, !voiceThrow {
                // The long tape slowdown: it eases in over the old voice's last words, is deepest
                // where the voice ends (the climax of the mix) and eases out as the old song goes,
                // two bars each way (3 to 6 seconds), or an even split of a shorter mix.
                let seconds = min(max(8 * KnobShiftExitStyle.beat(of: current), 3), 6)
                let side = seconds / max(duration, 0.1)
                let peak = duration >= 2 * seconds + 1 ? min(max(voiceDone, quiet + side), 1 - side) : (1 + quiet) / 2
                keyframes = (start: max(peak - side, quiet), peak: peak, end: min(peak + side, 1))
            } else {
                let effectsFrom = max(quiet, voiceDone - 1 / max(duration, 0.1))
                let peak = sync.isOn ? min(max(voiceDone + 0.6 * (1 - voiceDone), effectsFrom + 0.05), 0.95) : 0.25
                keyframes = (start: effectsFrom, peak: peak, end: 1.0)
            }
            if !voiceThrow { log("EFFECT", String(format: "Keyframes: effects start %.1fs into the mix, rise for %.1fs to full, then fall for %.1fs.",
                                 duration * keyframes.start, duration * (keyframes.peak - keyframes.start), duration * (keyframes.end - keyframes.peak))) }
            mixState = .mixing
            mixNowWaiting = false
            mixingInto = next
            blendProgress = 0
            transitionDescription = "MIXING • \(Int(duration.rounded())) second blend into \(next.title)" + (sync.isOn ? ", beats locked." : ".")
            log("KNOBMIX", "Starting \(Self.seconds(duration)) blend over \(Self.seconds(music)) of \(current.title)'s music. Outgoing \(primaryDeck.name), incoming \(secondaryDeck.name) with \(next.title).")
            log("SYNC", lock.note)
            if voiceThrow {
                log("KNOBMIX", String(format: "%@'s voice is pressed down from the start; %@ comes in %.0f%% of the way in and its voice arrives over %@'s.",
                                      current.title, next.title, pivot * 100, current.title))
            } else if pivot > 0.02 {
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
            // The new song arrives in a hall, so its deck's reverb has to be in the sound.
            if voiceThrow { secondaryDeck.armTransitionEffects(echoEvery: 0.5, hall: .largeHall) }
            armExitEffects(from: current, to: next, sync: sync, announces: !voiceThrow)
            secondaryDeck.volume = 0
            secondaryDeck.rate = sync.rates(progress: 0, voice: tempoAt).incoming
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
            // In a sung mix the new song only starts where its beats come in, so none of its
            // intro is used up while it would be silent. Locked, that wait is a whole number of
            // the old song's strong beats, so the beat lock holds.
            let strongBeat = 2 * 60 / max(sync.meetingTempo, 1)
            var entryWait: TimeInterval = {
                guard voiceThrow, pivot > 0.02 else { return 0 }
                let wanted = pivot * duration
                guard mixSync.isOn else { return wanted }
                return (wanted / strongBeat).rounded() * strongBeat
            }()
            // The new voice comes in half way to the old voice's last words, over the pressed old
            // voice, and never after them, so the songs mix and there is no gap. The analysis
            // places the old voice's last words about 1.25 seconds late and the new first words
            // about 1.25 seconds early, so both are corrected first. The new song's start is then
            // moved either way, in whole beats when the beats lock.
            var wordsShare = voiceDone
            // How long the new song takes to rise: over most of its music before its voice, so it
            // eases in under the old song and its first words are already at full level.
            var riseTime: TimeInterval? = nil
            // Where the new voice comes in, as a share of the mix.
            var voiceShare: Double? = nil
            if voiceThrow, let firstWords {
                let oldEnd = max(voiceEnd - KnobShiftPlan.analysisSlack, outgoingAt + 1)
                wordsShare = min(max((oldEnd - outgoingAt) / music, 0), 1)
                let wordsEnd = wordsShare * duration
                // Unlocked, its music starts slow and reaches its own speed with the voice, so on
                // average it plays half way between the two.
                let fileLead = max(0, firstWords - lock.incomingStart)
                let lead = fileLead / (!mixSync.isOn && fileLead >= 1 ? (1 + KnobShiftPlan.introSpeed) / 2 : max(Double(secondaryDeck.rate), 0.1))
                let overlap = { (wait: TimeInterval) in wordsEnd - (wait + lead) }
                let latest = duration * 0.97
                let bar = current.analysis.tempo.map { 4 * 60 / $0 } ?? 2.5
                let target = KnobShiftPlan.newVoiceEntry(wordsEnd: wordsEnd, bar: bar)
                var chosen = min(max(target - lead, 0), latest)
                if mixSync.isOn {
                    // Whole beats keep the lock; of the nearest few, the one closest to the target.
                    let wanted = wordsEnd - target
                    let beat = 60 / max(sync.meetingTempo, 1)
                    let nearest = (chosen / beat).rounded()
                    let options = (-2...2).map { (nearest + Double($0)) * beat }.filter { $0 >= 0 && $0 <= latest }
                    // Never a gap: only those that still overlap, unless none does.
                    let overlapping = options.filter { overlap($0) >= KnobShiftPlan.leastOverlap }
                    let pool = !overlapping.isEmpty ? overlapping : options
                    chosen = pool.min { abs(overlap($0) - wanted) < abs(overlap($1) - wanted) } ?? chosen
                }
                riseTime = min(max(0.6 * lead, 0.15), 2)
                voiceShare = min((chosen + lead) / max(duration, 0.1), 1)
                let moved = chosen - entryWait
                entryWait = chosen
                log("KNOBMIX", String(format: "Voices: %@'s first words at about %.2fs into the mix, %@'s last words end at about %.2fs: they sing together for %.2fs%@.",
                                      next.title, entryWait + lead, current.title, wordsEnd, overlap(entryWait),
                                      abs(moved) > 0.01 ? String(format: " (the new song moved %.2fs %@)", abs(moved), moved > 0 ? "later" : "earlier") : ""))
            }
            // Where the new song comes in, as a share of the mix.
            let entryShare = voiceThrow ? min(entryWait / max(duration, 0.1), 1) : pivot
            let wait = lock.delay + entryWait
            // Where the new song's own drums come in, as a share of the mix: an intro without
            // drums can play over the old beats, its drums cannot when the tempos are apart.
            let newBeats: Double = {
                guard let drums = next.analysis.beatEntry else { return entryShare }
                return min(max((entryWait + max(0, drums - lock.incomingStart)) / max(duration, 0.1), entryShare), 1)
            }()
            // On the host clock, shared by every part, even with no wait, so the new song's separated
            // music and voice start together. Never on a sample count: each part counts only while
            // it plays, so one that sat idle runs behind and started seconds late, voice last.
            if primaryDeck.player.lastRenderTime?.isSampleTimeValid == true {
                let startAt = KnobShiftDeck.startTime(after: max(wait, 0.05))
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
                var handedOver = entryShare <= 0.02
                for step in 0...steps {
                    // Each step waits for its own deadline from the blend start, so small sleep
                    // overshoots never add up and the handoff lands on the planned end.
                    let delay = duration * Double(step) / Double(steps) - Date().timeIntervalSince(started)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard let self, !Task.isCancelled else { return }
                    let progress = Double(step) / Double(steps)
                    self.applyBlend(progress, pivot: entryShare, voiceDone: wordsShare, keyframes: keyframes, length: duration, sync: mixSync,
                                    voiceThrow: voiceThrow, tempoAt: tempoAt, newBeats: newBeats, riseTime: riseTime, voiceShare: voiceShare)
                    self.blendProgress = progress
                    if !handedOver, progress >= entryShare {
                        handedOver = true
                        if voiceThrow {
                            self.log("KNOBMIX", "\(next.title) comes in.")
                        } else {
                            self.log("KNOBMIX", String(format: "Handoff: %@'s voice is done. %@ opens up fully at its own speed (%.3f), the basslines swap and %@ fades out.",
                                                   current.title, next.title, self.secondaryDeck.rate, current.title))
                        }
                    }
                    let bucket = Int(progress * 20)
                    if bucket != lastLogged, !voiceThrow {
                        lastLogged = bucket
                        self.logBlendStep(progress: progress, pivot: tempoAt, elapsed: Date().timeIntervalSince(started), sync: sync)
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

    /// The two separated voices at a point of the blend, handing over smoothly: the old voice
    /// fades into its hall over 1.5 seconds after it ends, and the new one rises through its
    /// reverb (over 0.8 seconds) in the mix's last 2 seconds, once the old tail is down to a
    /// third. They only meet as a quiet reverb crossover, never two full voices.
    nonisolated static func voiceLevels(progress: Double, voiceDone: Double, length: TimeInterval) -> (old: Double, new: Double) {
        let seconds = max(length, 0.1)
        let old = progress < voiceDone ? 1 : max(0, 1 - (progress - voiceDone) * seconds / 1.5)
        let arrives = newVoiceArrives(voiceDone: voiceDone, length: length)
        // A short mix leaves less room: the rise fits what is left, so it is full by the end.
        let rise = max(0.2, min(0.8, (1 - arrives) * seconds))
        let new = progress < arrives ? 0 : min((progress - arrives) * seconds / rise, 1)
        return (old, new)
    }

    /// Where the new voice starts, 0...1 of the mix: at least a second after the old voice ends,
    /// and in the last 2 seconds.
    nonisolated static func newVoiceArrives(voiceDone: Double, length: TimeInterval) -> Double {
        let seconds = max(length, 0.1)
        return max(voiceDone + 1.0 / seconds, 1 - KnobShiftPlan.overlap / seconds)
    }

    /// How much of the old song's echo, reverb and voice hall is still let through: all of it
    /// until half a second before the new voice, then cleared within 0.6 seconds, so the new
    /// singer comes in clean, never over the old song's tails.
    nonisolated static func tailLevel(progress: Double, newVoiceAt: Double, length: TimeInterval) -> Double {
        let seconds = max(length, 0.1)
        let from = newVoiceAt - 0.5 / seconds
        return 1 - shape(min(max((progress - from) / (0.6 / seconds), 0), 1))
    }

    /// A vocal throw at `share` of the way from the cut (0) to the end of the mix (1): the old
    /// music fading slowly in time with the new beats, gone at 85%; the old voice slowing like
    /// tape (to 15% slower, its pitch falling) into a hall while it fades, gone at 90%; the new
    /// voice only after that. Beats that cannot lock lose the old music within the first 12%
    /// instead, so they barely meet.
    nonisolated static func throwLevels(share: Double, locked: Bool = true) -> (music: Double, voice: Double, tape: Double, reverb: Double, newVoice: Double) {
        let music = locked ? cos(shape(min(share / 0.6, 1)) * .pi / 2) : 1 - shape(min(share / 0.1, 1))
        let fading = min(share / 0.9, 1)
        let voice = cos(shape(fading) * .pi / 2)
        // Keyframes: the slowdown rises to its peak by the middle and eases back to nothing at
        // the very end, and the hall peaks a little earlier and lingers longer, so neither is cut
        // off while the old voice is still fading.
        let tape = shape(min(share / 0.5, 1)) * (share <= 0.5 ? 1 : 1 - shape((share - 0.5) / 0.5))
        let reverb = 0.8 * shape(min(share / 0.4, 1)) * (share <= 0.55 ? 1 : 1 - shape((share - 0.55) / 0.45))
        let newVoice = share < 0.92 ? 0 : min((share - 0.92) / 0.08, 1)
        return (music, voice < 0.005 ? 0 : voice, tape, reverb, newVoice)
    }

    /// The first strong beat at or after `time`: an even numbered beat counted from where the
    /// song's drums come in (its first and third beats of each bar).
    nonisolated static func strongBeat(in analysis: Analysis, atOrAfter time: TimeInterval) -> TimeInterval? {
        let grid = analysis.beatGrid
        let entry = grid.firstIndex { $0 >= (analysis.beatEntry ?? grid.first ?? 0) - 0.05 } ?? 0
        guard let first = grid.firstIndex(where: { $0 >= time }) else { return nil }
        let index = (first - entry) % 2 == 0 ? first : first + 1
        return index < grid.count ? grid[index] : nil
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
                            keyframes: (start: Double, peak: Double, end: Double), length: TimeInterval, sync: KnobShiftSync,
                            voiceThrow: Bool = false, tempoAt: Double? = nil, newBeats: Double = 0, riseTime: TimeInterval? = nil,
                            voiceShare: Double? = nil) {
        if voiceThrow {
            applyHookMix(progress, entry: pivot, wordsEnd: voiceDone, beatsIn: newBeats, length: length, sync: sync, rise: riseTime, voiceAt: voiceShare)
            return
        }
        var outgoing: Double, incoming: Double, swap: Double, sweep: Double, beatsOnly: Double, voice: Double
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
        // A vocal throw after the cut: the old music drops out, its separated voice alone slows
        // into a hall and fades, and the new voice waits until it is gone. Without separated
        // parts the whole old song leaves within the first 40%, as an echo out.
        throwingVoice = voiceThrow && outgoingOnStems && progress >= voiceDone
        let newVoiceAt = Self.newVoiceArrives(voiceDone: pivot > 0.02 || sync.isOn ? voiceDone : 0, length: length)
        let tail = Self.tailLevel(progress: progress, newVoiceAt: newVoiceAt, length: length)
        if voiceThrow, progress >= voiceDone {
            let share = voiceDone < 1 ? min(max((progress - voiceDone) / (1 - voiceDone), 0), 1) : 1
            let levels = Self.throwLevels(share: share, locked: sync.isOn)
            if outgoingOnStems {
                outgoing = 1
                primaryDeck.musicStemLevel = Float(levels.music)
                primaryDeck.throwVoice(speed: 1 - 0.25 * levels.tape)
                primaryDeck.voiceReverb = levels.reverb
                oldVoice = levels.voice
            } else {
                outgoing = min(outgoing, cos(Self.shape(min(share / 0.4, 1)) * .pi / 2))
            }
            voice = levels.newVoice
            // The new song's beats stay low while the old music is still heard and open up as it
            // clears, so the two songs' beats never sit on top of each other.
            incoming = min(incoming, 0.35 + 0.65 * (1 - levels.music))
            swap = max(swap, 1 - levels.music)
        }
        primaryDeck.volume = Float(outgoing)
        secondaryDeck.volume = Float(incoming)
        let rates = sync.rates(progress: progress, voice: tempoAt ?? pivot)
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
        // The square root lifts the whole curve: the effects reach strength sooner and stay strong
        // longer, instead of only touching their peak (same start, peak and end).
        applyExitEffects(exit, envelope: exitStrength * envelope.squareRoot(), tail: tail)
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
        traceVoice(of: next, on: primaryDeck)
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
