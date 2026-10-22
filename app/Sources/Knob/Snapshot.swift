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
        model.select(Preset.factory().first { $0.name == "Music" } ?? Preset.factory().first!)
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
