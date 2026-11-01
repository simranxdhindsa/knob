import AVFoundation

/// Vocal separation in the mix. When a mix is planned, the stretch of the next song that plays
/// underneath the old one is split into its voice and its music in the background. During the
/// blend the new song then plays as those two parts side by side, so its voice (intro tags,
/// shouts, ad-libs) stays silent under the old singer and only its music comes in, and its voice
/// joins as it opens up. Without a separation in time, the mix plays as before.
extension KnobShiftModel {
    func prepareStems(for next: Track, plan: KnobShiftPlan) {
        guard plan.duration > 0, plan.beatsBeforeVoice != nil else { return }
        let from = max(0, plan.incomingOffset - 0.3)
        // The new song may play up to 8% faster during the blend; a little extra covers that.
        let length = plan.duration * 1.1 + 2
        if let ready = preparedStems, ready.song == next.url, ready.start <= plan.incomingOffset,
           ready.start + ready.length >= plan.incomingOffset + length - 0.5 {
            return
        }
        stemTask?.cancel()
        preparedStems = nil
        let url = next.url
        log("STEMS", "Separating \(next.title)'s voice from its music, \(Self.seconds(length)) from \(Self.seconds(from)), for the coming mix.")
        stemTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try KnobShiftStems.prepare(url, from: from, length: length) }
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
