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

    /// The iPhone's record sliding out of its sleeve, then settling half under it.
    static let vinylOut = Animation.interpolatingSpring(mass: 1, stiffness: 80, damping: 16)
    static let vinylSettle = Animation.interpolatingSpring(mass: 1, stiffness: 110, damping: 19)
    /// The record changing with the song, always these lengths, however the song changed or
    /// however long its KnobMix runs: under the sleeve, the sleeve's cover changes, back out.
    static let vinylTuckSeconds = 0.8, vinylCoverSeconds = 0.3, vinylReturnSeconds = 0.9
    static let vinylTuck = Animation.timingCurve(0.5, 0, 0.7, 1, duration: vinylTuckSeconds)
    static let vinylCover = Animation.easeInOut(duration: vinylCoverSeconds)
    static let vinylReturn = Animation.timingCurve(0.2, 0, 0.2, 1, duration: vinylReturnSeconds)

    /// The arm cueing like a real one, only once the record is out: lifted off its rest, swung
    /// across, then lowered into the groove. Going away for a song change it lifts and swings back.
    static let armLiftSeconds = 0.2, armSwingSeconds = 0.8
    static let armLift = Animation.easeOut(duration: armLiftSeconds)
    static let armSwing = Animation.timingCurve(0.45, 0, 0.25, 1, duration: armSwingSeconds)

    /// The iPhone's Bedside mode: the room going dim, the clock and the controls trading places
    /// with one gone before the other comes, and each part of the clock rising into place a
    /// moment after the one above it.
    static let bedside = Animation.easeInOut(duration: 0.9)
    static let bedsideOutSeconds = 0.22
    static let bedsideOut = Animation.easeOut(duration: bedsideOutSeconds)
    static let bedsideIn = Animation.easeOut(duration: 0.35).delay(bedsideOutSeconds)
    static let bedsideRise = Animation.timingCurve(0.2, 0, 0.2, 1, duration: 0.7)
    static let bedsideStagger = 0.09

    /// The guide: how long the hand takes over one gesture, and the iPhone tipping onto its side.
    static let tipMoveSeconds = 2.4
    static let tipTurn = Animation.easeInOut(duration: 0.9).delay(0.5)

    /// The queue going to the playing song: the list glides there, the button's arrow shoots the
    /// way the list is about to move, and the row glows as it arrives.
    static let queueJumpSeconds = 0.6
    static let queueJump = Animation.timingCurve(0.2, 0, 0.2, 1, duration: queueJumpSeconds)
    static let queueJumpArrow = Animation.easeOut(duration: 0.28)
    static let queueLand = Animation.easeOut(duration: 0.9)

    /// The record in StandBy and the Dynamic Island turning as the song changes, at the deck's own
    /// speed of 160 degrees a second. iOS runs nothing by itself on a Live Activity and stops an
    /// animation after about 2 seconds, so this is one glide, not a spin.
    static let standbyTurnSeconds = 2.0
    static let standbyTurnDegrees = 320.0
    static let standbyTurn = Animation.linear(duration: standbyTurnSeconds)

    /// A song's cover coming up from grey to full colour once it is ready.
    static let artworkReveal = Animation.easeOut(duration: 0.4)

    /// The iPhone player's blurred background fading from one song's cover to the next.
    static let ambient = Animation.easeInOut(duration: 0.8)

    /// 21st.dev Switch: 250ms on, 125ms off, cubic-bezier(.26, .75, .38, .45).
    static func switchThumb(turningOn: Bool) -> Animation {
        .timingCurve(0.26, 0.75, 0.38, 0.45, duration: turningOn ? 0.25 : 0.125)
    }
}

extension Motion {
    /// Nothing moves for someone who asked for less motion.
    static func respecting(_ animation: Animation, reduce: Bool) -> Animation? { reduce ? nil : animation }
}
