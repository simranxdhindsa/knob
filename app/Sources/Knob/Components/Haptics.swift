#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    /// One push of a knob straining against its end stop, `intensity` 0...1 (the iPhone
    /// opening). The iPhone's rigid tap, a little firmer than asked so even the faint first and
    /// last pushes are felt; on the Mac, the trackpad's tick.
    static func strain(_ intensity: Double) {
        #if os(macOS)
        tick()
        #else
        let firmer = 0.15 + 0.85 * min(max(intensity, 0), 1)
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: CGFloat(firmer))
        }
        #endif
    }

    /// The iPhone opening's own taps: `firm` (medium) for each mark lighting and each mark landing
    /// on the Play dial, `hard` (heavy) for reaching the last mark. The Mac has no opening, so
    /// they fall back to its trackpad's clicks.
    static func firm() {
        #if os(macOS)
        mark()
        #else
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        #endif
    }

    static func hard() {
        #if os(macOS)
        detent()
        #else
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        #endif
    }

    /// Something finished well (a sync, a save): the iPhone's success tap; on the Mac, a firm click.
    static func success() {
        #if os(macOS)
        detent()
        #else
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        #endif
    }

    #if os(macOS)
    typealias Pattern = NSHapticFeedbackManager.FeedbackPattern
    #else
    /// The iPhone's Taptic Engine, with the same three strengths as the trackpad.
    enum Pattern { case alignment, generic, levelChange }
    #endif

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

    private static func perform(_ pattern: Pattern, spaced: Bool) {
        let now = Date()
        if spaced, now.timeIntervalSince(lastTick) < 0.012 { return }
        lastTick = now
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        #else
        DispatchQueue.main.async {
            switch pattern {
            case .alignment: UISelectionFeedbackGenerator().selectionChanged()
            case .generic: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .levelChange: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        #endif
    }
}
