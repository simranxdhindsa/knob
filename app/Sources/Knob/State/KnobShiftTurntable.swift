import AVFoundation
import SwiftUI

/// The working parts of the record deck (VinylStage), on the iPhone and the Mac. A hand on the record takes the song away from
/// the player's deck and plays it from KnobShiftScratch, which follows the hand at any speed in
/// either direction. Letting go, the motor brings the record back up to speed and the deck takes
/// over from exactly that point, so the song carries on from wherever the hand left it.
@MainActor
final class KnobShiftTurntable: ObservableObject {
    /// A little under a real 33 and a third, which looked hurried on screen: one full turn is
    /// 2.25 seconds of song.
    nonisolated static let degreesPerSecond = 160.0
    /// The fastest a hand can throw the record, as a multiple of normal speed.
    private static let fastest = 8.0
    /// How quickly the song closes on where the hand has put the record. The song is held to the
    /// record's angle, not its speed, so one full turn is always exactly 2.25 seconds of song.
    private static let grip = 0.035
    /// The motor is back up to speed well inside this; past it, the deck takes over regardless.
    private static let longestReturn = 1.2
    /// The deck starts this far ahead, to meet the record as it fades out.
    private static let handoverLead = 0.03

    let model: KnobShiftModel
    /// A hand is on the record, or it is coming back up to speed after one.
    @Published private(set) var isActive = false
    @Published private(set) var isArmHeld = false
    @Published private(set) var heldProgress: Double?
    var isHolding: Bool { holding }
    /// The playing song is in memory, so a hand can take it.
    var isReady: Bool { canHold }
    var isWired: Bool { attached }

    private let scratch: KnobShiftScratch
    private let node: AVAudioSourceNode
    private var attached = false
    /// How many decks are on screen. A new one can appear before the old one has gone, when a
    /// switch is flipped quickly, and the old one leaving mustn't unplug the new one.
    private var decks = 0
    private var loaded: KnobShiftModel.Track?
    private var loading: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    private var angle = 0.0
    private var lastFrame = Date()
    private var spin = 0.0

    private var holding = false
    private var wasPlaying = false
    private var returningTo: Double?
    private var returnStarted = Date()
    private var fingerAngle = 0.0
    private var grabbedAngle = 0.0
    private var grabbedTime: TimeInterval = 0
    private var turnedSinceTick = 0.0

    /// One record for the life of the app, so turning the phone doesn't read the song again.
    private static var shared: KnobShiftTurntable?

    static func shared(for model: KnobShiftModel) -> KnobShiftTurntable {
        if let shared { return shared }
        let made = KnobShiftTurntable(model: model)
        shared = made
        return made
    }

    private init(model: KnobShiftModel) {
        self.model = model
        let rate = model.audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        scratch = KnobShiftScratch(outputRate: rate > 0 ? rate : 48_000)
        node = scratch.makeNode(format: AVAudioFormat(standardFormatWithSampleRate: scratch.outputRate, channels: 2)!)
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.giveBackMemory() }
        }
        #endif
    }

    /// With the deck away, nothing needs the song in memory if the phone is short of it.
    private func giveBackMemory() {
        guard !attached, !isActive else { return }
        scratch.release()
        loaded = nil
    }

    /// The deck is on screen: wires the record into the mix, so Knob's volume and effects apply
    /// to it like everything else, and Listen Together sends it too.
    func start() {
        decks += 1
        guard !attached else { return }
        model.audioEngine.attach(node)
        model.audioEngine.connect(node, to: model.deckBus, format: nil)
        attached = true
        follow(model.nowPlaying)
    }

    func stop() {
        releaseNow()
        decks = max(decks - 1, 0)
        guard attached, decks == 0 else { return }
        model.audioEngine.detach(node)
        attached = false
    }

    /// Reads the playing song into memory, ready for a hand. Takes about a second.
    func follow(_ track: KnobShiftModel.Track?) {
        guard let track, track != loaded else { return }
        // Another song started under the hand (Next, say): it wins, and the record lets go.
        if isActive { abandon() }
        loaded = track
        loading?.cancel()
        scratch.release()
        let url = track.url
        loading = Task.detached(priority: .userInitiated) { [weak self] in
            guard let decoded = (try? KnobShiftScratch.decode(url)).map(Decoded.init) else {
                await self?.model.log("VINYL", "\(track.title) stays off the record: it is too long or could not be read.")
                return
            }
            await self?.took(decoded, for: track)
        }
    }

    private func took(_ decoded: Decoded, for track: KnobShiftModel.Track) {
        guard loaded == track else {
            decoded.samples.deallocate()
            return
        }
        scratch.use(decoded.samples, frames: decoded.frames, rate: decoded.rate)
        model.log("VINYL", "\(track.title) is on the record.")
    }

    private struct Decoded: @unchecked Sendable {
        let samples: UnsafeMutablePointer<Int16>, frames: Int, rate: Double
        init(_ result: (UnsafeMutablePointer<Int16>, Int, Double)) { (samples, frames, rate) = result }
    }

    /// The song can't be taken over mid mix, with two songs playing.
    private var canHold: Bool {
        scratch.isLoaded && loaded == model.nowPlaying && model.mixState != .mixing && !model.isMixPaused && model.nowPlaying != nil
    }

    // MARK: The record

    /// How far round the record is at this moment. Called for every frame drawn.
    func recordAngle(at date: Date) -> Double {
        let elapsed = min(date.timeIntervalSince(lastFrame), 0.1)
        lastFrame = date
        if !holding {
            let target = isActive ? scratch.speed : (model.isPlaying ? 1 : 0)
            spin += (target - spin) * min(1, elapsed * 14)
            angle += spin * Self.degreesPerSecond * elapsed
        }
        return angle
    }

    func handDown(at point: CGPoint, center: CGPoint) {
        guard canHold, !holding, !isArmHeld else { return }
        takeOver()
        scratch.move(speed: 0)
        holding = true
        spin = 0
        grabbedAngle = angle
        grabbedTime = model.playbackTime
        fingerAngle = Self.bearing(point, center)
        model.log("VINYL", "A hand stops the record at \(String(format: "%.2f", grabbedTime))s.")
    }

    func handMoved(to point: CGPoint, center: CGPoint) {
        guard holding else { return }
        let bearing = Self.bearing(point, center)
        var turned = bearing - fingerAngle
        if turned > 180 { turned -= 360 } else if turned < -180 { turned += 360 }
        fingerAngle = bearing
        turn(by: turned)
    }

    /// Clockwise goes forward through the song, anticlockwise back.
    func turn(by degrees: Double) {
        angle += degrees
        turnedSinceTick += abs(degrees)
        if turnedSinceTick >= 30 {
            turnedSinceTick = 0
            Haptics.tick()
        }
    }

    func handUp() {
        guard holding else { return }
        holding = false
        spin = scratch.speed
        comeBack()
        model.log("VINYL", "The hand lets go at \(String(format: "%.2f", scratch.time))s.")
    }

    private static func bearing(_ point: CGPoint, _ center: CGPoint) -> Double {
        atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
    }

    /// The deck stops under the record without the song counting as paused, so the Play button,
    /// the lock screen and the song's state all stay as they were.
    private func holdDeck() {
        wasPlaying = model.isPlaying
        model.releaseHold = { [weak self] in self?.releaseNow() }
        guard wasPlaying else { return }
        model.updatePlaybackTime()
        model.cancelPlan("A hand is on the record")
        model.secondaryDeck.stop()
        model.primaryDeck.pause()
        model.progressTask?.cancel()
    }

    /// The record takes the song from the deck.
    private func takeOver() {
        holdDeck()
        try? model.startEngineIfNeeded()
        scratch.grab(at: model.playbackTime, speed: wasPlaying ? 1 : 0)
        isActive = true
        watch()
    }

    private func comeBack() {
        let target = model.isPlaying ? 1.0 : 0.0
        scratch.letGo(to: target)
        returningTo = target
        returnStarted = Date()
    }

    /// Ends any hold at once, wherever the song has got to: for a button pressed under the hand,
    /// a touch the system took away, or the deck leaving the screen.
    func releaseNow() {
        if isArmHeld, let progress = heldProgress {
            isArmHeld = false
            heldProgress = nil
            model.releaseHold = nil
            model.seek(to: progress * model.playbackDuration)
        } else if isActive {
            finish()
        }
    }

    /// Keeps the song's clock, and so the arm and the times, with the record, and hands back to
    /// the deck once the motor is up to speed.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while let self, !Task.isCancelled, self.isActive {
                self.followRecord()
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.watching = nil
        }
    }

    private func followRecord() {
        guard scratch.isCaughtUp else { return }
        model.playbackTime = scratch.time
        if holding {
            let wanted = grabbedTime + (angle - grabbedAngle) / Self.degreesPerSecond
            let held = min(max(wanted, 0), model.playbackDuration)
            scratch.move(speed: min(max((held - scratch.time) / Self.grip, -Self.fastest), Self.fastest))
        }
        guard let target = returningTo else { return }
        // At the very end of the song there is no groove left for the record to speed up in.
        let atEnd = target > 0 && scratch.time >= model.playbackDuration - 0.05
        if abs(scratch.speed - target) < 0.03 || atEnd || Date().timeIntervalSince(returnStarted) > Self.longestReturn { finish() }
    }

    private func finish() {
        holding = false
        returningTo = nil
        isActive = false
        model.releaseHold = nil
        let duration = model.nowPlaying?.duration ?? 0
        let time = min(scratch.time + (model.isPlaying ? Self.handoverLead : 0), max(duration - 0.5, 0))
        model.seek(to: time)
        scratch.fadeOut()
        model.log("VINYL", "The deck takes over at \(String(format: "%.2f", time))s.")
    }

    private func abandon() {
        holding = false
        returningTo = nil
        isActive = false
        model.releaseHold = nil
        scratch.fadeOut()
    }

    // MARK: The arm

    /// Lifted off the record, the song stops, as it does on a real one.
    func armLifted(progress: Double) {
        guard !model.isMirroring, model.nowPlaying != nil, model.mixState != .mixing, !model.isMixPaused, !isActive else { return }
        holdDeck()
        isArmHeld = true
        heldProgress = progress
    }

    func armMoved(progress: Double) {
        guard isArmHeld else { return }
        heldProgress = progress
        model.playbackTime = progress * model.playbackDuration
    }

    /// Set down, the record picks up from under the stylus: from a standstill, with the motor,
    /// when the song was playing.
    func armDropped() {
        guard isArmHeld, let progress = heldProgress else { return }
        let time = progress * model.playbackDuration
        isArmHeld = false
        heldProgress = nil
        model.releaseHold = nil
        model.log("VINYL", "The arm comes down at \(String(format: "%.2f", time))s.")
        if wasPlaying, canHold {
            try? model.startEngineIfNeeded()
            scratch.grab(at: time, speed: 0)
            model.releaseHold = { [weak self] in self?.releaseNow() }
            isActive = true
            watch()
            comeBack()
        } else {
            model.seek(to: time)
        }
    }
}
