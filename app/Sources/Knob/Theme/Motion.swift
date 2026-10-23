import SwiftUI

/// Knob's animations. The springs use Framer Motion's settings: SwiftUI's
/// `interpolatingSpring(mass:stiffness:damping:)` is the same damped-spring model
/// Framer Motion uses for `{ type: "spring", stiffness, damping, mass }`.
enum Motion {
    /// Framer Motion `{ type: "spring", stiffness: 400, damping: 30 }`: quick, no wobble.
    static let snappy = Animation.interpolatingSpring(mass: 1, stiffness: 400, damping: 30)
    /// Framer Motion `{ type: "spring", stiffness: 170, damping: 26 }`: soft settle.
    static let gentle = Animation.interpolatingSpring(mass: 1, stiffness: 170, damping: 26)
    /// A knob catching up with an outside change, such as the Mac volume keys.
    static let knob = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 24)
    /// The VU meter needle: Analog UI Needle Gauge's spring `{ stiffness: 420, damping: 28, mass: 1 }`.
    static let vuNeedle = Animation.interpolatingSpring(mass: 1, stiffness: 420, damping: 28)
    /// 21st.dev Segmented Control thumb: 0.35s cubic-bezier(0.2, 0, 0, 1).
    static let segment = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.35)

    /// 21st.dev Switch: 250ms on, 125ms off, cubic-bezier(.26, .75, .38, .45).
    static func switchThumb(turningOn: Bool) -> Animation {
        .timingCurve(0.26, 0.75, 0.38, 0.45, duration: turningOn ? 0.25 : 0.125)
    }
}
