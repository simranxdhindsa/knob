import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPhone's main screen, laid out like Apple Music's player in a modern finish: the cover
/// runs edge to edge from the top of the screen and melts into a blurred wash of its own colours,
/// above the song with KnobMix and more beside it on glass, the position slider, the transport
/// around the Play dial, the iPhone's volume, and three buttons along the bottom for Knob's
/// sound, the output and the queue. Pausing eases the cover back and dims it. The queue button
/// shrinks it to the corner and opens the queue in its place, while the song and the controls
/// stay. The cover moves as one view, by transform only.
struct PhonePlayer: View {
    @ObservedObject var model: KnobShiftModel
    let knob: KnobModel
    /// Songs picked to add, before they join the queue: they are copied into the app.
    var prepareImports: ([URL]) -> [URL]

    @ObservedObject private var sheets = PhoneSheets.shared
    @StateObject private var scrub = PhoneScrub()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false

    var body: some View {
        GeometryReader { geometry in
            let layout = PhonePlayerLayout(size: geometry.size, topInset: geometry.safeAreaInsets.top, queue: sheets.queue)
            ZStack(alignment: .topLeading) {
                // With no song there is no cover to melt, only a note on the plain background.
                if model.nowPlaying == nil && !sheets.queue {
                    Image(systemName: "music.note")
                        .font(.system(size: layout.side * 0.2, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .position(layout.cover)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                } else {
                    cover(layout)
                }
                titleRow(layout)
                if sheets.queue {
                    queue
                        .frame(width: layout.width, height: layout.queueHeight)
                        .offset(x: PhonePlayerLayout.margin, y: layout.queueTop)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity))
                }
                controls(layout)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: sheets.queue)
        }
        .background { PhoneAmbient(url: (model.mixingInto ?? model.nowPlaying)?.url).ignoresSafeArea() }
        .sheet(item: $sheets.mac) { PhoneMacSheet(model: model, source: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let prepared = prepareImports(urls)
            Task { await model.addTracks(prepared) }
        }
    }

    private func cover(_ layout: PhonePlayerLayout) -> some View {
        let queue = sheets.queue
        let scale = queue ? PhonePlayerLayout.small / layout.side : (model.isPlaying ? PhonePlayerLayout.playing : 1)
        return KnobShiftCover(model: model, clock: model.clock, size: layout.side, animated: model.isPlaying, corner: queue ? 0.13 : 0)
            // A soft shade behind the clock and battery, for bright covers.
            .overlay(alignment: .top) {
                LinearGradient(colors: [Glass.scrim, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: layout.side * 0.2)
                    .opacity(queue ? 0 : 1)
            }
            // The melt: solid at the top, gone by the bottom edge. Solid all over in the queue.
            .mask {
                ZStack {
                    LinearGradient(stops: Self.melt, startPoint: .top, endPoint: .bottom)
                    Color.black.opacity(queue ? 1 : 0)
                }
            }
            .brightness(model.isPlaying || queue ? 0 : -0.1)
            .scaleEffect(scale)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: model.isPlaying)
            .position(layout.cover)
            .onTapGesture { sheets.queue = false }
            .allowsHitTesting(queue)
    }

    private static let melt: [Gradient.Stop] = [
        .init(color: .black, location: 0.34), .init(color: .black.opacity(0.86), location: 0.46),
        .init(color: .black.opacity(0.58), location: 0.6), .init(color: .black.opacity(0.28), location: 0.74),
        .init(color: .black.opacity(0.08), location: 0.88), .init(color: .clear, location: 1),
    ]

    private func titleRow(_ layout: PhonePlayerLayout) -> some View {
        let track = model.nowPlaying
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track?.name ?? "Nothing playing")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(Glass.text)
                Text(track?.artist ?? (track != nil ? "Local music" : (model.tracks.isEmpty ? "Add songs from the dots" : "Tap Play to start")))
                    .font(.system(size: 18)).foregroundStyle(Glass.secondary)
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.gentle, value: track?.id)
            Spacer(minLength: 0)
            PhoneGlassGroup {
                HStack(spacing: 10) {
                    PhoneMixButton(model: model, clock: model.clock)
                    PhoneMoreMenu(model: model, onFiles: { importing = true })
                }
            }
        }
        .frame(width: layout.titleWidth, height: PhonePlayerLayout.title)
        .offset(x: layout.titleX, y: layout.titleY)
    }

    private var queue: some View {
        KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { sheets.mac = .spotify }, onYouTube: { sheets.mac = .youtube },
                       onSync: { sheets.mac = .sync })
    }

    private func controls(_ layout: PhonePlayerLayout) -> some View {
        VStack(spacing: 0) {
            PhoneTimeline(model: model, clock: model.clock, scrub: scrub)
                .frame(height: PhonePlayerLayout.timeline)
            Spacer(minLength: 0)
            PhoneTransport(model: model, scrub: scrub, dialSize: layout.dial)
                .frame(height: layout.dial)
            Spacer(minLength: 0)
            PhoneVolumeRow(knob: knob)
                .frame(height: PhonePlayerLayout.volume)
            HStack {
                PhoneSoundButton(knob: knob) { sheets.sound = true }
                Spacer()
                PhoneOutputButton()
                Spacer()
                PhoneDeckButton(systemImage: "list.bullet", label: sheets.queue ? "Hide the queue" : "Show the queue", lit: sheets.queue) {
                    sheets.queue.toggle()
                }
            }
            .padding(.horizontal, 28)
            .frame(height: PhonePlayerLayout.buttons)
            PhoneCaption(model: model)
                .frame(height: PhonePlayerLayout.caption)
        }
        .frame(width: layout.width, height: layout.size.height - layout.controlsTop)
        .offset(x: PhonePlayerLayout.margin, y: layout.controlsTop)
    }
}

/// Where everything on the player sits, worked out from the screen. The cover is a square a
/// little wider than the screen, so its sides run off the edges and its melt reaches the song's
/// name; the controls spread out over what is left below, and on short phones the cover gives
/// way to them.
struct PhonePlayerLayout {
    static let margin: CGFloat = 24, top: CGFloat = 10, title: CGFloat = 56, timeline: CGFloat = 60
    static let volume: CGFloat = 34, buttons: CGFloat = 44, caption: CGFloat = 20
    /// The cover's size in the queue, and how far it zooms in while playing. It never gets
    /// smaller than the screen, which would show its edges.
    static let small: CGFloat = 60, playing: CGFloat = 1.05
    /// How far the cover's bottom edge reaches past the top of the song's name.
    private static let overlap: CGFloat = 48

    let size: CGSize
    let topInset: CGFloat
    let queue: Bool

    var width: CGFloat { size.width - 2 * Self.margin }
    /// The Play dial, smaller on short phones.
    var dial: CGFloat { size.height < 720 ? 100 : 118 }
    private var lower: CGFloat { Self.timeline + dial + Self.volume + Self.buttons + Self.caption }
    /// The top of the song's name while the cover is large.
    private var songTop: CGFloat { min(size.width * 1.2 - topInset - Self.overlap, size.height - lower - Self.title - 6) }
    var side: CGFloat { max(size.width, songTop + topInset + Self.overlap) }
    var controlsTop: CGFloat { songTop + Self.title + 6 }
    private var playerCover: CGPoint { CGPoint(x: size.width / 2, y: side / 2 - topInset) }
    private var smallCover: CGPoint { CGPoint(x: Self.margin + Self.small / 2, y: Self.top + Self.small / 2) }
    var cover: CGPoint { queue ? smallCover : playerCover }

    var titleX: CGFloat { Self.margin + (queue ? Self.small + 12 : 0) }
    var titleY: CGFloat { queue ? smallCover.y - Self.title / 2 : songTop }
    var titleWidth: CGFloat { width - (queue ? Self.small + 12 : 0) }
    var queueTop: CGFloat { Self.top + Self.small + 12 }
    var queueHeight: CGFloat { controlsTop - queueTop - 6 }
}

/// The player's background: the cover and its reflection shrunk to a few pixels and blurred, so a
/// soft wash of its colours fills the screen, and costs almost nothing to draw. Dark mode fades it
/// towards black. Light mode turns it into bright pastels of the same colours (`pastel`), because
/// white laid over a cover greys a dark one and bleaches a bright one. It fades from song to song.
struct PhoneAmbient: View {
    let url: URL?
    @State private var wash: UIImage?
    /// The last song's wash, kept underneath so the next fades in over it with no dark dip.
    @State private var previous: UIImage?
    @State private var shown = 0.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        ZStack {
            LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)
            if let previous { blurred(previous) }
            if let wash { blurred(wash).opacity(shown) }
            if scheme == .dark { Glass.scrim }
        }
        .task(id: "\(url?.path ?? "")\(scheme)") {
            guard let url, let image = await KnobShiftArtwork.load(url) else {
                previous = nil
                wash = nil
                return
            }
            let side = CGRect(x: 0, y: 0, width: 40, height: 40)
            previous = wash
            shown = 0
            // The whole cover with its reflection under it, so its strongest colours reach the bottom too.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let reflected = UIGraphicsImageRenderer(size: CGSize(width: side.width, height: side.height * 2), format: format).image { context in
                image.draw(in: side)
                context.cgContext.translateBy(x: 0, y: side.height * 2)
                context.cgContext.scaleBy(x: 1, y: -1)
                image.draw(in: side)
            }
            wash = scheme == .dark ? reflected : Self.pastel(reflected)
            // A frame at nothing first, so the fade has somewhere to start from.
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(Motion.ambient) { shown = 1 }
        }
        .accessibilityHidden(true)
    }

    private func blurred(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image).resizable().scaledToFill()
                    .blur(radius: scheme == .dark ? 40 : 90).saturation(scheme == .dark ? 1.5 : 1)
                    .scaleEffect(scheme == .dark ? 1.3 : 1.7)
            }
            .clipped()
    }

    /// Every pixel keeps its hue at one bright level and a capped strength, so text stays readable.
    /// Near black has no real colour of its own, so it fades to white instead of a random hue.
    private static func pastel(_ image: UIImage) -> UIImage {
        guard let source = image.cgImage else { return image }
        let width = source.width, height = source.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        for pixel in stride(from: 0, to: width * height * 4, by: 4) {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: CGFloat(data[pixel]) / 255, green: CGFloat(data[pixel + 1]) / 255, blue: CGFloat(data[pixel + 2]) / 255, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            let strength = min(saturation * 1.5, 0.5) * min(brightness / 0.2, 1)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            UIColor(hue: hue, saturation: strength, brightness: 0.96, alpha: 1).getRed(&red, green: &green, blue: &blue, alpha: nil)
            data[pixel] = UInt8(red * 255)
            data[pixel + 1] = UInt8(green * 255)
            data[pixel + 2] = UInt8(blue * 255)
        }
        return context.makeImage().map { UIImage(cgImage: $0) } ?? image
    }
}

/// A move through the song while the finger is down: the slider and the Play dial both show it,
/// and it is only played once the finger lifts.
@MainActor
final class PhoneScrub: ObservableObject {
    @Published var position: TimeInterval?
}

/// The song's position: the slider, the times, and what
/// KnobShift is doing between them, where Apple Music shows the audio quality. It alone watches
/// the playback clock, so ten updates a second redraw nothing else.
struct PhoneTimeline: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    @ObservedObject var scrub: PhoneScrub

    /// How many seconds ahead a planned mix is announced.
    private static let warning = 5

    var body: some View {
        let playing = model.nowPlaying != nil
        let duration = max(clock.duration, 1)
        let time = scrub.position ?? clock.time
        VStack(spacing: 0) {
            slider(playing: playing, time: time, duration: duration)
            ZStack {
                HStack {
                    Text(playing ? KnobShiftNowPlaying.clock(time) : "0:00")
                    Spacer()
                    Text(playing ? "-" + KnobShiftNowPlaying.clock(max(0, clock.duration - time)) : "0:00")
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Glass.secondary)
                chip
            }
        }
    }

    /// The iPhone's own slider. With nothing playing it is an empty line, since the slider
    /// shows its handle even with nothing to move.
    @ViewBuilder private func slider(playing: Bool, time: TimeInterval, duration: TimeInterval) -> some View {
        if playing {
            Slider(value: Binding(get: { min(time, duration) }, set: { scrub.position = $0 }), in: 0...duration) { editing in
                if !editing, let position = scrub.position {
                    model.seek(to: position)
                    scrub.position = nil
                }
            }
            .tint(Palette.accent)
            .accessibilityLabel("Position in song")
        } else {
            KnobGroove(value: 0, accessibilityLabel: "Position in song", accessibilityValue: "0:00", onChange: { _ in })
                .disabled(true)
        }
    }

    @ViewBuilder private var chip: some View {
        let lit = model.mixState == .mixing
        let text = chipText
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).tracking(0.4)
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(lit || countdown != nil ? Glass.onAccent : Glass.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Capsule().fill(lit ? Palette.accent : (countdown != nil ? Palette.accent.opacity(0.45) : Glass.fill)))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.snappy, value: text)
    }

    /// Seconds to a mix that is about to start: the last few of a planned one, or all of them
    /// once KnobMix Now has been tapped.
    private var countdown: Int? {
        guard let mix = model.nextMix, mix.blends, model.mixState != .mixing else { return nil }
        let left = Int(mix.at.timeIntervalSinceNow.rounded(.up))
        return left > 0 && (model.mixNowWaiting || left <= Self.warning) ? left : nil
    }

    private var chipText: String? {
        guard model.nowPlaying != nil else { return nil }
        if model.mixState == .mixing { return "KNOBMIX" }
        if let countdown { return "KNOBMIX IN \(countdown)" }
        if model.mixNowWaiting { return "KNOBMIX STARTING" }
        return model.mixState == .analyzing ? "PREPARING" : nil
    }
}

/// What the player has to say under its buttons: a problem first, or else where the sound is
/// going when that isn't the iPhone's speaker. It always keeps its height, so nothing moves.
struct PhoneCaption: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var output = PhoneOutputName.shared

    var body: some View {
        Text(model.notice ?? output.name ?? " ")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.notice != nil ? Palette.accent : Glass.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}
