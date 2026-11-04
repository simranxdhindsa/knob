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
    /// Slow breathing glow for something live, like the KNOBMIX badge during a mix.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    /// The slow drift of a generated cover's shapes while its song plays.
    static let artworkDrift = Animation.easeInOut(duration: 9).repeatForever(autoreverses: true)

    /// A song's cover coming up from grey to full colour once it is ready.
    static let artworkReveal = Animation.easeOut(duration: 0.4)

    /// The iPhone player's blurred background fading from one song's cover to the next.
    static let ambient = Animation.easeInOut(duration: 0.8)

    /// 21st.dev Switch: 250ms on, 125ms off, cubic-bezier(.26, .75, .38, .45).
    static func switchThumb(turningOn: Bool) -> Animation {
        .timingCurve(0.26, 0.75, 0.38, 0.45, duration: turningOn ? 0.25 : 0.125)
    }
}
