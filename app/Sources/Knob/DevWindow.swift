import AppKit
import SwiftUI

/// Dev mode only (`npm run dev` launches Knob with KNOB_DEV_OPEN_POPOVER=1): shows the panel in a
/// floating window too, so every relaunch puts it on screen without clicking the menu bar icon,
/// which the MacBook notch can hide. It never takes keyboard focus away from the editor.
@MainActor
enum DevWindow {
    private static var window: NSWindow?

    static func showIfRequested(model: KnobModel) {
        guard ProcessInfo.processInfo.environment["KNOB_DEV_OPEN_POPOVER"] == "1", window == nil else { return }
        let host = NSHostingView(rootView: PanelView(model: model).focusEffectDisabled())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Knob (dev)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host
        // Remembers where you dragged it, across relaunches.
        if !window.setFrameUsingName("KnobDevWindow") { window.center() }
        window.setFrameAutosaveName("KnobDevWindow")
        window.orderFrontRegardless()
        self.window = window
    }
}
