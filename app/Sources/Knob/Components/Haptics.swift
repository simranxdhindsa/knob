import AppKit

/// Trackpad haptics for the hardware controls, felt like a stepped studio pot: a light tick every
/// 2.5% while turning, a firmer click on each of the eleven printed marks (0 to 10), and the
/// firmest click at the ends and at a fader's centre. Ticks are spaced at least 12 ms apart, so a
/// fast spin feels like a run of notches instead of a buzz. Does nothing on Macs without a Force
/// Touch trackpad.
enum Haptics {
    /// Light notches across a full turn, and the printed marks they fall between.
    static let notches = 40
    static let marks = 10

    nonisolated(unsafe) private static var lastTick = Date.distantPast

    static func tick() { perform(.alignment, spaced: true) }
    static func mark() { perform(.generic, spaced: false) }
    static func detent() { perform(.levelChange, spaced: false) }

    /// Plays the right feedback for a control moving from `old` to `new` (both 0...1): the
    /// firmest click on reaching either end, a firmer one on crossing a printed mark, a light tick
    /// on crossing a notch.
    static func moved(from old: Double, to new: Double) {
        if (old > 0 && new == 0) || (old < 1 && new == 1) { detent(); return }
        if step(old, marks) != step(new, marks) { mark(); return }
        if step(old, notches) != step(new, notches) { tick() }
    }

    /// For knobs with indicator marks: one click each time a mark switches on or off (`lit` is how
    /// many are lit at a value), and the firmest click on reaching either end. Nothing in between,
    /// so the clicks you feel are the marks you see.
    static func indicatorMoved(from old: Double, to new: Double, lit: (Double) -> Int) {
        if (old > 0 && new == 0) || (old < 1 && new == 1) { detent(); return }
        if lit(old) != lit(new) { mark() }
    }

    /// Which step a value is in; a value exactly on a step line counts as that step, so landing
    /// on a mark clicks once, whichever way it is reached.
    private static func step(_ value: Double, _ count: Int) -> Int {
        Int((value * Double(count) + 1e-9).rounded(.down))
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, spaced: Bool) {
        let now = Date()
        if spaced, now.timeIntervalSince(lastTick) < 0.012 { return }
        lastTick = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
