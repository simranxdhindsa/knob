import AppKit
import SwiftUI

/// App-level behaviour: Dock icon, clicking the Dock icon, and quitting safely.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `KnobApp` at launch so quitting can stop the engine first.
    @MainActor static weak var model: KnobModel?
    /// Longer than stopping the engine can take: three requests of a second or two each.
    private static let quitLimit: TimeInterval = 8
    @MainActor private var quitAnswered = false

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.apply()
    }

    /// Clicking the Dock icon brings back Knob's windows (the KnobShift player, About) when one is
    /// minimised or open, as every Mac app does; with none, it opens the Knob panel from the
    /// menu bar.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // Pick real windows by their style, not `canBecomeMain`: a minimised window reports
        // false for that, so it was never found and the Dock click left it in the Dock.
        let windows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
        }
        if !windows.isEmpty {
            for window in windows where window.isMiniaturized { window.deminiaturize(nil) }
            windows.first?.makeKeyAndOrderFront(nil)
            return false
        }
        // Activate first, then press the menu bar button on the next beat: pressing it while the
        // app is still becoming active let the panel open and close again straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { StatusItemPanel.open() }
        return false
    }

    /// Quit from the Dock, ⌘Q or the app menu: save the sound, give the speakers back, stop the
    /// engine, then quit. Dev mode relaunches on every save, so it keeps the engine running.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        KnobShiftWindow.prepareForTermination()
        guard ProcessInfo.processInfo.environment["KNOB_DEV_OPEN_POPOVER"] != "1", let model = Self.model
        else { return .terminateNow }
        Task { @MainActor in
            await model.stopEngine()
            answerQuit()
        }
        // A timer still fires if `terminate` ever started from main actor work, which would hold
        // the task above back for good. Knob then quits without waiting for the engine.
        let backstop = Timer(timeInterval: Self.quitLimit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.quitAnswered == false else { return }
                model.abandonEngine()
                self?.answerQuit()
            }
        }
        RunLoop.main.add(backstop, forMode: .common)
        return .terminateLater
    }

    @MainActor private func answerQuit() {
        guard !quitAnswered else { return }
        quitAnswered = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Quits from Knob's own menu. `terminate` waits for the answer above inside its own event
    /// loop, and main actor work can't run until whatever called it returns, so calling it from a
    /// task or a main queue block never finishes: Knob stays open and ignores every later Quit.
    /// The run loop calls this block outside all of that.
    @MainActor static func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

/// Whether Knob shows in the Dock and the ⌘-Tab switcher (on by default).
@MainActor
enum DockPresence {
    static var isShown: Bool {
        UserDefaults.standard.object(forKey: PersistKey.showInDock.rawValue) as? Bool ?? true
    }

    static func apply(_ shown: Bool? = nil) {
        NSApp.setActivationPolicy((shown ?? isShown) ? .regular : .accessory)
    }
}

/// Opens the Knob panel from its menu bar icon. SwiftUI has no API for this, so it clicks
/// Knob's own status bar button. Used by the Dock icon and by dev mode after a relaunch.
@MainActor
enum StatusItemPanel {
    static func open() {
        let button = NSApp.windows
            .filter { $0.className.contains("StatusBarWindow") }
            .compactMap { $0.contentView.flatMap(findButton) }
            .first
        guard let button else { NSLog("Knob: menu bar button not found"); return }
        button.performClick(nil)
    }

    private static func findButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews { if let found = findButton(in: subview) { return found } }
        return nil
    }
}
