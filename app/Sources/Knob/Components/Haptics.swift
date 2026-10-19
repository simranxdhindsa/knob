import AppKit

/// Trackpad haptics for the hardware controls: a soft tick for each notch while turning, a firmer
/// click at the ends and at a fader's centre. Does nothing on Macs without a Force Touch trackpad.
enum Haptics {
    /// Notches across a knob's full turn, or a fader's full travel.
    static let notches = 20

    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    static func detent() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }

    /// Plays the right feedback for a control moving from `old` to `new` (both 0...1): a click on
    /// reaching either end, a tick on crossing a notch.
    static func moved(from old: Double, to new: Double) {
        if (old > 0 && new == 0) || (old < 1 && new == 1) { detent(); return }
        if Int((old * Double(notches)).rounded(.down)) != Int((new * Double(notches)).rounded(.down)) { tick() }
    }
}
