import SwiftUI

/// The iPhone app's opening, carrying on from the app icon: the same charcoal faceplate and real
/// knob, resting where the icon shows it (the seventh indicator). It winds back to the first
/// indicator, the marks going dark one by one, holds for a beat, then sweeps up to the eleventh,
/// lighting each mark as it passes with a tap felt at each, bumps against its end stop and
/// strains past it for a moment (the pointer shaking a few degrees beyond the eleventh mark with
/// a rumble felt in the hand), then zooms toward the viewer onto the player. Only the marks glow: there is no halo behind the knob. The turn follows the clock
/// frame by frame, so it stays smooth at 120 Hz; the springs are Knob's Framer Motion settings
/// (Motion.swift). With Reduce Motion it only fades.
struct PhoneLaunch: View {
    /// Called as the zoom begins, so the player can settle in underneath it.
    var onReveal: () -> Void
    /// Called once the opening has gone, to remove it.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepStarted: Date?
    /// The turn has reached the eleventh indicator; the clock stops driving the knob.
    @State private var turned = false
    @State private var zooming = false
    @State private var lastMark = PhoneLaunch.mark(PhoneLaunch.iconValue)
    @State private var endStop = false

    static let knobSize: CGFloat = 220
    /// The launch screen's colour (Assets.xcassets/LaunchBackground).
    static let background = Color(hex: 0x2F3235)
    /// Where the app icon shows the knob: its seventh indicator.
    static let iconValue = 0.68
    /// The turn, in seconds from its start: rest on the icon's pose, wind back to the first
    /// indicator, a beat of stillness, then the sweep up to the eleventh.
    static let hold = 0.15, windBack = 0.35, rest = 0.1, sweep = 0.75
    static var turnLength: Double { hold + windBack + rest + sweep }
    /// The strain at the end stop: how long, how far past the last mark (degrees) and how fast
    /// the pointer shakes (times a second).
    static let strain = 0.45, strainReach = 9.0, strainRate = 18.0
    /// The zoom: slow to start, then rushing past, like moving in toward the knob.
    static let zoom = Animation.timingCurve(0.6, 0, 0.8, 0.4, duration: 0.45)

    var body: some View {
        TimelineView(.animation(paused: sweepStarted == nil || turned)) { timeline in
            let value = sweepValue(at: timeline.date)
            // The first frame is exactly the iPhone's launch image (the same view renders it, in
            // the launch screen's colour, centred on the whole screen), so the knob is there from
            // the tap and simply starts to move.
            ZStack {
                Self.background.opacity(zooming ? 0 : 1)
                // Only the indicator marks glow, as they light.
                LaunchKnobPose(value: value, size: Self.knobSize,
                               knobScale: zooming ? 7 : (endStop ? 1.035 : 1), knobOpacity: zooming ? 0 : 1,
                               overshoot: strainDegrees(at: timeline.date))
            }
            .ignoresSafeArea()
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
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            sweepStarted = Date.distantPast
            try? await Task.sleep(for: .milliseconds(350))
            onReveal()
            withAnimation(.easeOut(duration: 0.3)) { zooming = true }
            try? await Task.sleep(for: .milliseconds(300))
            onFinished()
            return
        }
        // iOS fades from the launch screen into the app over its first moments: the knob waits on
        // the icon's pose until it is fully on screen, so the whole turn is seen.
        try? await Task.sleep(for: .milliseconds(350))
        sweepStarted = Date()
        try? await Task.sleep(for: .seconds(Self.turnLength))
        // The end stop: a small bump, as a real knob gives when it is turned all the way.
        withAnimation(Motion.snappy) { endStop = true }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(Motion.gentle) { endStop = false }
        // The strain runs on the frame clock (strainDegrees, with its taps in strainPush).
        try? await Task.sleep(for: .seconds(Self.strain - 0.09))
        turned = true
        try? await Task.sleep(for: .milliseconds(80))
        onReveal()
        withAnimation(Self.zoom) { zooming = true }
        try? await Task.sleep(for: .milliseconds(450))
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

    /// Which of the ten steps between the eleven indicators the pointer has reached.
    private static func mark(_ value: Double) -> Int { Int((value * 10 + 1e-6).rounded(.down)) }
}
