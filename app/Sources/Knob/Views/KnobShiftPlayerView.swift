import SwiftUI
import UniformTypeIdentifiers

/// KnobShift's player: a now-playing deck beside Up Next and the queue, on Knob's faceplate. The
/// Mac shows it in its own window (KnobShiftWindow.swift); the iPhone app's main screen is this
/// player, with Knob's sound controls behind the header's sound button. The deck and cards are in
/// KnobShiftNowPlaying.swift and KnobShiftQueue.swift.
/// Streaming services are not offered: Knob cannot safely or permissibly decode, preload and
/// overlap their protected audio streams.
struct KnobShiftPlayerView: View {
    static let minimumSize = CGSize(width: 440, height: 520)
    static let initialSize = CGSize(width: 820, height: 600)
    static let maximumSize = CGSize(width: 1_200, height: 900)

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: KnobShiftModel
    /// Shows a sound button in the header that opens Knob's controls (the iPhone app).
    var onSound: (() -> Void)?
    /// Songs picked to add, before they join the queue: the iPhone copies them into the app.
    var prepareImports: ([URL]) -> [URL] = { $0 }
    @State private var importing = false
    @State private var showingSpotify = false
    @State private var showingYouTube = false

    var body: some View {
        let palette = Palette.of(scheme)
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header(palette)
                workspace(width: geometry.size.width)
            }
            .padding(onSound == nil ? 20 : 16)
        }
        #if os(macOS)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        #endif
        .background {
            ZStack {
                LinearGradient(colors: [palette.panelTop, palette.panelBottom], startPoint: .top, endPoint: .bottom)
                Grain(opacity: palette.grain)
            }
            .ignoresSafeArea()
        }
        #if os(macOS)
        .sheet(isPresented: $showingSpotify) { KnobShiftSpotifySheet(model: model).focusEffectDisabled() }
        .sheet(isPresented: $showingYouTube) { KnobShiftYouTubeSheet(model: model).focusEffectDisabled() }
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let prepared = prepareImports(urls)
            Task { await model.addTracks(prepared) }
        }
    }

    private func header(_ palette: Palette) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Palette.accent)
                .shadow(color: Palette.accentGlow.opacity(0.45), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("KNOBSHIFT").font(.system(size: 15, weight: .heavy)).tracking(1.6).foregroundStyle(palette.label)
                Text("Seamless mixes for the music on your \(Platform.deviceName)").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
            }
            Spacer()
            if let onSound {
                Button(action: onSound) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .frame(width: 40, height: 40)
                        .background(RecessedPill())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Knob sound: effects, equalizer and presets")
            }
        }
    }

    @ViewBuilder private func workspace(width: CGFloat) -> some View {
        if width >= 760 {
            HStack(alignment: .top, spacing: 18) {
                KnobShiftNowPlaying(model: model, compact: false)
                VStack(spacing: 14) {
                    KnobShiftUpNext(model: model)
                    KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true }, onYouTube: { showingYouTube = true })
                }
                .frame(width: min(360, width * 0.42))
            }
        } else {
            VStack(spacing: 12) {
                KnobShiftNowPlaying(model: model, compact: true)
                KnobShiftUpNext(model: model)
                KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true }, onYouTube: { showingYouTube = true })
            }
        }
    }
}
