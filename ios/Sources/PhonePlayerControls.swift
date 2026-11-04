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

/// Play, as a flat modern dial: an orange disc that plays and pauses, where the opening's knob
/// lands, inside Knob's eleven marks. The marks glow up one by one and the disc's pointer turns through
/// the song, so a glance tells how far along it is, and turning the ring moves through the song, with
/// a tap felt at each mark.
struct PhonePlayDial: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    @ObservedObject var scrub: PhoneScrub
    let size: CGFloat
    /// True while the opening's knob is flying in to become this disc.
    @Environment(\.hidesPlayButton) private var hidesPlayButton
    @State private var rotary: RotaryDrag?

    static let marks = 11, sweep = 270.0
    static let discShare: CGFloat = 0.64
    /// A mark's width, then its length and how far out it sits as shares of the dial.
    static let markWidth: CGFloat = 2.5, markLength: CGFloat = 0.075, markReach: CGFloat = 0.45
    /// How lit the next mark is by the time the song is halfway to it.
    private static let faintGlow = 0.15

    var body: some View {
        let disc = size * Self.discShare
        ZStack {
            ring
            Button {
                Haptics.mark()
                model.pauseOrResume()
            } label: {
                PhonePlayDisc(isPlaying: model.isPlaying, turn: -Self.sweep / 2 + Self.sweep * value,
                                showsPointer: model.nowPlaying != nil, diameter: disc)
                    .contentShape(Circle())
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
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<Self.marks, id: \.self) { mark in
                let glow = model.nowPlaying == nil ? 0 : Self.glow(mark, at: value)
                Capsule()
                    .fill(Glass.tertiary)
                    .overlay(Capsule().fill(Palette.accent).opacity(glow))
                    .shadow(color: Palette.accentGlow.opacity(glow * 0.7), radius: 3)
                    .frame(width: Self.markWidth, height: size * Self.markLength)
                    .offset(y: -size * Self.markReach)
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

/// The Play button: a flat orange disc with Play or Pause and the pointer.
struct PhonePlayDisc: View {
    let isPlaying: Bool
    /// Where the song has turned the pointer to, in degrees from the top.
    let turn: Double
    let showsPointer: Bool
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Palette.accent)
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(Glass.onAccent)
                .contentTransition(.symbolEffect(.replace))
                .offset(x: isPlaying ? 0 : diameter * 0.03)
            Capsule().fill(Glass.onAccent)
                .frame(width: 3, height: diameter * 0.13)
                .offset(y: -diameter * 0.4)
                .rotationEffect(.degrees(turn))
                .opacity(showsPointer ? 1 : 0)
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
