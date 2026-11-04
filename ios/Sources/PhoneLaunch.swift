import SwiftUI

/// The iPhone app's opening, carrying on from the app icon: the same charcoal faceplate and real
/// knob, resting where the icon shows it (the seventh indicator). It winds back to the first
/// indicator, the marks going dark one by one, holds for a beat, then sweeps up to the eleventh,
/// lighting each mark as it passes with a tap felt at each, bumps against its end stop and
/// strains past it for a moment (the pointer shaking a few degrees beyond the eleventh mark with
/// a rumble felt in the hand), then flies down into the player's Play button, shrinking to its
/// size and fading to orange, so the knob you watched becomes the button you tap (a shared
/// element hand over, like iOS zoom transitions). Its marks stay behind in the air, then jump
/// across one after another to the marks around Play (LaunchMarks). Only the marks glow: there
/// is no halo behind the knob. Everything follows the clock frame by frame, so it stays smooth
/// at 120 Hz. With Reduce Motion it only fades.
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
            let marksTravel = landingStarted != nil && playButton != .zero
            let marksTime = landingStarted.map { timeline.date.timeIntervalSince($0) } ?? 0
            // The first frame is exactly the iPhone's launch image (the same view renders it, in
            // the launch screen's colour, centred on the whole screen), so the knob is there from
            // the tap and simply starts to move.
            ZStack {
            ZStack {
                Self.background.opacity(1 - Self.smoother((u - 0.1) / 0.6))
                // Only the indicator marks glow, as they light.
                LaunchKnobPose(value: value, size: Self.knobSize,
                               knobScale: spot.scale * (endStop ? 1.035 : 1),
                               knobOpacity: 1 - Self.clamp((u - 0.45) / 0.35),
                               overshoot: strainDegrees(at: timeline.date), scheme: scheme,
                               showsMarks: !marksTravel)
                    .position(spot.center)
                // The Play button it becomes: orange fading in over the knob from halfway, then
                // the real disc with its triangle for the last quarter. Its glow is gone by the
                // end, as the real button has none.
                let body = Self.knobSize * Self.bodyShare
                let diameter = playButton == .zero ? body : playButton.width
                ZStack {
                    Circle().fill(Palette.accent)
                        .shadow(color: Palette.accentGlow.opacity(0.55 * (1 - Self.clamp((u - 0.8) / 0.2))), radius: 9)
                    PlayDisc(isPlaying: false, turn: 0, showsPointer: false, diameter: diameter)
                        .opacity(Self.clamp((u - 0.75) / 0.25))
                }
                .frame(width: diameter, height: diameter)
                .scaleEffect(body * spot.scale / diameter)
                .compositingGroup()
                .opacity(Self.clamp((u - 0.45) / 0.45))
                .position(spot.center)
            }
            // Faded as one flat picture: layer by layer, the see through orange washed over the
            // real button's white triangle underneath, a dip that looked like a flicker.
            .compositingGroup()
            .opacity(fading ? 0 : 1)
            // Outside the fade: the last marks are still landing as the button hands over.
            if marksTravel {
                LaunchMarks(time: marksTime, from: CGPoint(x: screen.size.width / 2, y: screen.size.height / 2),
                            playButton: playButton)
            }
            }
            // A firm tap as each mark clicks into its place.
            .onChange(of: LaunchMarks.landed(at: marksTime)) { _, landed in
                if landed > 0 { Haptics.firm() }
            }
            // The strain is felt with the shake it is seen with: one tap each time the pointer
            // pushes out furthest past the stop, as strong as that push.
            .onChange(of: strainPush(at: timeline.date)) { _, push in
                guard let push else { return }
                Haptics.strain(strainSwell(push))
            }
            // A soft tick for each mark going dark on the way back, a firm tap for each mark
            // lighting on the way up, and a hard one at the end stop.
            .onChange(of: Self.mark(value)) { _, mark in
                defer { lastMark = mark }
                if mark < lastMark { Haptics.tick() } else if mark == 10 { Haptics.hard() } else if mark > lastMark { Haptics.firm() }
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
        try? await Task.sleep(for: .seconds(LaunchMarks.length - Self.landing))
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

/// The opening's eleven marks on their way to the Play dial. They wait where the knob left them,
/// then from the first to the eleventh each jumps across on a soft curve, kicks as it clicks into
/// its place and cools away, leaving the dial's own mark underneath. Drawn by the frame clock.
struct LaunchMarks: View {
    /// Seconds since the knob set off for the Play button.
    var time: Double
    /// The middle of the knob they start around.
    var from: CGPoint
    var playButton: CGRect

    /// Seconds between one mark leaving and the next, and how long each is in the air.
    private static let stagger = 0.036, flight = 0.3
    /// How long a mark's kick and its cooling take once it has landed.
    private static let kick = 0.14, cooling = 0.22
    /// Seconds from the first mark leaving until the last has cooled.
    static var length: Double { stagger * Double(PlayDial.marks - 1) + flight + cooling }

    /// How many marks have landed by this moment.
    static func landed(at time: Double) -> Int {
        (0..<PlayDial.marks).filter { time >= stagger * Double($0) + flight }.count
    }

    var body: some View {
        let knob = PhoneLaunch.knobSize, dial = playButton.width / PlayDial.discShare
        // RealisticKnob's marks, at the launch size.
        let startLength = knob * 0.085, startWidth = knob * 0.026, startReach = knob * 0.415 + startLength / 2
        let endLength = dial * PlayDial.markLength, endReach = dial * PlayDial.markReach
        let target = CGPoint(x: playButton.midX, y: playButton.midY)
        ZStack {
            ForEach(0..<PlayDial.marks, id: \.self) { mark in
                let degrees = -PlayDial.sweep / 2 + PlayDial.sweep * Double(mark) / Double(PlayDial.marks - 1)
                let since = time - Self.stagger * Double(mark) - Self.flight
                let e = Self.ease((since + Self.flight) / Self.flight)
                let start = Self.point(from, degrees, startReach), end = Self.point(target, degrees, endReach)
                // Marks left of the middle bow out to the left, marks right of it to the right.
                let bow = sin(.pi * e) * CGFloat(mark - PlayDial.marks / 2) * 7
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: startWidth + (PlayDial.markWidth - startWidth) * e,
                           height: startLength + (endLength - startLength) * e)
                    .shadow(color: Palette.accentGlow.opacity(0.9), radius: 4)
                    .scaleEffect(1 + 0.55 * (1 - Self.ease(since / Self.kick)) * (since > 0 ? 1 : 0))
                    .rotationEffect(.degrees(degrees))
                    .opacity(1 - min(max(since / Self.cooling, 0), 1))
                    .position(x: start.x + (end.x - start.x) * e + bow, y: start.y + (end.y - start.y) * e)
            }
        }
    }

    private static func point(_ center: CGPoint, _ degrees: Double, _ reach: CGFloat) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: center.x + reach * sin(angle), y: center.y - reach * cos(angle))
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (6 * t - 15) + 10)
    }
}
