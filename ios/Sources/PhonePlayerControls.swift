import SwiftUI

/// A press: the button dips and a soft disc shows under it, like Apple Music's transport.
struct PhonePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed ? 0.9 : 1)
            .background(Circle().fill(Glass.fill.opacity(pressed ? 1 : 0)).scaleEffect(pressed ? 1 : 0.7))
            .animation(Motion.snappy, value: pressed)
    }
}

extension View {
    /// Apple's Liquid Glass round this button, or frosted glass before iOS 26.
    @ViewBuilder func phoneGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

extension View {
    /// A light layer of Liquid Glass, tinted so strongly that the Play disc stays plain orange
    /// and the glass only shows in how it catches the light and reacts to a touch.
    @ViewBuilder func phoneTint() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(Palette.accent).interactive(), in: .circle)
        } else {
            self
        }
    }
}

/// Glass buttons side by side share one pass of Liquid Glass.
struct PhoneGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 10) { content }
        } else {
            content
        }
    }
}

/// Previous, the Play dial and next.
struct PhoneTransport: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var scrub: PhoneScrub
    let dialSize: CGFloat
    @State private var backTaps = 0
    @State private var nextTaps = 0

    var body: some View {
        HStack {
            step("backward.fill", label: "Previous", taps: $backTaps, action: model.previous)
            Spacer()
            PhonePlayDial(model: model, clock: model.clock, scrub: scrub, size: dialSize)
            Spacer()
            step("forward.fill", label: "Next", taps: $nextTaps, action: model.next)
        }
        .padding(.horizontal, 22)
    }

    private func step(_ symbol: String, label: String, taps: Binding<Int>, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.mark()
            taps.wrappedValue += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .symbolEffect(.bounce, value: taps.wrappedValue)
                .foregroundStyle(Glass.text)
                .frame(width: 68, height: 68)
                .contentShape(Circle())
        }
        .buttonStyle(PhonePress())
        .disabled(model.tracks.isEmpty)
        .opacity(model.tracks.isEmpty ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}

/// Play, as Knob's real master knob inside its eleven marks. The marks glow up one by one and the
/// pointer turns through the song, so a glance tells how far along it is, and turning the ring
/// moves through the song, with a tap felt at each mark. A tap on the knob plays or pauses: the
/// pointer slides to the middle and becomes Play or Pause, and a second later goes back to
/// pointing. The opening lands on an orange button, which then melts into the knob.
struct PhonePlayDial: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    @ObservedObject var scrub: PhoneScrub
    let size: CGFloat
    /// True while the opening's knob is flying in to become this disc.
    @Environment(\.hidesPlayButton) private var hidesPlayButton
    @State private var rotary: RotaryDrag?
    /// The orange button is showing instead of the knob, as it is when the opening lands.
    @State private var showingButton = true
    /// How far the pointer has become `glyph`, 0...1.
    @State private var morph = 0.0
    @State private var glyph = PhonePointerShape.Glyph.play
    @State private var settling: Task<Void, Never>?

    private static let marks = 11, sweep = 270.0
    private static let discShare: CGFloat = 0.64
    /// The size of the volume knob in the panel (VolumeSection).
    private static let panelKnob: CGFloat = 150
    /// How long Play or Pause, or the opening's button, stays before going back.
    private static let hold = 1.0
    /// How lit the next mark is by the time the song is halfway to it.
    private static let faintGlow = 0.15

    var body: some View {
        let disc = size * Self.discShare
        ZStack {
            ring
            // Drawn at the panel's size and scaled as a whole: the knob changes its proportions
            // when drawn small, and this must be exactly the panel's volume knob.
            ZStack {
                RealisticKnob(value: .constant(value), size: Self.panelKnob, showsMinMax: false, showsMarks: false, showsPointer: false,
                              accessibilityLabel: "", accessibilityValue: "", springsToChanges: false)
                    .scaleEffect(size / Self.panelKnob)
                    .frame(width: size, height: size)
                PhonePointer(glyph: glyph, degrees: -Self.sweep / 2 + Self.sweep * value, morph: morph, size: size)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .scaleEffect(showingButton ? 0.9 : 1)
            .opacity(hidesPlayButton ? 0 : 1)
            Button(action: tapped) {
                // The clear circle takes the tap while the button itself is out of sight.
                Color.clear
                    .frame(width: disc, height: disc)
                    .contentShape(Circle())
                    .overlay {
                        PhonePlayDisc(symbol: "play.fill", diameter: disc)
                            .scaleEffect(showingButton ? 1 : 0.7)
                            .opacity(showingButton ? 1 : 0)
                    }
            }
            .buttonStyle(PhonePress())
            .disabled(model.tracks.isEmpty)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PlayButtonFrame.self, value: proxy.frame(in: .global))
            })
            .opacity(hidesPlayButton ? 0 : 1)
        }
        .frame(width: size, height: size)
        .onChange(of: hidesPlayButton) { _, hidden in if !hidden { settle() } }
        .onDisappear { settling?.cancel() }
    }

    private func tapped() {
        Haptics.mark()
        glyph = model.isPlaying ? .pause : .play
        model.pauseOrResume()
        withAnimation(Motion.snappy) { morph = 1 }
        settle()
    }

    /// Back to the plain knob after a moment; another tap starts the moment again.
    private func settle() {
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(Self.hold))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.gentle) {
                showingButton = false
                morph = 0
            }
        }
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<Self.marks, id: \.self) { mark in
                let glow = model.nowPlaying == nil ? 0 : Self.glow(mark, at: value)
                Capsule()
                    .fill(Glass.tertiary)
                    .overlay(Capsule().fill(Palette.accent).opacity(glow))
                    .shadow(color: Palette.accentGlow.opacity(glow * 0.7), radius: 3)
                    .frame(width: size * 0.026, height: size * 0.085)
                    .offset(y: -size * 0.4575)
                    .rotationEffect(.degrees(-Self.sweep / 2 + Self.sweep * Double(mark) / Double(Self.marks - 1)))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(turn)
        .accessibilityElement()
        .accessibilityLabel("Position in song")
        .accessibilityValue(KnobShiftNowPlaying.clock(scrub.position ?? clock.time))
        .accessibilityAdjustableAction { direction in
            model.seek(to: clock.time + (direction == .increment ? 10 : -10))
        }
    }

    private var value: Double { min((scrub.position ?? clock.time) / max(clock.duration, 1), 1) }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard model.nowPlaying != nil else { return }
                if rotary == nil { rotary = RotaryDrag(sweep: Self.sweep, size: size, value: value) }
                guard let next = rotary?.move(to: gesture.location) else { return }
                Haptics.indicatorMoved(from: value, to: next, lit: Self.lit)
                scrub.position = next * clock.duration
            }
            .onEnded { _ in
                rotary = nil
                if let time = scrub.position { model.seek(to: time) }
                scrub.position = nil
            }
    }

    /// How lit a mark is at a position (0...1), as the song travels towards it from the mark
    /// before: only a faint glow for the first half of the way, then from halfway it slowly
    /// brightens until it is fully lit on arrival.
    private static func glow(_ mark: Int, at value: Double) -> Double {
        let travelled = min(max(value * Double(marks - 1) - Double(mark - 1), 0), 1)
        if travelled <= 0.5 { return faintGlow * travelled / 0.5 }
        let t = (travelled - 0.5) / 0.5
        return faintGlow + (1 - faintGlow) * t * t * (3 - 2 * t)
    }

    /// How many marks are lit at a position (0...1).
    private static func lit(_ value: Double) -> Int { Int((value * Double(marks - 1) + 0.001).rounded(.down)) + 1 }
}

/// The knob's white pointer, which can become Play or Pause on the cap.
struct PhonePointer: View {
    let glyph: PhonePointerShape.Glyph
    let degrees: Double
    let morph: Double
    let size: CGFloat

    var body: some View {
        let shape = PhonePointerShape(glyph: glyph, degrees: degrees, morph: morph)
        let ink = Palette.dark.knobIndicator
        shape.fill(ink)
            .overlay(shape.stroke(ink, style: StrokeStyle(lineWidth: size * PhonePointerShape.width, lineCap: .round, lineJoin: .round)))
            .shadow(color: Glass.tertiary, radius: 2)
            .frame(width: size, height: size)
    }
}

/// One shape for the pointer and what it turns into, with `morph` going from the pointer at 0 to
/// the glyph at 1. Pause is the pointer split in two and stood up either side of the middle; Play
/// is the pointer opened out into a triangle. At 0 both are a flat line, which the round stroke
/// draws as the knob's capsule pointer. Sizes are shares of the knob, from RealisticKnob's
/// pointer at the panel's size.
struct PhonePointerShape: Shape {
    enum Glyph { case play, pause }
    static let width: CGFloat = 0.032
    private static let inner: CGFloat = 0.138, outer: CGFloat = 0.214

    var glyph: Glyph
    /// Where it points, in degrees from the top, clockwise.
    var degrees: Double
    var morph: Double

    var animatableData: Double {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let size = rect.width, m = CGFloat(morph)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let angle = degrees * .pi / 180
        func along(_ share: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + size * share * CGFloat(sin(angle)), y: centre.y - size * share * CGFloat(cos(angle)))
        }
        func towards(_ from: CGPoint, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (centre.x + size * x - from.x) * m, y: from.y + (centre.y + size * y - from.y) * m)
        }
        // The end that is higher goes to the top of the glyph, so it never turns upside down.
        let ends = [along(Self.inner), along(Self.outer)].sorted { $0.y < $1.y }
        let top = ends[0], bottom = ends[1]
        var path = Path()
        switch glyph {
        case .pause:
            for side in [CGFloat(-1), 1] {
                let a = towards(top, side * 0.05, -0.1), b = towards(bottom, side * 0.05, 0.1)
                let half = size * 0.016 * m
                path.addLines([CGPoint(x: a.x - half, y: a.y), CGPoint(x: a.x + half, y: a.y),
                               CGPoint(x: b.x + half, y: b.y), CGPoint(x: b.x - half, y: b.y)])
                path.closeSubpath()
            }
        case .play:
            let tip = CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2)
            path.addLines([towards(top, -0.07, -0.11), towards(bottom, -0.07, 0.11), towards(tip, 0.12, 0)])
            path.closeSubpath()
        }
        return path
    }
}

/// The orange button the opening lands on: a flat disc with Play, with only a touch of glass on
/// it, a soft sheen from above and a thin bright rim.
struct PhonePlayDisc: View {
    let symbol: String
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Palette.accent)
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(Glass.text)
                .offset(x: symbol == "play.fill" ? diameter * 0.03 : 0)
                .frame(width: diameter, height: diameter)
                .phoneTint()
            Circle()
                .fill(LinearGradient(colors: [Glass.fill, .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(LinearGradient(colors: [Glass.tertiary, .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// KnobMix Now, where Apple Music has its star: a glass button that pulses while it waits for
/// the next phrase, and draws an orange ring around itself as the mix runs.
struct PhoneMixButton: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock

    var body: some View {
        let mixing = model.mixState == .mixing
        let waiting = model.mixNowWaiting && !mixing
        let ready = model.isPlaying && model.tracks.count > 1 && !mixing && !waiting
        Button {
            Haptics.detent()
            model.mixNow()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .bold))
                .symbolEffect(.pulse, isActive: waiting)
                .foregroundStyle(mixing || waiting ? Palette.accent : Glass.text)
                .opacity(ready || mixing || waiting ? 1 : 0.45)
                .frame(width: 40, height: 40)
                .overlay {
                    if mixing {
                        Circle().trim(from: 0, to: clock.blend)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                    }
                }
                .phoneGlass()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .accessibilityLabel(waiting ? "KnobMix Now, waiting for the beat" : "KnobMix Now")
    }
}

/// The three dots: everything else there is to do with the music.
struct PhoneMoreMenu: View {
    @ObservedObject var model: KnobShiftModel
    var onFiles: () -> Void
    @ObservedObject private var sheets = PhoneSheets.shared

    var body: some View {
        Menu {
            Section {
                Button { model.mixNow() } label: { Label("KnobMix Now", systemImage: "arrow.left.arrow.right") }
                    .disabled(!model.isPlaying || model.tracks.count < 2 || model.mixState == .mixing || model.mixNowWaiting)
                Button { model.toggleShuffle() } label: {
                    Label(model.isShuffled ? "Turn Shuffle Off" : "Shuffle", systemImage: "shuffle")
                }
                .disabled(model.tracks.count < 2)
            }
            Section("Add music") {
                Button { sheets.mac = .spotify } label: { Label("From Spotify", systemImage: "link") }
                Button { sheets.mac = .youtube } label: { Label("From YouTube", systemImage: "play.rectangle") }
                Button { sheets.mac = .sync } label: { Label("Sync from your Mac", systemImage: "laptopcomputer.and.iphone") }
                Button(action: onFiles) { Label("Songs on your iPhone", systemImage: "folder") }
            }
            if let track = model.nowPlaying {
                Section {
                    Button(role: .destructive) { model.remove(ids: [track.id]) } label: {
                        Label("Take Out of Queue", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Glass.text)
                .frame(width: 40, height: 40)
                .phoneGlass()
                .contentShape(Circle())
        }
        .accessibilityLabel("More")
    }
}

/// One of the three buttons along the bottom; orange while what it opens is on.
struct PhoneDeckButton: View {
    let systemImage: String
    let label: String
    var lit = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(lit ? Palette.accent : Glass.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PhonePress())
        .accessibilityLabel(label)
    }
}

/// Opens Knob's sound (effects, equalizer and presets); lit while Knob's sound is on. Its own
/// view, so the sound model's changes redraw only this button.
struct PhoneSoundButton: View {
    @ObservedObject var knob: KnobModel
    let action: () -> Void

    var body: some View {
        PhoneDeckButton(systemImage: "slider.vertical.3", label: "Knob sound: effects, equalizer and presets", lit: knob.powerOn, action: action)
    }
}
