import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPhone's main screen, laid out like Apple Music's player in a modern finish: a blurred,
/// darkened copy of the cover fills the screen, under a large cover, the song with KnobMix and
/// more beside it on glass, the position slider, the transport around the Play dial, the
/// iPhone's volume, and three buttons along the bottom for Knob's sound, the output and the
/// queue. Pausing shrinks the cover back. The queue button shrinks it to the corner and opens the
/// queue in its place, while the song and the controls stay. The cover moves as one view, by
/// transform only.
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
            let layout = PhonePlayerLayout(size: geometry.size, queue: sheets.queue)
            ZStack(alignment: .topLeading) {
                cover(layout)
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
        // Always dark, like Apple Music's player, so the clock and battery read on the wash too.
        .preferredColorScheme(.dark)
        .environment(\.glassCards, true)
        .sheet(item: $sheets.mac) { PhoneMacSheet(model: model, source: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let prepared = prepareImports(urls)
            Task { await model.addTracks(prepared) }
        }
    }

    private func cover(_ layout: PhonePlayerLayout) -> some View {
        let scale = sheets.queue ? PhonePlayerLayout.small / layout.side : (model.isPlaying ? 1 : PhonePlayerLayout.paused)
        return KnobShiftCover(model: model, clock: model.clock, size: layout.side, animated: model.isPlaying,
                              corner: sheets.queue ? 0.13 : 0.035)
            .scaleEffect(scale)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.knob, value: model.isPlaying)
            .position(layout.cover)
            .onTapGesture { sheets.queue = false }
            .allowsHitTesting(sheets.queue)
    }

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
            PhoneTransport(model: model, scrub: scrub, dialSize: layout.dial)
                .frame(height: layout.dial)
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
        .frame(width: layout.width, height: layout.lower)
        .offset(x: PhonePlayerLayout.margin, y: layout.lowerTop)
    }
}

/// Where everything on the player sits, worked out from the screen, so the cover fills what the
/// controls leave and every phone gets the same layout.
struct PhonePlayerLayout {
    static let margin: CGFloat = 24, top: CGFloat = 10, title: CGFloat = 56, timeline: CGFloat = 60
    static let volume: CGFloat = 34, buttons: CGFloat = 44, caption: CGFloat = 20
    /// The cover's size in the queue, and its share of full size while paused.
    static let small: CGFloat = 60, paused: CGFloat = 0.76

    let size: CGSize
    let queue: Bool

    var width: CGFloat { size.width - 2 * Self.margin }
    /// The Play dial, smaller on short phones.
    var dial: CGFloat { size.height < 720 ? 100 : 118 }
    var lower: CGFloat { Self.timeline + dial + Self.volume + Self.buttons + Self.caption }
    var lowerTop: CGFloat { size.height - lower }
    private var coverSpace: CGFloat { lowerTop - Self.title - Self.top - 14 }
    var side: CGFloat { max(120, min(width, coverSpace)) }
    private var playerCover: CGPoint { CGPoint(x: size.width / 2, y: Self.top + coverSpace / 2) }
    private var smallCover: CGPoint { CGPoint(x: Self.margin + Self.small / 2, y: Self.top + Self.small / 2) }
    var cover: CGPoint { queue ? smallCover : playerCover }

    var titleX: CGFloat { Self.margin + (queue ? Self.small + 12 : 0) }
    var titleY: CGFloat { queue ? smallCover.y - Self.title / 2 : lowerTop - Self.title - 6 }
    var titleWidth: CGFloat { width - (queue ? Self.small + 12 : 0) }
    var queueTop: CGFloat { Self.top + Self.small + 12 }
    var queueHeight: CGFloat { lowerTop - queueTop - 6 }
}

/// The player's background: the cover shrunk to a few pixels, blurred and darkened, so it is a
/// soft wash of the song's colours that costs almost nothing to draw. It fades from song to song.
struct PhoneAmbient: View {
    let url: URL?
    @State private var wash: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom)
            if let wash {
                Color.clear
                    .overlay {
                        Image(uiImage: wash).resizable().scaledToFill()
                            .blur(radius: 40).saturation(1.5).scaleEffect(1.3)
                    }
                    .clipped()
                    .id(wash)
                    .transition(.opacity)
            }
            Glass.scrim
        }
        .animation(Motion.ambient, value: wash)
        .task(id: url) {
            guard let url, let image = await KnobShiftArtwork.load(url) else { wash = nil; return }
            let size = CGSize(width: 40, height: 40)
            wash = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        .accessibilityHidden(true)
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
                    Text(playing ? KnobShiftNowPlaying.clock(max(0, clock.duration - time)) + " left" : "0:00")
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Glass.secondary)
                chip
            }
        }
    }

    /// The iPhone's own slider. With nothing playing it is an empty line, since the slider shows its handle even with nothing to move.
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
        if let text = chipText {
            Text(text)
                .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                .foregroundStyle(lit ? Glass.text : Glass.secondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(lit ? Palette.accent : Glass.fill))
                .animation(Motion.gentle, value: lit)
        }
    }

    private var chipText: String? {
        guard model.nowPlaying != nil else { return nil }
        if model.mixState == .mixing { return "KNOBMIX" }
        if model.mixNowWaiting { return "ON THE NEXT BEAT" }
        switch model.mixState {
        case .preservingEnding: return "FULL ENDING"
        case .analyzing: return "PREPARING"
        default: return model.nowPlaying?.analysis.tempo.map { String(format: "%.0f BPM", $0) }
        }
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
