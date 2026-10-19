import AppKit
import SwiftUI

/// App-level behaviour: Dock icon, clicking the Dock icon, and quitting safely.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `KnobApp` at launch so quitting can stop the engine first.
    @MainActor static weak var model: KnobModel?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.apply()
    }

    /// Clicking the Dock icon opens the Knob panel from the menu bar.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Activate first, then press the menu bar button on the next beat: pressing it while the
        // app is still becoming active let the panel open and close again straight away.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { StatusItemPanel.open() }
        return false
    }

    /// Quit from the Dock, ⌘Q or the app menu: save the sound, give the speakers back, stop the
    /// engine, then quit. Dev mode relaunches on every save, so it keeps the engine running.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["KNOB_DEV_OPEN_POPOVER"] != "1", let model = Self.model
        else { return .terminateNow }
        Task { @MainActor in
            await model.stopEngine()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
