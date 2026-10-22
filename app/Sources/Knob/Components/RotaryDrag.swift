import CoreGraphics
import Foundation

/// The maths behind turning a knob by circling the pointer around it. Kept free of SwiftUI so
/// it can be tested on its own. Angles are degrees, 0 at the top, clockwise positive.
struct RotaryDrag {
    /// Degrees of pointer travel for the full MIN to MAX range (the knob's arc).
    let sweep: Double
    /// Knob size in points; the centre is at (size/2, size/2).
    let size: CGFloat

    private(set) var value: Double
    private var lastAngle: Double?
    private var lastLocation: CGPoint?

    init(sweep: Double, size: CGFloat, value: Double) {
        self.sweep = sweep
        self.size = size
        self.value = min(max(value, 0), 1)
    }

    /// Feeds the next pointer location and returns the new knob value (0...1).
    /// Circling clockwise turns up. Within the inner 18% of the radius, where the angle is
    /// unsteady, up/down movement is used instead. Stops at both ends, never wraps.
    mutating func move(to location: CGPoint, precision: Bool = false) -> Double {
        let sensitivity = precision ? 0.1 : 1.0
        let dx = Double(location.x - size / 2), dy = Double(location.y - size / 2)
        let nearCentre = (dx * dx + dy * dy).squareRoot() < Double(size) * 0.18
        let angle = atan2(dx, -dy) * 180 / .pi
        if !nearCentre, let previous = lastAngle {
            var delta = angle - previous
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            value += delta / sweep * sensitivity
        } else if nearCentre, let last = lastLocation {
            value += Double(last.y - location.y) / Double(max(160, size * 1.8)) * sensitivity
        }
        lastAngle = nearCentre ? nil : angle
        lastLocation = location
        value = min(max(value, 0), 1)
        return value
    }
}
