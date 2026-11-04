import AppKit
import SwiftUI

/// Launch options:
///   (none)              real engine and real Mac volume
///   --demo              demo engine and demo volume, for trying the panel without the engine
///   --snapshot DIR      render the panel in light and dark mode to PNG files, then quit
///   --icons DIR         render the app icon (1024px) and the About window, then quit
///   --demo-frames DIR   record the panel through a scripted story as 30fps PNG frames, then quit
///   --volume-check SEC  print real Mac volume changes for SEC seconds, set and restore, then quit
///   --knobshift-analysis-check FILE  analyse a local file without opening an audio output device
///   --knobshift-mix-check            KnobMix's transition rules against the real planner, no audio
@main
struct KnobLauncher {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Snapshot.run(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if let index = arguments.firstIndex(of: "--demo-frames"), index + 1 < arguments.count {
            DemoFrames.run(into: URL(fileURLWithPath: arguments[index + 1]))
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
        if let index = arguments.firstIndex(of: "--knobshift-check"), index + 2 < arguments.count {
            // Optional third value: listening volume from 0 to 100 (default muted).
            let volume = index + 3 < arguments.count ? (Float(arguments[index + 3]) ?? 0) / 100 : 0
            KnobShiftSmokeCheck.run(first: URL(fileURLWithPath: arguments[index + 1]),
                                    second: URL(fileURLWithPath: arguments[index + 2]), volume: volume)
            return
        }
        if let index = arguments.firstIndex(of: "--knobshift-mixnow-check"), index + 3 < arguments.count {
            // Seeks to the given second, presses KnobMix Now and checks it waits for the beat.
            KnobShiftSmokeCheck.run(first: URL(fileURLWithPath: arguments[index + 1]),
                                    second: URL(fileURLWithPath: arguments[index + 2]),
                                    mixNowAt: Double(arguments[index + 3]) ?? 60)
            return
        }
        if let index = arguments.firstIndex(of: "--knobshift-sync-check"), index + 2 < arguments.count {
            KnobShiftAnalysisCheck.runSync(first: URL(fileURLWithPath: arguments[index + 1]),
                                           second: URL(fileURLWithPath: arguments[index + 2]))
            return
        }
        if let index = arguments.firstIndex(of: "--knobshift-spotify-check"), index + 1 < arguments.count {
            KnobShiftSpotifyCheck.run(Array(arguments[(index + 1)...]))
            return
        }
        if arguments.contains("--knobshift-link-check") {
            MainActor.assumeIsolated { KnobShiftLinkCheck.run() }
            return
        }
        if arguments.contains("--knobshift-link-serve") {
            MainActor.assumeIsolated { KnobShiftLinkCheck.serve() }
            return
        }
        if arguments.contains("--knobshift-mix-check") {
            MainActor.assumeIsolated { KnobShiftMixTests.run() }
            exit(MainActor.assumeIsolated { KnobShiftMixTests.failures } == 0 ? 0 : 1)
        }
        if let index = arguments.firstIndex(of: "--knobshift-youtube-check"), index + 1 < arguments.count {
            KnobShiftYouTubeCheck.run(Array(arguments[(index + 1)...]))
            return
        }
        if let index = arguments.firstIndex(of: "--knobshift-stems-check"), index + 4 < arguments.count {
            KnobShiftAnalysisCheck.runStems(file: URL(fileURLWithPath: arguments[index + 1]),
                                            start: Double(arguments[index + 2]) ?? 0, length: Double(arguments[index + 3]) ?? 20,
                                            folder: URL(fileURLWithPath: arguments[index + 4]))
            return
        }
        if let index = arguments.firstIndex(of: "--knobshift-analysis-check"), index + 1 < arguments.count {
            KnobShiftAnalysisCheck.run(file: URL(fileURLWithPath: arguments[index + 1]))
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
        // Offers the KnobShift playlists to Knob on the iPhone, over the home Wi-Fi.
        KnobShiftLinkServer.shared.start(model: model.knobShift)
        // Now Playing in Control Center and the keyboard's play keys.
        KnobShiftNowPlayingCenter.shared.start(model: model.knobShift)
        DispatchQueue.main.async {
            DevWindow.showIfRequested(model: model)
            KnobShiftWindow.restoreIfNeeded(model: model.knobShift)
        }
        ProcessInfo.processInfo.disableAutomaticTermination("Knob lives in the menu bar")
        if ProcessInfo.processInfo.environment["KNOB_DEV_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { StatusItemPanel.open() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
            // Knob never draws macOS's blue focus ring; pointer highlights show what is active.
            .focusEffectDisabled()
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
