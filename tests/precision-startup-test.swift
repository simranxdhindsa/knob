import Foundation
import CoreGraphics

@main
enum PrecisionStartupTests {
    static func near(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.000001, "Expected \(expected), got \(actual)")
    }

    static func point(_ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: 75 + sin(radians) * 60, y: 75 - cos(radians) * 60)
    }

    static func main() {
        var normal = RotaryDrag(sweep: 270, size: 150, value: 0.5)
        var fine = normal
        _ = normal.move(to: point(0))
        _ = fine.move(to: point(0), precision: true)
        near(normal.move(to: point(27)), 0.6)
        near(fine.move(to: point(27), precision: true), 0.51)
        // Shift can be pressed or released mid-gesture without a jump.
        near(fine.move(to: point(27)), 0.51)
        near(fine.move(to: point(54)), 0.61)
        near(fine.move(to: point(54), precision: true), 0.61)
        near(fine.move(to: point(27), precision: true), 0.60)

        var centre = RotaryDrag(sweep: 270, size: 150, value: 0.5)
        _ = centre.move(to: CGPoint(x: 75, y: 80), precision: true)
        near(centre.move(to: CGPoint(x: 75, y: 70), precision: true), 0.5 + 1 / 270)
        var edge = RotaryDrag(sweep: 270, size: 150, value: 0.99)
        _ = edge.move(to: point(0))
        near(edge.move(to: point(90)), 1)
        near(edge.move(to: point(63)), 0.9)
        var wrap = RotaryDrag(sweep: 270, size: 150, value: 0.5)
        _ = wrap.move(to: point(179))
        near(wrap.move(to: point(-179)), 0.5 + 2 / 270)

        let locale = Locale(identifier: "en_US")
        for bad in ["", "NaN", "inf", "1e999", "100.1", "-0.1", "25abc", "1,000"] {
            precondition(NumericEntry.parse(bad, range: 0...100, locale: locale) == nil, bad)
        }
        near(NumericEntry.parse(" 25.25 ", range: 0...100, locale: locale)!, 25.25)
        near(NumericEntry.parse("-3.5", range: -12...12, locale: locale)!, -3.5)
        near(NumericEntry.parse("2,5", range: 0...10, locale: Locale(identifier: "de_DE"))!, 2.5)
        near(NumericEntry.parse("0", range: 0...100, locale: locale)!, 0)
        near(NumericEntry.parse("100", range: 0...100, locale: locale)!, 100)

        let missing = "knob-engine: audio device unavailable: 4C2D7776-0000-0000-2922-0103803C2278\n"
        let timeout = "knob-engine: capture/render readiness timed out; default output was not activated\n"
        precondition(StartupFailure.diagnose(log: missing) == .outputUnavailable)
        precondition(StartupFailure.diagnose(log: timeout) == .audioTimeout)
        precondition(StartupFailure.diagnose(log: missing + timeout + "knob-supervisor: engine exited; retry 1/3 without automatic routing\n") == .audioTimeout)
        precondition(StartupFailure.diagnose(log: "") == nil)
        precondition(StartupFailure.diagnose(log: "knob-engine: saved preset unavailable; loading fallback preset") == nil)
        if CommandLine.arguments.count > 1 {
            let reproduced = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            precondition(StartupFailure.diagnose(log: reproduced) == .outputUnavailable)
        }
        print("PASS: precision dragging, modifier transitions, numeric validation and startup diagnosis")
    }
}
