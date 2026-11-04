import SwiftUI

/// Live spectrum bars with dB grid lines, drawn like an analyser screen. `bands` are 0...1 from
/// low to high frequency; they are smoothly interpolated into `barCount` thin bars. The engine
/// measures about 15 times a second, so between readings each bar glides on every screen frame:
/// up quickly with a hit, down slowly as it fades, like a real analyser's ballistics.
struct SpectrumView: View {
    var bands: [Double]
    var barCount = 46
    var showsGrid = true
    var intensity = 1.0

    @State private var motion = SpectrumMotion()

    var body: some View {
        // Stops drawing once the bars have settled where the audio left them.
        TimelineView(.animation(paused: motion.settled(on: bands))) { timeline in
            Canvas { context, size in
                let shown = motion.advance(to: bands, at: timeline.date)
                if showsGrid {
                    for index in 1...3 {
                        let y = size.height * CGFloat(index) / 4
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(line, with: .color(Screen.grid), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    }
                }
                guard shown.count > 1 else { return }
                let step = size.width / CGFloat(barCount)
                let barWidth = max(1.2, step * 0.55)
                for index in 0..<barCount {
                    let level = Self.sample(shown, at: Double(index) / Double(barCount - 1)) * intensity
                    let height = max(1.5, CGFloat(level) * size.height * 0.92)
                    let rect = CGRect(x: CGFloat(index) * step, y: size.height - height, width: barWidth, height: height)
                    context.fill(Path(rect), with: .linearGradient(
                        Gradient(colors: [Screen.bar.opacity(0.95), Screen.bar.opacity(0.25)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Smooth (cosine) interpolation between neighbouring bands, plus a fixed ripple so bars
    /// inside one band are not identical. No randomness: the picture only moves with the audio.
    private static func sample(_ bands: [Double], at position: Double) -> Double {
        let scaled = position * Double(bands.count - 1)
        let i = min(Int(scaled), bands.count - 2)
        let t = scaled - Double(i)
        let eased = (1 - cos(t * .pi)) / 2
        let base = bands[i] * (1 - eased) + bands[i + 1] * eased
        let ripple = 0.86 + 0.14 * sin(position * 57.0) * sin(position * 13.0)
        return min(max(base * ripple, 0), 1)
    }
}

/// The levels the bars show right now, eased frame by frame towards the latest reading. A plain
/// class kept in `@State`, so moving it on each frame redraws nothing but the canvas.
final class SpectrumMotion {
    private var shown: [Double] = []
    private var last: Date?
    /// How quickly a bar closes the gap to its reading, per second: rising, then falling.
    private static let rise = 28.0, fall = 7.0

    func advance(to target: [Double], at date: Date) -> [Double] {
        guard shown.count == target.count else {
            shown = target
            last = date
            return shown
        }
        // A long gap (the panel was closed, or the bars sat still) counts as a quarter second,
        // which is near enough all the way there.
        let elapsed = min(date.timeIntervalSince(last ?? date), 0.25)
        last = date
        for index in shown.indices {
            let gap = target[index] - shown[index]
            let rate = gap > 0 ? Self.rise : Self.fall
            shown[index] += gap * (1 - exp(-rate * elapsed))
        }
        return shown
    }

    func settled(on target: [Double]) -> Bool {
        shown.count == target.count && zip(shown, target).allSatisfy { abs($0 - $1) < 0.002 }
    }
}
