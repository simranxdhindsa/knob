import Foundation

/// A listener's estimate of the host's clock, from pings. Measured on real Wi-Fi, replies take
/// anywhere from 7 to 120 ms, but the quickest ones are nearly the same both ways, so only the
/// quickest in the last few seconds counts. Clocks here drift by a few parts per million, under
/// a tenth of a millisecond in that time, so no separate drift estimate is needed.
struct KnobShiftTogetherClock {
    static let window: Int64 = 10_000_000_000
    /// How far each new estimate moves the clock, so one lucky ping can't make a step.
    private static let follow = 0.1

    private var samples: [(at: Int64, trip: Int64, offset: Int64)] = []
    private var smoothed: Double?

    /// The host's clock minus this one, in nanoseconds, once a ping has come back.
    var offset: Int64? { smoothed.map { Int64($0) } }
    /// The quickest round trip in the window: half of it is the most the offset can be wrong by.
    var bestTrip: Int64? { samples.map(\.trip).min() }

    /// One ping: sent and received on this clock, answered on the host's.
    mutating func add(sent: Int64, hostAnswered: Int64, received: Int64) {
        guard received >= sent else { return }
        samples.append((received, received - sent, hostAnswered - sent / 2 - received / 2))
        samples.removeAll { received - $0.at > Self.window }
        guard let best = samples.min(by: { $0.trip < $1.trip }) else { return }
        if let current = smoothed {
            smoothed = current + (Double(best.offset) - current) * Self.follow
        } else {
            smoothed = Double(best.offset)
        }
    }
}

/// Which frame of the mix left the host at a given moment on its clock. Anchors arrive with
/// small errors of their own, so a straight line through the last minute of them is used, which
/// also finds the sound card's true rate.
struct KnobShiftTogetherTimeline {
    private static let longest = 60
    private var anchors: [(frame: Int64, host: Int64)] = []

    struct Line: Equatable {
        var frame: Int64
        var host: Int64
        var framesPerNanosecond: Double
    }

    private(set) var line: Line?

    /// The mix stopped and started again, so earlier anchors no longer sit on the same line.
    mutating func restart() {
        anchors.removeAll()
        line = nil
    }

    mutating func add(frame: Int64, hostNanoseconds: Int64, rate: Double) {
        anchors.append((frame, hostNanoseconds))
        if anchors.count > Self.longest { anchors.removeFirst(anchors.count - Self.longest) }
        let nominal = rate / 1e9
        guard anchors.count >= 8, let first = anchors.first else {
            line = Line(frame: frame, host: hostNanoseconds, framesPerNanosecond: nominal)
            return
        }
        // Measured from the first anchor, so the sums stay small enough to be exact in a Double.
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        for anchor in anchors {
            let x = Double(anchor.host - first.host), y = Double(anchor.frame - first.frame)
            sumX += x; sumY += y; sumXX += x * x; sumXY += x * y
        }
        let count = Double(anchors.count)
        let spread = count * sumXX - sumX * sumX
        guard spread > 0 else { return }
        var slope = (count * sumXY - sumX * sumY) / spread
        // A sound card is never far from its rate: anything else is a bad fit, not a fast clock.
        if abs(slope / nominal - 1) > 0.002 { slope = nominal }
        let meanX = sumX / count, meanY = sumY / count
        line = Line(frame: first.frame + Int64(meanY), host: first.host + Int64(meanX), framesPerNanosecond: slope)
    }
}
