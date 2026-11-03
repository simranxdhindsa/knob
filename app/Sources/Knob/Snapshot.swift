import AppKit
import SwiftUI

/// Renders the panel offscreen with the demo engine, in light and dark, to PNG files.
/// Used for visual checks: `Knob --snapshot DIR` writes panel-light.png and panel-dark.png.
@MainActor
enum Snapshot {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        model.start()
        let presets = Preset.factory()
        if let preset = presets.first(where: { $0.name == "Music" }) ?? presets.first {
            model.select(preset)
        }
        Task { @MainActor in
            await model.refresh()
            model.panelOpened()
            try? await Task.sleep(for: .milliseconds(900))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for tab in ScreenSection.Tab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: PersistKey.selectedTab.rawValue)
                    render(PanelView(model: model).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("panel-\(name)-\(tab.rawValue).png"))
                }
            }
            // KnobShift's tab as a mini player, playing and mid-mix.
            UserDefaults.standard.set(ScreenSection.Tab.knobShift.rawValue, forKey: PersistKey.selectedTab.rawValue)
            for mixing in [false, true] {
                model.knobShift.showPreviewForSnapshot(mixing: mixing)
                for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    render(PanelView(model: model).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("panel-\(name)-knobShift-\(mixing ? "mixing" : "playing").png"))
                }
            }
            model.knobShift.stop()

            // KnobShift is a separate, resizable player. Render its two responsive breakpoints.
            // Both sizes, light and dark, playing and mid-mix.
            for mixing in [false, true] {
                let shift = KnobShiftModel(restoresQueue: false)
                shift.showPreviewForSnapshot(mixing: mixing)
                for (name, size) in [("compact", CGSize(width: 460, height: 720)), ("wide", CGSize(width: 900, height: 620))] {
                    for (schemeName, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                        render(KnobShiftPlayerView(model: shift)
                            .frame(width: size.width, height: size.height)
                            .environment(\.colorScheme, scheme), scheme: scheme,
                               to: folder.appendingPathComponent("knobshift-\(name)-\(schemeName)\(mixing ? "-mixing" : "").png"))
                    }
                }
            }
            // The Spotify sheet: its one time notice, and the form logged in with a status line.
            let spotify = KnobShiftModel(restoresQueue: false)
            spotify.showSpotifyPreviewForSnapshot()
            for (name, form) in [("notice", false), ("form", true)] {
                render(KnobShiftSpotifySheet(model: spotify, showsForm: form).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("knobshift-spotify-\(name).png"))
            }
            spotify.showSpotifyPickerForSnapshot()
            render(KnobShiftSpotifySheet(model: spotify, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-spotify-picker.png"))
            // The YouTube sheet: its one time notice, the form signed out and signed in, and the picker.
            let youtube = KnobShiftModel(restoresQueue: false)
            for (name, form) in [("notice", false), ("form", true)] {
                render(KnobShiftYouTubeSheet(model: youtube, showsForm: form).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("knobshift-youtube-\(name).png"))
            }
            render(KnobShiftGoogleKey(model: youtube, startsOpen: true).padding(22).frame(width: 460)
                    .background(Screen.bottom).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-key.png"))
            youtube.showYouTubeCodeForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-code.png"))
            youtube.showYouTubeLoadingForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-loading.png"))
            youtube.showYouTubePreviewForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-signedin.png"))
            youtube.showYouTubePickerForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-picker.png"))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                render(HeaderBar(model: model).knobMenu.padding(16).background(Palette.of(scheme).panelBottom)
                        .environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("knob-menu-\(name).png"))
            }
            render(KnobShiftAddMusicCard(onMac: {}, onSpotify: {}).padding(16)
                    .background(Screen.bottom).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-add-music.png"))
            render(KnobShiftSpotifyKey(model: spotify, startsOpen: true).padding(22).frame(width: 460)
                    .background(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom))
                    .environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-spotify-key.png"))
            model.panelClosed()

            // Engine off: what the panel looks like before the engine is installed or running.
            let offline = KnobModel(engine: SocketEngine(path: "/nonexistent/knob-engine.sock"), volume: DemoVolume())
            offline.start()
            await offline.refresh()
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for tab in ScreenSection.Tab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: PersistKey.selectedTab.rawValue)
                    render(PanelView(model: offline).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("offline-\(name)-\(tab.rawValue).png"))
                }
            }

            // Recovery messages and actions must fit alongside the real panel layout.
            for failure in StartupFailure.allCases {
                offline.showStartupFailure(failure)
                UserDefaults.standard.set(ScreenSection.Tab.effects.rawValue, forKey: PersistKey.selectedTab.rawValue)
                for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    render(PanelView(model: offline).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("recovery-\(failure)-\(name).png"))
                }
            }

            // Pressing ON with the engine off: the real launcher's checks, never a silent no-op.
            // (Runs the real device check; it only launches anything if Knob's device is installed.)
            let attempt = KnobModel(engine: SocketEngine(path: "/nonexistent/knob-engine.sock"), volume: DemoVolume(),
                                    launcher: EngineLauncher())
            attempt.start()
            await attempt.refresh()
            if !HardwareDevices.all().contains(where: { $0.uid == HardwareDevices.knobUID }) {
                attempt.setPower(true)
                try? await Task.sleep(for: .milliseconds(500))
                print("power-on notice: \(attempt.notice ?? "none")")
                UserDefaults.standard.set(ScreenSection.Tab.effects.rawValue, forKey: PersistKey.selectedTab.rawValue)
                render(PanelView(model: attempt).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("power-attempt-dark.png"))
            }
            exit(0)
        }
        app.run()
    }

    /// `Knob --icons DIR`: the app icon at 1024px, the installer background, and the About window in light and dark.
    static func renderArtwork(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            render(AppIconView(size: 1024), scheme: .dark, to: folder.appendingPathComponent("icon-1024.png"))
            render(AppIconView(size: 1024, fullBleed: true), scheme: .dark, to: folder.appendingPathComponent("icon-ios-1024.png"))
            // The iPhone launch image: the opening's first frame, at 2x and 3x (renders are 2x).
            render(LaunchKnobPose(value: 0.68, size: 220), scheme: .dark, to: folder.appendingPathComponent("launch-knob@2x.png"))
            render(LaunchKnobPose(value: 0.68, size: 330), scheme: .dark, to: folder.appendingPathComponent("launch-knob@3x.png"))
            render(InstallerBackgroundView(), scheme: .light, to: folder.appendingPathComponent("installer-background.png"))
            let statuses: [(String, UpdateStatus)] = [("checking", .checking), ("downloading", .downloading(progress: nil)),
                                                     ("installing", .installing), ("uptodate", .upToDate),
                                                     ("failed", .failed(message: "Couldn't update Knob. It will try again later."))]
            for (name, status) in statuses {
                render(UpdateStatusLabel(status: status).padding(8).background(Palette.dark.panelTop)
                        .environment(\.colorScheme, .dark),
                       scheme: .dark, to: folder.appendingPathComponent("update-\(name).png"))
            }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                render(AboutView().environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("about-\(name).png"))
            }
            exit(0)
        }
        app.run()
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
