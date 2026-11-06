import SwiftUI
import UniformTypeIdentifiers

/// KnobShift's player on the Mac, in its own window (KnobShiftWindow.swift), in the same modern
/// finish as the iPhone player: the cover runs to the window's edges and melts into a blurred wash
/// of its own colours, above the song with KnobMix and more beside it on glass, the position
/// slider and the transport around the Play dial. Up Next and the queue sit on glass beside it in
/// a wide window; a narrow one shows them in the cover's place from the queue button. Full screen
/// (KnobShiftPlayerView+Poster.swift) shows the whole cover instead, with nothing laid over it.
struct KnobShiftPlayerView: View {
    static let minimumSize = CGSize(width: 440, height: 520)
    static let initialSize = CGSize(width: 820, height: 600)
    static let maximumSize = CGSize(width: 1_200, height: 900)
    /// From this width the queue sits beside the player.
    static let wide: CGFloat = 760

    @ObservedObject var model: KnobShiftModel
    @StateObject var scrub = PlayerScrub()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Full screen shows the record deck instead of the cover, from the switch at its top.
    @AppStorage(PersistKey.knobShiftVinyl.rawValue) var vinyl = false
    @AppStorage(PersistKey.knobShiftTipsSeen.rawValue) var tipsSeen = ""
    /// The song on the deck, so the name changes with the cover rather than ahead of it.
    @State var deckSong: KnobShiftModel.Track?
    @ObservedObject private var together = KnobShiftTogetherSession.shared
    @State private var importing = false
    @State private var showingSpotify = false
    @State private var showingYouTube = false
    /// A narrow window's queue, shown in the cover's place.
    @State private var showingQueue = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wide
            let poster = KnobShiftPosterLayout.fits(geometry.size)
            HStack(spacing: 0) {
                if poster {
                    posterDeck(wide: wide)
                } else {
                    deck(wide: wide).overlay(alignment: .top) { fullScreenTip }
                }
                if wide {
                    sidebar(poster: poster).frame(width: KnobShiftPosterLayout.sidebar(geometry.size.width, poster: poster))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: poster)
            .onChange(of: poster, initial: true) { if poster { DeckTip.fullScreen.mark(in: &tipsSeen) } }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background { PlayerAmbient(url: (model.mixingInto ?? model.nowPlaying)?.url).ignoresSafeArea() }
        .environment(\.surface, .glass)
        .sheet(isPresented: $showingSpotify) { KnobShiftSpotifySheet(model: model).focusEffectDisabled() }
        .sheet(isPresented: $together.showing) { KnobShiftTogetherView(model: model).focusEffectDisabled() }
        .sheet(isPresented: $showingYouTube) { KnobShiftYouTubeSheet(model: model).focusEffectDisabled() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addTracks(urls) }
        }
    }

    /// Full screen is where the record deck is, and nothing in the window says so.
    @ViewBuilder private var fullScreenTip: some View {
        if model.nowPlaying != nil, !DeckTip.fullScreen.isSeen(in: tipsSeen) {
            DeckTipBubble(tip: .fullScreen, action: ("Full screen", { NSApp.keyWindow?.toggleFullScreen(nil) }),
                          onClose: { DeckTip.fullScreen.mark(in: &tipsSeen) })
                .frame(maxWidth: 340)
                .padding(.top, 40)
                .padding(.horizontal, 16)
                .transition(.opacity)
        }
    }

    private func deck(wide: Bool) -> some View {
        GeometryReader { geometry in
            let layout = KnobShiftPlayerLayout(size: geometry.size, wide: wide)
            let queue = !wide && showingQueue
            ZStack(alignment: .top) {
                if model.nowPlaying == nil {
                    // With no song there is no cover to melt, only a note on the plain background.
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: layout.coverSpace)
                        .opacity(queue ? 0 : 1)
                        .accessibilityHidden(true)
                } else {
                    cover(layout, hidden: queue)
                }
                if queue {
                    sidebar(poster: false)
                        .frame(height: layout.coverSpace)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity))
                }
                controls(wide: wide)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: queue)
        }
        // Under the see-through title bar, so the cover reaches the window's top edge.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The cover from the top of the window, melting away towards the song's name, and towards
    /// the queue beside it in a wide window. Pausing eases it back and dims it.
    private func cover(_ layout: KnobShiftPlayerLayout, hidden: Bool) -> some View {
        KnobShiftCover(model: model, clock: model.clock, size: layout.side, animated: model.isPlaying, corner: 0)
            // A soft shade behind the window buttons, for bright covers.
            .overlay(alignment: .top) {
                LinearGradient(colors: [Glass.scrim, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
            }
            .mask { LinearGradient(stops: Self.melt, startPoint: .top, endPoint: .bottom) }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: layout.wide ? 0.8 : 1), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .brightness(model.isPlaying ? 0 : -0.1)
            .scaleEffect(model.isPlaying ? 1.04 : 1, anchor: .top)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: model.isPlaying)
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .clipped()
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(false)
    }

    private static let melt: [Gradient.Stop] = [
        .init(color: .black, location: 0.34), .init(color: .black.opacity(0.86), location: 0.46),
        .init(color: .black.opacity(0.58), location: 0.6), .init(color: .black.opacity(0.28), location: 0.74),
        .init(color: .black.opacity(0.08), location: 0.88), .init(color: .clear, location: 1),
    ]

    private func controls(wide: Bool) -> some View {
        VStack(spacing: 0) {
            titleRow(wide: wide)
                .frame(height: KnobShiftPlayerLayout.title)
            PlayerTimeline(model: model, clock: model.clock, scrub: scrub)
                .frame(height: KnobShiftPlayerLayout.timeline)
            PlayerTransport(model: model, scrub: scrub, dialSize: KnobShiftPlayerLayout.dial)
                .frame(height: KnobShiftPlayerLayout.dial)
            Text(model.notice ?? " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(height: KnobShiftPlayerLayout.caption)
        }
        .padding(.horizontal, KnobShiftPlayerLayout.margin)
        .padding(.bottom, KnobShiftPlayerLayout.bottom)
    }

    func titleRow(wide: Bool, scale: CGFloat = 1, song: KnobShiftModel.Track? = nil) -> some View {
        let track = song ?? model.nowPlaying
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track?.name ?? "Nothing playing")
                    .font(.system(size: 21 * scale, weight: .semibold)).foregroundStyle(Glass.text)
                Text(track?.artist ?? (track != nil ? "Local music" : (model.tracks.isEmpty ? "Add songs from the dots" : "Press Play to start")))
                    .font(.system(size: 16 * scale)).foregroundStyle(Glass.secondary)
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.gentle, value: track?.id)
            Spacer(minLength: 0)
            PlayerGlassGroup {
                HStack(spacing: 10) {
                    MixNowButton(model: model, clock: model.clock)
                    if !wide { queueButton }
                    PlayerMoreMenu(model: model, onFiles: { importing = true }, onSpotify: { showingSpotify = true },
                                   onYouTube: { showingYouTube = true })
                }
            }
        }
    }

    private var queueButton: some View {
        Button {
            Haptics.tick()
            showingQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(showingQueue ? Palette.accent : Glass.text)
                .frame(width: 40, height: 40)
                .playerGlass()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showingQueue ? "Hide the queue" : "Show the queue")
    }

    private func sidebar(poster: Bool) -> some View {
        VStack(spacing: 14) {
            KnobShiftUpNext(model: model)
            KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true }, onYouTube: { showingYouTube = true })
        }
        // Clear of the window's close, minimise and zoom buttons, which full screen doesn't have.
        .padding(.top, poster ? 18 : 38)
        .padding([.horizontal, .bottom], 18)
    }
}

/// Where the Mac player's parts sit, worked out from the deck's size. The cover is a square at
/// least as wide as the deck, so its sides run off the edges, and tall enough for its melt to
/// reach the song's name.
struct KnobShiftPlayerLayout {
    static let margin: CGFloat = 28, title: CGFloat = 56, timeline: CGFloat = 60, dial: CGFloat = 112
    static let caption: CGFloat = 22, bottom: CGFloat = 12
    /// How far the cover's bottom edge reaches past the top of the song's name.
    private static let overlap: CGFloat = 48
    static var controls: CGFloat { title + timeline + dial + caption + bottom }

    let size: CGSize
    let wide: Bool

    /// The space above the song's name.
    var coverSpace: CGFloat { max(size.height - Self.controls, 0) }
    var side: CGFloat { max(size.width, coverSpace + Self.overlap) }
}
