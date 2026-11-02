import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the single KnobShift player window. It retains the shared model from KnobModel, so music
/// continues when the main menu-bar panel is closed and the player can be reopened without reset.
@MainActor
enum KnobShiftWindow {
    private static var window: NSWindow?
    private static let stateDelegate = WindowStateDelegate()
    private static var isTerminating = false

    static func show(model: KnobShiftModel) {
        present(model: model, activates: true)
    }

    /// Restores the player's presence, not merely its queue: a manually closed player stays
    /// closed on the next Knob launch, while an open player comes back where expected.
    static func restoreIfNeeded(model: KnobShiftModel) {
        guard UserDefaults.standard.bool(forKey: PersistKey.knobShiftWindowOpen.rawValue) else { return }
        present(model: model, activates: false)
    }

    static func prepareForTermination() {
        isTerminating = true
    }

    private static func present(model: KnobShiftModel, activates: Bool) {
        if window == nil {
            let host = NSHostingController(rootView: KnobShiftPlayerView(model: model).focusEffectDisabled())
            let created = NSWindow(contentViewController: host)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.title = "KnobShift"
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.minSize = KnobShiftPlayerView.minimumSize
            created.maxSize = KnobShiftPlayerView.maximumSize
            created.setContentSize(KnobShiftPlayerView.initialSize)
            created.center()
            created.delegate = stateDelegate
            window = created
        }
        UserDefaults.standard.set(true, forKey: PersistKey.knobShiftWindowOpen.rawValue)
        if activates { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    private final class WindowStateDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard !KnobShiftWindow.isTerminating else { return }
            UserDefaults.standard.set(false, forKey: PersistKey.knobShiftWindowOpen.rawValue)
        }
    }
}

/// KnobShift's player window: a now-playing deck beside Up Next and the queue, on Knob's
/// faceplate. The deck and cards are in KnobShiftNowPlaying.swift and KnobShiftQueue.swift.
/// Streaming services are not offered: Knob cannot safely or permissibly decode, preload and
/// overlap their protected audio streams.
struct KnobShiftPlayerView: View {
    static let minimumSize = CGSize(width: 440, height: 520)
    static let initialSize = CGSize(width: 820, height: 600)
    static let maximumSize = CGSize(width: 1_200, height: 900)

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: KnobShiftModel
    @AppStorage(PersistKey.knobShiftEnabled.rawValue) private var enabled = false
    @State private var importing = false
    @State private var showingSpotify = false

    var body: some View {
        let palette = Palette.of(scheme)
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header(palette)
                if enabled {
                    workspace(width: geometry.size.width)
                } else {
                    off(palette)
                }
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addTracks(urls) }
        }
        .onChange(of: enabled) { if !enabled { model.stop() } }
    }

    private func header(_ palette: Palette) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Palette.accent)
                .shadow(color: Palette.accentGlow.opacity(0.45), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("KNOBSHIFT").font(.system(size: 15, weight: .heavy)).tracking(1.6).foregroundStyle(palette.label)
                Text("Seamless mixes for the music on your Mac").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
            }
            Spacer()
            Toggle("KnobShift", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .accessibilityLabel("KnobShift on or off")
        }
    }

    @ViewBuilder private func workspace(width: CGFloat) -> some View {
        if width >= 760 {
            HStack(alignment: .top, spacing: 18) {
                KnobShiftNowPlaying(model: model, compact: false)
                VStack(spacing: 14) {
                    KnobShiftUpNext(model: model)
                    KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true })
                }
                .frame(width: min(360, width * 0.42))
            }
        } else {
            VStack(spacing: 12) {
                KnobShiftNowPlaying(model: model, compact: true)
                KnobShiftUpNext(model: model)
                KnobShiftQueue(model: model, onAdd: { importing = true }, onSpotify: { showingSpotify = true })
            }
        }
    }

    private func off(_ palette: Palette) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 30)).foregroundStyle(palette.faint)
            Text("KnobShift is off").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.label)
            Text("Turn it on to play your songs with smooth, beat matched mixes between them.")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
