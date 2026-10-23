import AppKit
import SwiftUI

/// Launch options:
///   (none)              real engine and real Mac volume
///   --demo              demo engine and demo volume, for trying the panel without the engine
///   --snapshot DIR      render the panel in light and dark mode to PNG files, then quit
///   --icons DIR         render the app icon (1024px) and the About window, then quit
///   --volume-check SEC  print real Mac volume changes for SEC seconds, set and restore, then quit
@main
struct KnobLauncher {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Snapshot.run(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if let index = arguments.firstIndex(of: "--icons"), index + 1 < arguments.count {
            Snapshot.renderArtwork(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if let index = arguments.firstIndex(of: "--volume-check"), index + 1 < arguments.count {
            VolumeCheck.run(seconds: Double(arguments[index + 1]) ?? 3)
            return
        }
        KnobApp.main()
    }
}

struct KnobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: KnobModel

    init() {
        let demo = CommandLine.arguments.contains("--demo")
        let model = KnobModel(engine: demo ? DemoEngine() : SocketEngine(),
                              volume: demo ? DemoVolume() : SystemVolume(),
                              launcher: demo ? nil : EngineLauncher())
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
        model.start()
        model.restorePower()
        Updater.shared.start()
        DispatchQueue.main.async { DevWindow.showIfRequested(model: model) }
        ProcessInfo.processInfo.disableAutomaticTermination("Knob lives in the menu bar")
        if ProcessInfo.processInfo.environment["KNOB_DEV_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { StatusItemPanel.open() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.powerOn ? "dial.medium.fill" : "dial.medium")
                .accessibilityLabel("Knob")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Knob") { AboutWindow.show() }
            }
        }
    }
}
