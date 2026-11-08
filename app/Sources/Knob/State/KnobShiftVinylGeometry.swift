import CoreGraphics
import Foundation

/// Where the iPhone's record and arm sit, in pure numbers so it can be tested on its own. Angles
/// are degrees clockwise from pointing right, as on screen. The arm's pivot sits above and to the
/// right of the record, so the stylus crosses the half of the record the sleeve leaves showing.
struct KnobShiftVinylGeometry {
    /// Where the music starts and ends on the record, as shares of its width from the centre. The
    /// song starts right at the outer edge, as on a real record.
    static let outerGroove = 0.488, innerGroove = 0.22
    private static let pivotRight = 0.66, pivotUp = 0.40, reach = 0.72
    /// How far past the outer groove the arm rests, clear of the record.
    private static let restSwing = 16.0

    let center: CGPoint
    let diameter: CGFloat

    var pivot: CGPoint { CGPoint(x: center.x + Self.pivotRight * diameter, y: center.y - Self.pivotUp * diameter) }
    var armLength: CGFloat { Self.reach * diameter }
    var restAngle: Double { angle(progress: 0) - Self.restSwing }

    /// From the pivot to the record's centre, and that distance as a share of the record.
    private static var centerDistance: Double { (pivotRight * pivotRight + pivotUp * pivotUp).squareRoot() }
    private static var centerAngle: Double { atan2(pivotUp, -pivotRight) * 180 / .pi }

    /// The arm's angle with the stylus at this point in the song, from 0 to 1.
    func angle(progress: Double) -> Double {
        let share = min(max(progress, 0), 1)
        let radius = Self.outerGroove + (Self.innerGroove - Self.outerGroove) * share
        let d = Self.centerDistance, l = Self.reach
        let cosine = (d * d + l * l - radius * radius) / (2 * d * l)
        return Self.centerAngle - acos(min(max(cosine, -1), 1)) * 180 / .pi
    }

    /// The point in the song for an arm at this angle.
    func progress(angle: Double) -> Double {
        let d = Self.centerDistance, l = Self.reach
        let turn = (Self.centerAngle - angle) * .pi / 180
        let radius = (d * d + l * l - 2 * d * l * cos(turn)).squareRoot()
        return min(max((Self.outerGroove - radius) / (Self.outerGroove - Self.innerGroove), 0), 1)
    }

    /// The point in the song for a finger holding the arm here.
    func progress(finger: CGPoint) -> Double {
        progress(angle: bearing(finger: finger))
    }

    /// The direction from the pivot to a finger, in the same degrees as the arm's angle.
    func bearing(finger: CGPoint) -> Double {
        atan2(Double(finger.y - pivot.y), Double(finger.x - pivot.x)) * 180 / .pi
    }

    /// The point in the song for an arm picked up at `progress` with the finger at `from`, once
    /// the finger is at `to`. The arm turns by a share of the finger's turn, so the whole song
    /// isn't squeezed into a few degrees of the finger, and it never jumps to the finger on pickup.
    func progress(from: CGPoint, to: CGPoint, startingAt progress: Double, precision: Double) -> Double {
        var turned = bearing(finger: to) - bearing(finger: from)
        if turned > 180 { turned -= 360 } else if turned < -180 { turned += 360 }
        return self.progress(angle: angle(progress: progress) + turned * precision)
    }

    func stylus(progress: Double) -> CGPoint {
        let turn = angle(progress: progress) * .pi / 180
        return CGPoint(x: pivot.x + armLength * cos(turn), y: pivot.y + armLength * sin(turn))
    }
}
