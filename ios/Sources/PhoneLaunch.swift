import SwiftUI

/// The iPhone app's opening, carrying on from the app icon: the same charcoal faceplate and real
/// knob, resting where the icon shows it (the seventh indicator). It winds back to the first
/// indicator, the marks going dark one by one, holds for a beat, then sweeps up to the eleventh,
/// lighting each mark as it passes with a tap felt at each, bumps against its end stop, blooms
/// with the orange glow and zooms toward the viewer onto the player. The turn follows the clock
/// frame by frame, so it stays smooth at 120 Hz; the springs are Knob's Framer Motion settings
/// (Motion.swift). With Reduce Motion it only fades.
struct PhoneLaunch: View {
    /// Called as the zoom begins, so the player can settle in underneath it.
    var onReveal: () -> Void
    /// Called once the opening has gone, to remove it.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepStarted: Date?
    @State private var appeared = false
    @State private var bloom = false
    @State private var zooming = false
    @State private var lastMark = PhoneLaunch.mark(PhoneLaunch.iconValue)
    @State private var endStop = false

    static let knobSize: CGFloat = 220
    /// Where the app icon shows the knob: its seventh indicator.
    static let iconValue = 0.68
    /// The turn, in seconds from its start: rest on the icon's pose, wind back to the first
    /// indicator, a beat of stillness, then the sweep up to the eleventh.
    static let hold = 0.22, windBack = 0.5, rest = 0.14, sweep = 1.05
    static var turnLength: Double { hold + windBack + rest + sweep }
    /// The zoom: slow to start, then rushing past, like moving in toward the knob.
    static let zoom = Animation.timingCurve(0.6, 0, 0.8, 0.4, duration: 0.6)

    var body: some View {
        TimelineView(.animation(paused: sweepStarted == nil || bloom)) { timeline in
            let value = sweepValue(at: timeline.date)
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A3D42), Color(hex: 0x1C1E21)], startPoint: .top, endPoint: .bottom)
                    .overlay(Grain(opacity: 0.05))
                    .ignoresSafeArea()
                    .opacity(zooming ? 0 : 1)
                // The orange glow grows as the marks light, and blooms once all eleven are lit.
                Circle()
                    .fill(RadialGradient(colors: [Palette.accentGlow.opacity(0.55), .clear], center: .center,
                                         startRadius: 0, endRadius: Self.knobSize * 0.9))
                    .frame(width: Self.knobSize * 1.8, height: Self.knobSize * 1.8)
                    .scaleEffect(bloom ? 1.25 : 0.7 + 0.3 * value)
                    .opacity(zooming ? 0 : (bloom ? 1 : 0.15 + 0.6 * value))
                RealisticKnob(value: .constant(value), size: Self.knobSize, showsMinMax: false,
                              accessibilityLabel: "Knob", accessibilityValue: "", springsToChanges: false)
                    .allowsHitTesting(false)
                    .scaleEffect(zooming ? 7 : (appeared ? (endStop ? 1.035 : 1) : 0.94))
                    .opacity(zooming ? 0 : (appeared ? 1 : 0))
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
            appeared = true
            sweepStarted = Date.distantPast
            try? await Task.sleep(for: .milliseconds(350))
            onReveal()
            withAnimation(.easeOut(duration: 0.3)) { zooming = true }
            try? await Task.sleep(for: .milliseconds(300))
            onFinished()
            return
        }
        withAnimation(Motion.gentle) { appeared = true }
        sweepStarted = Date()
        try? await Task.sleep(for: .seconds(Self.turnLength))
        // The end stop: a small bump, as a real knob gives when it is turned all the way.
        withAnimation(Motion.snappy) { endStop = true }
        withAnimation(.easeOut(duration: 0.35)) { bloom = true }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(Motion.gentle) { endStop = false }
        try? await Task.sleep(for: .milliseconds(240))
        onReveal()
        withAnimation(Self.zoom) { zooming = true }
        try? await Task.sleep(for: .milliseconds(600))
        onFinished()
    }

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
