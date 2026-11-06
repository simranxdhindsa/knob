import SwiftUI
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
    @StateObject private var scrub = PlayerScrub()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hidesPlayButton) private var hidesPlayButton
    @State private var importing = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                PhoneVinylDeck(model: model, scrub: scrub)
            } else {
                upright(geometry)
            }
        }
        .background { PlayerAmbient(url: (model.mixingInto ?? model.nowPlaying)?.url).ignoresSafeArea() }
        .sheet(item: $sheets.mac) { PhoneMacSheet(model: model, source: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let prepared = prepareImports(urls)
            Task { await model.addTracks(prepared) }
        }
        .onChange(of: canTurn, initial: true) { PhoneOrientation.allow(landscape: canTurn) }
    }

    /// The phone can turn to the record deck with a song loaded, and nothing else open.
    private var canTurn: Bool {
        model.nowPlaying != nil && !hidesPlayButton && !sheets.queue && !sheets.sound && sheets.mac == nil
    }

    private func upright(_ geometry: GeometryProxy) -> some View {
            let layout = PhonePlayerLayout(size: geometry.size, topInset: geometry.safeAreaInsets.top, queue: sheets.queue)
            return ZStack(alignment: .topLeading) {
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
            PlayerGlassGroup {
                HStack(spacing: 10) {
                    MixNowButton(model: model, clock: model.clock)
                    PlayerMoreMenu(model: model, onFiles: { importing = true }, onSpotify: { sheets.mac = .spotify },
                                   onYouTube: { sheets.mac = .youtube }, onSync: { sheets.mac = .sync })
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
            PlayerTimeline(model: model, clock: model.clock, scrub: scrub)
                .frame(height: PhonePlayerLayout.timeline)
            Spacer(minLength: 0)
            PlayerTransport(model: model, scrub: scrub, dialSize: layout.dial)
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
