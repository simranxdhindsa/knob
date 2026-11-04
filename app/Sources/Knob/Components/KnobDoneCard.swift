import SwiftUI

/// Knob's "done" moment, told with the knob itself: a small Knob sweeps from its first indicator
/// to its eleventh, lighting each mark with a tap felt in the hand (turned all the way up:
/// everything is there), bumps its end stop, then melts into an orange disc where a tick draws
/// itself with a success tap, the same knob into button hand over as the iPhone's opening
/// (PhoneLaunch). After a moment the card lifts away by itself. The tick follows the 21st.dev
/// Task Checkbox by arihantcodes (spring fill, then the check drawn in), on a card shaped like
/// the 21st.dev Animated Toast by dev.shejanmahamud, rebuilt in SwiftUI. Everything runs on the
/// frame clock; with Reduce Motion the card only fades in with its tick.
struct KnobDoneCard: View {
    let title: String
    let detail: String
    /// Called once the card has gone.
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surface) private var surface
    @Environment(\.colorScheme) private var scheme
    @State private var started: Date?
    @State private var lastMark = 0
    @State private var leaving = false

    /// The sweep up to the eleventh mark, the bump at the end stop, the melt into the disc and the
    /// tick, in seconds from the start.
    static let sweep = 0.7, bump = 0.12, melt = 0.3, draw = 0.32, hold = 1.5
    static let knobSize: CGFloat = 64
    /// The knob's body (its skirt) as a share of its size (RealisticKnob), so the disc it melts
    /// into is exactly as wide.
    static let bodyShare: CGFloat = 0.77 * 0.82

    var body: some View {
        TimelineView(.animation(paused: started == nil || leaving)) { timeline in
            let t = started.map { timeline.date.timeIntervalSince($0) } ?? 0
            let value = reduceMotion ? 1 : Self.smoother(t / Self.sweep)
            let m = reduceMotion ? 1 : Self.clamp((t - Self.sweep - Self.bump) / Self.melt)
            let drawn = reduceMotion ? 1 : Self.clamp((t - Self.sweep - Self.bump - Self.melt * 0.6) / Self.draw)
            VStack(spacing: 14) {
                ZStack {
                    LaunchKnobPose(value: value, size: Self.knobSize,
                                   knobScale: (1 + bump(t) * 0.06) * (1 - 0.25 * m), knobOpacity: 1 - m)
                    let disc = Self.knobSize * Self.bodyShare
                    Circle().fill(Palette.accent)
                        .frame(width: disc, height: disc)
                        .shadow(color: Palette.accentGlow.opacity(0.6), radius: 12)
                        .scaleEffect(0.6 + 0.4 * Self.smoother(m) + 0.08 * sin(.pi * Self.clamp(m * 1.2)))
                        .opacity(m)
                    TickShape().trim(from: 0, to: drawn)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .frame(width: disc * 0.42, height: disc * 0.34)
                }
                .frame(width: Self.knobSize * 1.8, height: Self.knobSize * 1.8)
                .padding(-8)
                VStack(spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(surface.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(surface.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(reduceMotion ? 1 : Self.clamp(t / 0.25))
            }
            // One tap for each mark lit on the way up, the firmest at the end stop.
            .onChange(of: Self.mark(value)) { _, mark in
                defer { lastMark = mark }
                if mark == 10 { Haptics.detent() } else if mark > lastMark { Haptics.mark() }
            }
            .onChange(of: drawn > 0) { _, drawing in if drawing { Haptics.success() } }
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .frame(maxWidth: 290)
        .background {
            SurfaceBackground(radius: 24).shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
        .scaleEffect(reduceMotion ? 1 : (leaving ? 0.9 : (started == nil ? 0.85 : 1)))
        .offset(y: reduceMotion ? 0 : (leaving ? -16 : (started == nil ? 18 : 0)))
        .opacity(leaving || started == nil ? 0 : 1)
        .environment(\.colorScheme, surface.scheme(scheme))
        .accessibilityElement(children: .combine)
        .task { await play() }
    }

    private func play() async {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.snappy) { started = Date() }
        AccessibilityNotification.Announcement("\(title). \(detail)").post()
        let shown = reduceMotion ? 0.2 : Self.sweep + Self.bump + Self.melt + Self.draw
        try? await Task.sleep(for: .seconds(shown + Self.hold))
        withAnimation(reduceMotion ? .easeIn(duration: 0.2) : Motion.gentle) { leaving = true }
        try? await Task.sleep(for: .milliseconds(400))
        onFinished()
    }

    /// The little push at the end stop, 0...1 and back.
    private func bump(_ t: Double) -> Double {
        reduceMotion ? 0 : sin(.pi * Self.clamp((t - Self.sweep) / Self.bump))
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func smoother(_ x: Double) -> Double { let t = clamp(x); return t * t * t * (t * (6 * t - 15) + 10) }
    /// Which of the ten steps between the eleven indicators the pointer has reached.
    private static func mark(_ value: Double) -> Int { Int((value * 10 + 1e-6).rounded(.down)) }
}

/// A tick, drawn from its short arm to its long one, so trimming it draws it in.
struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
