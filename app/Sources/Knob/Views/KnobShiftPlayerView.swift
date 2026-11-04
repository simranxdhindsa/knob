import SwiftUI
import UniformTypeIdentifiers

/// KnobShift's player on the Mac: a now-playing deck beside Up Next and the queue, on Knob's
/// faceplate, in its own window (KnobShiftWindow.swift). The deck and cards are in
/// KnobShiftNowPlaying.swift and KnobShiftQueue.swift. The iPhone has its own (PhonePlayer).
struct KnobShiftPlayerView: View {
    static let minimumSize = CGSize(width: 440, height: 520)
    static let initialSize = CGSize(width: 820, height: 600)
    static let maximumSize = CGSize(width: 1_200, height: 900)

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: KnobShiftModel
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
            .padding(20)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background {
            ZStack {
                LinearGradient(colors: [palette.panelTop, palette.panelBottom], startPoint: .top, endPoint: .bottom)
                Grain(opacity: palette.grain)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingSpotify) { KnobShiftSpotifySheet(model: model).focusEffectDisabled() }
        .sheet(isPresented: $showingYouTube) { KnobShiftYouTubeSheet(model: model).focusEffectDisabled() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addTracks(urls) }
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
        }
    }

    private var queue: some View {
        KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true }, onYouTube: { showingYouTube = true })
    }

    @ViewBuilder private func workspace(width: CGFloat) -> some View {
        if width >= 760 {
            HStack(alignment: .top, spacing: 18) {
                KnobShiftNowPlaying(model: model, compact: false)
                VStack(spacing: 14) {
                    KnobShiftUpNext(model: model)
                    queue
                }
                .frame(width: min(360, width * 0.42))
            }
        } else {
            VStack(spacing: 12) {
                KnobShiftNowPlaying(model: model, compact: true)
                KnobShiftUpNext(model: model)
                queue
            }
        }
    }
}
