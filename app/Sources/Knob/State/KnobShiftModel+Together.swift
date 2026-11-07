import AVFoundation

/// Listen Together on this device. While a session runs, the deck gate is shut and the mix comes
/// back through KnobShiftTogetherPlayer, a fixed time later, the same way as on every listener.
extension KnobShiftModel {
    /// How often frames are tied to the clock.
    private static let anchorSeconds = 1.0

    /// Starts sending the mix through this device's own delay. The song goes quiet for the length
    /// of the delay, then carries on from the same moment.
    func startTogetherSound(outputDelay: TimeInterval, onBlock: (@Sendable (KnobShiftTogetherCapture.Block) -> Void)? = nil,
                            onAnchor: (@Sendable (Int64, Int64, Double) -> Void)? = nil) throws {
        guard together == nil else { return }
        try startEngineIfNeeded()
        let player = KnobShiftTogetherPlayer()
        player.attach(to: audioEngine, outputDelay: outputDelay)
        let capture = KnobShiftTogetherCapture()
        var lastAnchor: Int64?
        var base: (frame: Int64, heard: Int64)?
        capture.start(on: deckBus) { block in
            player.ring.write(firstFrame: block.firstFrame, samples: block.samples)
            if block.afterBreak {
                base = nil
                player.restartSpeakers()
            }
            let due = block.afterBreak || lastAnchor.map { block.hostNanoseconds - $0 >= Int64(Self.anchorSeconds * 1e9) } ?? true
            guard due, let heard = player.ring.heard else {
                onBlock?(block)
                return
            }
            // Counted from what the speakers really played, whose times are real. Where the line
            // starts doesn't matter, as every device follows the same one.
            let start = base ?? (block.firstFrame, heard.frames)
            base = start
            lastAnchor = block.hostNanoseconds
            let frame = start.frame + Int64(Double(heard.frames - start.heard) * block.rate / player.speakerRate)
            player.tick()
            player.add(frame: frame, hostNanoseconds: heard.host, rate: block.rate, restart: block.afterBreak)
            onAnchor?(frame, heard.host, block.rate)
            onBlock?(block)
        }
        together = player
        togetherCapture = capture
        deckGate.outputVolume = 0
        log("TOGETHER", "This device now plays through Listen Together's delay.")
    }

    /// Back to playing straight from the decks.
    func stopTogetherSound() {
        guard let player = together else { return }
        deckGate.outputVolume = 1
        togetherCapture?.stop()
        togetherCapture = nil
        player.detach()
        together = nil
        log("TOGETHER", "This device plays straight from the decks again.")
    }
}
