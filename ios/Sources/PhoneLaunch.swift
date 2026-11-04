import SwiftUI

/// The iPhone app's opening, carrying on from the app icon: the same charcoal faceplate and real
/// knob, resting where the icon shows it (the seventh indicator). It winds back to the first
/// indicator, the marks going dark one by one, holds for a beat, then sweeps up to the eleventh,
/// lighting each mark as it passes with a tap felt at each, bumps against its end stop and
/// strains past it for a moment (the pointer shaking a few degrees beyond the eleventh mark with
/// a rumble felt in the hand), then flies down into the player's Play button, shrinking to its
/// size as the knob melts away from the real orange disc behind it, so the knob you watched
/// becomes the button you tap (a shared element hand over, like iOS zoom transitions). Only the
/// marks glow: there is no halo behind the knob. Everything follows the clock frame by frame, so
/// it stays smooth at 120 Hz. With Reduce Motion it only fades.
struct PhoneLaunch: View {
    /// Where the player's Play button is on screen; zero until the player has laid out.
    var playButton: CGRect
    /// Called as the knob arrives, so the real Play button can take over underneath it.
    var onLanded: () -> Void
    /// Called once the opening has gone, to remove it.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var sweepStarted: Date?
    /// The turn has reached the eleventh indicator; the clock stops driving the knob.
    @State private var turned = false
    @State private var fading = false
    /// When the knob set off for the Play button.
    @State private var landingStarted: Date?
    @State private var finished = false
    @State private var lastMark = PhoneLaunch.mark(PhoneLaunch.iconValue)
    @State private var endStop = false

    static let knobSize: CGFloat = 220
    /// The launch screen's colour, light or dark with the iPhone's theme.
    static let background = Color("LaunchBackground")
    /// Where the app icon shows the knob: its seventh indicator.
    static let iconValue = 0.68
    /// The turn, in seconds from its start: rest on the icon's pose, wind back to the first
    /// indicator, a beat of stillness, then the sweep up to the eleventh.
    static let hold = 0.05, windBack = 0.25, rest = 0.05, sweep = 0.5
    static var turnLength: Double { hold + windBack + rest + sweep }
    /// The strain at the end stop: how long, how far past the last mark (degrees) and how fast
    /// the pointer shakes (times a second).
    static let strain = 0.3, strainReach = 9.0, strainRate = 18.0
    /// The landing into the Play button, in seconds.
    static let landing = 0.5
    /// The last fade once the knob has landed, hiding the swap to the real button, in seconds.
    static let handOver = 0.12
    /// The knob's body (its skirt) as a share of its size at the launch size (RealisticKnob).
    static let bodyShare: CGFloat = 0.77 * 0.82

    var body: some View {
        GeometryReader { screen in
        TimelineView(.animation(paused: sweepStarted == nil || finished)) { timeline in
            let value = sweepValue(at: timeline.date)
            let u = landingProgress(at: timeline.date)
            let spot = landingSpot(u, in: screen.size)
            // The first frame is exactly the iPhone's launch image (the same view renders it, in
            // the launch screen's colour, centred on the whole screen), so the knob is there from
            // the tap and simply starts to move.
            ZStack {
                Self.background.opacity(1 - Self.smoother((u - 0.1) / 0.6))
                // The Play button it becomes, the very same disc, drawn at its final size and
                // scaled. It waits solid behind the knob, so the knob melts away to reveal it and
                // no see through moment shows between the two.
                let body = Self.knobSize * Self.bodyShare
                let diameter = playButton == .zero ? body : playButton.width
                PhonePlayDisc(isPlaying: false, turn: 0, showsPointer: false, diameter: diameter)
                    .scaleEffect(body * spot.scale / diameter)
                    .opacity(Self.clamp((u - 0.1) / 0.2))
                    .position(spot.center)
                // Only the indicator marks glow, as they light.
                LaunchKnobPose(value: value, size: Self.knobSize,
                               knobScale: spot.scale * (endStop ? 1.035 : 1),
                               knobOpacity: 1 - Self.smoother((u - 0.3) / 0.5),
                               overshoot: strainDegrees(at: timeline.date), scheme: scheme)
                    .position(spot.center)
            }
            .opacity(fading ? 0 : 1)
            // The strain is felt with the shake it is seen with: one tap each time the pointer
            // pushes out furthest past the stop, as strong as that push.
            .onChange(of: strainPush(at: timeline.date)) { _, push in
                guard let push else { return }
                Haptics.strain(strainSwell(push))
            }
            // A soft tick for each mark going dark on the way back, a firmer one for each mark
            // lighting on the way up, and the firmest at the end stop.
            .onChange(of: Self.mark(value)) { _, mark in
                defer { lastMark = mark }
                if mark < lastMark { Haptics.tick() } else if mark == 10 { Haptics.detent() } else if mark > lastMark { Haptics.mark() }
            }
        }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            sweepStarted = Date.distantPast
            try? await Task.sleep(for: .milliseconds(350))
            onLanded()
            withAnimation(.easeOut(duration: 0.3)) { fading = true }
            try? await Task.sleep(for: .milliseconds(300))
            onFinished()
            return
        }
        // iOS fades from the launch screen into the app over its first moments: the knob waits on
        // the icon's pose until it is fully on screen, so the whole turn is seen.
        try? await Task.sleep(for: .milliseconds(250))
        sweepStarted = Date()
        try? await Task.sleep(for: .seconds(Self.turnLength))
        // The end stop: a small bump, as a real knob gives when it is turned all the way.
        withAnimation(Motion.snappy) { endStop = true }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(Motion.gentle) { endStop = false }
        // The strain runs on the frame clock (strainDegrees, with its taps in strainPush).
        try? await Task.sleep(for: .seconds(Self.strain - 0.09))
        turned = true
        landingStarted = Date()
        try? await Task.sleep(for: .seconds(Self.landing))
        onLanded()
        withAnimation(.easeOut(duration: Self.handOver)) { fading = true }
        try? await Task.sleep(for: .seconds(Self.handOver))
        finished = true
        onFinished()
    }

    /// How far the pointer strains past the eleventh mark: pushing out and springing back many
    /// times a second, swelling and fading over the strain, never below the mark itself.
    private func strainDegrees(at date: Date) -> Double {
        guard let t = strainTime(at: date) else { return 0 }
        let shake = 0.5 + 0.5 * sin(2 * .pi * Self.strainRate * t - .pi / 2)
        return Self.strainReach * Self.swell(t) * shake
    }

    /// Seconds into the strain, or nil outside it.
    private func strainTime(at date: Date) -> Double? {
        guard let sweepStarted, !turned else { return nil }
        let t = date.timeIntervalSince(sweepStarted) - Self.turnLength
        return t > 0 && t < Self.strain ? t : nil
    }

    /// Which push of the shake has reached its furthest point (the shake peaks halfway through
    /// each cycle), so a tap lands exactly on each push.
    private func strainPush(at date: Date) -> Int? {
        guard let t = strainTime(at: date), t * Self.strainRate >= 0.5 else { return nil }
        return Int((t * Self.strainRate - 0.5).rounded(.down))
    }

    /// The strength of a push, 0...1, by its number.
    private func strainSwell(_ push: Int) -> Double { Self.swell((Double(push) + 0.5) / Self.strainRate) }

    /// The strain swelling and fading over its length.
    private static func swell(_ t: Double) -> Double { sin(.pi * min(max(t / strain, 0), 1)) }

    /// Where the knob points at this moment of the turn, 0 (first indicator) to 1 (eleventh):
    /// each move eases in and out (smootherstep), so it never starts or stops with a jolt.
    private func sweepValue(at date: Date) -> Double {
        guard let sweepStarted else { return Self.iconValue }
        let t = date.timeIntervalSince(sweepStarted)
        func eased(_ from: Double, _ length: Double) -> Double {
            let x = min(max((t - from) / length, 0), 1)
            return x * x * x * (x * (6 * x - 15) + 10)
        }
        if t < Self.hold + Self.windBack { return Self.iconValue * (1 - eased(Self.hold, Self.windBack)) }
        return eased(Self.hold + Self.windBack + Self.rest, Self.sweep)
    }

    /// 0 to 1 through the landing into the Play button.
    private func landingProgress(at date: Date) -> Double {
        guard let landingStarted else { return 0 }
        return Self.clamp(date.timeIntervalSince(landingStarted) / Self.landing)
    }

    /// Where the knob is and how big, `u` of the way into the Play button: place and size share
    /// one ease in and out, so they arrive together and it settles with no jolt. Without the
    /// button's place yet it stays in the middle and only fades.
    private func landingSpot(_ u: Double, in size: CGSize) -> (center: CGPoint, scale: CGFloat) {
        let start = CGPoint(x: size.width / 2, y: size.height / 2)
        guard playButton != .zero else { return (start, 1) }
        let e = Self.smoother(u)
        let center = CGPoint(x: start.x + (playButton.midX - start.x) * e,
                             y: start.y + (playButton.midY - start.y) * e)
        let target = playButton.width / (Self.knobSize * Self.bodyShare)
        return (center, 1 + (target - 1) * e)
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func smoother(_ x: Double) -> Double { let t = clamp(x); return t * t * t * (t * (6 * t - 15) + 10) }

    /// Which of the ten steps between the eleven indicators the pointer has reached.
    private static func mark(_ value: Double) -> Int { Int((value * 10 + 1e-6).rounded(.down)) }
}
