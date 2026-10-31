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
            let host = NSHostingController(rootView: KnobShiftPlayerView(model: model))
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

/// Local music controls for KnobShift. The transport layout is a SwiftUI port of the MIT-licensed
/// 21st.dev MP3 Player by DeltaComponents. Its source-driven visualizer follows the MIT-licensed
/// 21st.dev Audio Visualizer by ebnsina, using KnobShift's local AVAudioEngine mixer as its source.
/// Both are restyled to fit Knob's hardware player. Streaming services are not offered:
/// Knob cannot safely or permissibly decode, preload and overlap their protected audio streams.
struct KnobShiftPlayerView: View {
    static let minimumSize = CGSize(width: 440, height: 400)
    static let initialSize = CGSize(width: 680, height: 520)
    static let maximumSize = CGSize(width: 1_200, height: 900)

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: KnobShiftModel
    @AppStorage(PersistKey.knobShiftEnabled.rawValue) private var enabled = false
    @AppStorage(PersistKey.knobShiftStyle.rawValue) private var styleName = KnobShiftModel.Style.gentle.rawValue
    @State private var importing = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    private var style: KnobShiftModel.Style { KnobShiftModel.Style(rawValue: styleName) ?? .gentle }

    var body: some View {
        let palette = Palette.of(scheme)
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().overlay(Screen.textTertiary.opacity(0.35))
                if enabled {
                    workspace(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Spacer()
                    Text("Turn on KnobShift to blend local music played in this window.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Screen.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addTracks(urls) }
        }
        .onChange(of: enabled) { if !enabled { model.stop() } }
        .onChange(of: model.playbackTime) { _, time in if !isScrubbing { scrubPosition = time } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 23))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("KNOBSHIFT").font(.system(size: 14, weight: .bold)).tracking(1.4).foregroundStyle(Screen.text)
                Text("LOCAL MUSIC TRANSITIONS").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textSecondary)
            }
            Spacer()
            Toggle("KnobShift", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NOW PLAYING").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
            Text(model.nowPlaying?.title ?? "Choose music from your Mac")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.nowPlaying == nil ? Screen.textSecondary : Screen.text)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func workspace(width: CGFloat, height: CGFloat) -> some View {
        let isWide = width >= 820
        let isMedium = width >= 610
        if isWide {
            HStack(alignment: .top, spacing: 20) {
                playerDeck(showVisualizer: true, logHeight: height - 470)
                Divider().overlay(Screen.textTertiary.opacity(0.35))
                queue(maxHeight: max(180, height - 120))
                    .frame(width: min(320, width * 0.34))
            }
        } else if isMedium {
            HStack(alignment: .top, spacing: 18) {
                playerDeck(showVisualizer: true, logHeight: height - 470)
                queue(maxHeight: max(160, height - 120))
                    .frame(width: min(260, width * 0.38))
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                playerDeck(showVisualizer: false, logHeight: 110)
                queue(maxHeight: max(90, height - 260))
            }
        }
    }

    private func playerDeck(showVisualizer: Bool, logHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SegmentedTabs(options: KnobShiftModel.Style.allCases,
                          selection: Binding(get: { style }, set: { styleName = $0.rawValue })) { $0.title }
                .frame(height: 30)
            nowPlaying
            transport
            shiftPlan
            if showVisualizer { visualizer }
            KnobShiftLogView(model: model, maxHeight: logHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shiftPlan: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("KNOBSHIFT PLAN").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                Spacer()
                if model.mixState == .mixing {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6)
                            .shadow(color: Palette.accentGlow, radius: 4)
                        Text("KNOBMIX")
                            .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(Palette.accent)
                } else {
                    Text(model.mixState.title)
                        .font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Screen.textSecondary)
                }
            }
            Text(model.transitionDescription)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Screen.textSecondary)
                .lineLimit(2)
        }
    }

    private var visualizer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PLAYBACK VISUALIZER").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                Spacer()
                Text(model.isPlaying ? "LIVE" : "IDLE").font(.system(size: 9, weight: .bold)).foregroundStyle(model.isPlaying ? Palette.accent : Screen.textTertiary)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: !model.isPlaying)) { _ in
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<42, id: \.self) { index in
                        let level = Double(model.visualizerLevels[safe: index] ?? 0.08)
                        let height = 8 + level * 38
                        Capsule()
                            .fill(index.isMultiple(of: 7) ? Palette.accent : Screen.textSecondary.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                    }
                }
                .frame(height: 52)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RecessedPill())
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.previous() } label: { Image(systemName: "backward.end.fill") }
            Button { model.pauseOrResume(style: style) } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.accent))
                    .foregroundStyle(.white)
            }
            Button { model.next() } label: { Image(systemName: "forward.end.fill") }
            Text(Self.time(scrubPosition)).frame(width: 32, alignment: .trailing)
            Slider(value: $scrubPosition, in: 0...max(model.playbackDuration, 1), onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { model.seek(to: scrubPosition) }
            })
            .tint(Palette.accent)
            .disabled(model.nowPlaying == nil)
            Text("-\(Self.time(max(0, model.playbackDuration - scrubPosition)))").frame(width: 36, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(model.tracks.isEmpty ? Screen.textTertiary : Screen.text)
        .disabled(model.tracks.isEmpty || model.isPreparing)
    }

    private func queue(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("QUEUE").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                Spacer()
                Button("+ ADD LOCAL MUSIC") { importing = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Palette.accent)
                if model.isPreparing { Text("PREPARING").font(.system(size: 9, weight: .bold)).foregroundStyle(Screen.textTertiary) }
            }
            if model.tracks.isEmpty {
                Text("Apple Music, Spotify and YouTube stay in their own players.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Screen.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.tracks) { track in
                            HStack(spacing: 8) {
                                Image(systemName: model.nowPlaying == track ? "speaker.wave.2.fill" : "music.note")
                                    .font(.system(size: 10)).foregroundStyle(model.nowPlaying == track ? Palette.accent : Screen.textSecondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.text).lineLimit(1)
                                    Text(track.analysis.summary).font(.system(size: 8.5, weight: .medium)).foregroundStyle(Screen.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                Text(Self.time(track.duration)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Screen.textTertiary)
                                Button { model.remove(track) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(Screen.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(track) }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
            if let notice = model.notice { Text(notice).font(.system(size: 10)).foregroundStyle(Palette.accent).lineLimit(1) }
        }
    }

    private static func time(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
