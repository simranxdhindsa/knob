import AVFoundation

/// Vocal separation in the mix. When a mix is planned, the stretch of the next song that plays
/// underneath the old one is split into its voice and its music in the background. During the
/// blend the new song then plays as those two parts side by side, so its voice (intro tags,
/// shouts, ad-libs) stays silent under the old singer and only its music comes in, and its voice
/// joins as it opens up. Without a separation in time, the mix plays as before.
extension KnobShiftModel {
    /// Separates, in the background and one after the other: the stretch of the next song that
    /// plays underneath, then the leaving song's own mix window (so its voice alone can slow).
    func prepareStems(for next: Track, from current: Track, plan: KnobShiftPlan) {
        guard plan.duration > 0 else { return }
        // The songs may play up to 8% off their speed, and the leaving one slows a little more.
        let incoming = plan.beatsBeforeVoice == nil ? nil : (from: max(0, plan.incomingOffset - 0.3), length: plan.duration * 1.1 + 2)
        let outgoing = (from: max(0, plan.start - 0.5), length: plan.duration * 1.25 + 2)
        let needIncoming = incoming.map { range in
            guard let ready = preparedStems, ready.song == next.url else { return true }
            return !(ready.start <= range.from + 0.3 && ready.start + ready.length >= range.from + range.length - 0.5)
        } ?? false
        let needOutgoing: Bool = {
            guard let ready = preparedOutgoingStems, ready.song == current.url else { return true }
            return !(ready.start <= outgoing.from + 0.5 && ready.start + ready.length >= outgoing.from + outgoing.length - 0.5)
        }()
        guard needIncoming || needOutgoing else { return }
        stemTask?.cancel()
        if needIncoming { preparedStems = nil }
        if needOutgoing { preparedOutgoingStems = nil }
        let nextURL = next.url, currentURL = current.url
        stemTask = Task { [weak self] in
            if needIncoming, let range = incoming {
                self?.log("STEMS", "Separating \(next.title)'s voice from its music, \(Self.seconds(range.length)) from \(Self.seconds(range.from)), for the coming mix.")
                let result = await Task.detached(priority: .utility) {
                    Result { try KnobShiftStems.prepare(nextURL, from: range.from, length: range.length) }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .success(let prepared):
                    self.preparedStems = prepared
                    self.log("STEMS", String(format: "%@ separated in %.1fs: its voice stays silent under the old singer.", next.title, prepared.seconds))
                case .failure(let error):
                    self.log("STEMS", "Could not separate \(next.title) (\(error)), so this mix plays the whole song.")
                }
            }
            if needOutgoing {
                self?.log("STEMS", "Separating \(current.title)'s voice from its music for its mix window, \(Self.seconds(outgoing.length)) from \(Self.seconds(outgoing.from)).")
                let result = await Task.detached(priority: .utility) {
                    Result { try KnobShiftStems.prepare(currentURL, from: outgoing.from, length: outgoing.length) }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .success(let prepared):
                    self.preparedOutgoingStems = prepared
                    self.log("STEMS", String(format: "%@ separated in %.1fs: its voice alone can slow down in the mix.", current.title, prepared.seconds))
                case .failure(let error):
                    self.log("STEMS", "Could not separate \(current.title) (\(error)), so its voice is not slowed alone.")
                }
            }
        }
    }

    /// Moves the leaving deck from its whole file onto its separated music and voice, started on
    /// the same sample and crossfaded in a fifth of a second. The two parts add up to the file
    /// exactly, so the switch is silent; afterwards its voice alone can slow down. Returns false
    /// (and changes nothing) when no separation covers this moment.
    func switchOutgoingToStems(_ current: Track) -> Bool {
        let deck = primaryDeck
        guard let stems = preparedOutgoingStems, stems.song == current.url,
              let nodeTime = deck.player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = deck.player.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0,
              let music = try? AVAudioFile(forReading: stems.music), let vocals = try? AVAudioFile(forReading: stems.vocals) else {
            return false
        }
        let lead = 0.2
        let position = deck.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate + lead
        let rate = music.processingFormat.sampleRate
        let skip = AVAudioFramePosition(((position - stems.start) * rate).rounded())
        let frames = min(music.length, vocals.length) - skip
        guard skip >= 0, frames > AVAudioFramePosition(rate) else { return false }
        deck.musicStemLevel = 0
        deck.voiceLevel = 0
        deck.musicStem.scheduleSegment(music, startingFrame: skip, frameCount: AVAudioFrameCount(frames), at: nil)
        deck.voice.scheduleSegment(vocals, startingFrame: skip, frameCount: AVAudioFrameCount(frames), at: nil)
        let startAt = AVAudioTime(sampleTime: nodeTime.sampleTime + AVAudioFramePosition(lead * nodeTime.sampleRate), atRate: nodeTime.sampleRate)
        deck.musicStem.play(at: startAt)
        deck.voice.play(at: startAt)
        log("STEMS", String(format: "%@ switches to its separated music and voice at %.2fs, crossfaded, so its voice alone can slow down.", current.title, position))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(lead + 0.03))
            for step in 1...8 {
                let share = Float(step) / 8
                deck.fileLevel = 1 - share
                deck.musicStemLevel = share
                deck.voiceLevel = share
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.outgoingOnStems = true
        }
        return true
    }

    /// Queues the incoming song on the secondary deck from `start`. With a separation ready it
    /// plays as music and voice side by side, then carries on from the original file; the two
    /// parts add up to the original exactly, so there is no seam. Returns true in that case.
    func scheduleIncoming(_ next: Track, file: AVAudioFile, from start: TimeInterval,
                          startFrame: AVAudioFramePosition, frames: AVAudioFramePosition) -> Bool {
        let deck = secondaryDeck
        if let stems = preparedStems, stems.song == next.url, start >= stems.start,
           let music = try? AVAudioFile(forReading: stems.music), let vocals = try? AVAudioFile(forReading: stems.vocals),
           music.processingFormat.sampleRate == file.processingFormat.sampleRate {
            let skip = AVAudioFramePosition(((start - stems.start) * music.processingFormat.sampleRate).rounded())
            let stemFrames = min(music.length, vocals.length) - skip
            if stemFrames > 0, stemFrames < frames {
                deck.player.scheduleSegment(music, startingFrame: skip, frameCount: AVAudioFrameCount(stemFrames), at: nil)
                deck.player.scheduleSegment(file, startingFrame: startFrame + stemFrames,
                                            frameCount: AVAudioFrameCount(frames - stemFrames), at: nil)
                deck.voice.scheduleSegment(vocals, startingFrame: skip, frameCount: AVAudioFrameCount(stemFrames), at: nil)
                deck.voiceLevel = 0
                log("STEMS", String(format: "%@ comes in as music and voice side by side for %.1fs, then its original file.",
                                    next.title, Double(stemFrames) / music.processingFormat.sampleRate))
                return true
            }
        }
        if preparedStems?.song != next.url { log("STEMS", "No separation ready for \(next.title), so it comes in whole.") }
        deck.player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(frames), at: nil)
        return false
    }
}
