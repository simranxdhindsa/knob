import AppKit
import SwiftUI

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
            // Always dark: only white text can sit on the cover's real colours, spread over the
            // whole window. Light text colours would need a pale wash over them.
            created.appearance = NSAppearance(named: .darkAqua)
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.minSize = KnobShiftPlayerView.minimumSize
            created.maxSize = KnobShiftPlayerView.maximumSize
            created.setContentSize(KnobShiftPlayerView.initialSize)
            created.center()
            // Comes back where it was left, at the size it was left.
            created.setFrameUsingName("KnobShiftWindow")
            created.setFrameAutosaveName("KnobShiftWindow")
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
