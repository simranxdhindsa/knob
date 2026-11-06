import SwiftUI

/// The things worth showing someone once, each at the moment it is useful: how to reach the
/// record deck and what its parts do. A tip goes for good when it is done or dismissed. What has
/// been seen is what counts, not the version, so a new install and an update get the same guide.
enum DeckTip: String {
    case turn, fullScreen, toggle, record, arm, cover, bedside

    /// The deck's own tips, in the order they come.
    static let deck: [DeckTip] = [.record, .arm, .cover]

    func isSeen(in seen: String) -> Bool {
        seen.split(separator: ",").contains(Substring(rawValue))
    }

    func mark(in seen: inout String) {
        guard !isSeen(in: seen) else { return }
        seen = seen.isEmpty ? rawValue : "\(seen),\(rawValue)"
    }

    var symbol: String {
        switch self {
        case .turn: "iphone"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .toggle: "record.circle"
        case .record: "arrow.clockwise"
        case .arm: "hand.point.up.left"
        case .cover, .bedside: "hand.tap"
        }
    }

    var text: String {
        #if os(iOS)
        let spin = "Spin the record"
        let cover = "Tap the cover to pause, or swipe it for another song"
        #else
        let spin = "Drag the record around"
        let cover = "Click the cover to pause, or drag it sideways for another song"
        #endif
        return switch self {
        case .turn: "Turn your iPhone on its side to play on a record"
        case .fullScreen: "Go full screen for the big player and the record deck"
        case .toggle: "Flip this switch to play on a record"
        case .record: "\(spin). Clockwise moves ahead, anticlockwise goes back"
        case .arm: "Lift the arm and set it down anywhere in the song"
        case .cover: cover
        case .bedside: "Tap the clock for the controls"
        }
    }
}

/// One tip on glass: an icon, one short line, dots for how far through the deck's tips this is,
/// and a way out. Its look comes from 21st.dev's Product Tour Popover (shadcnspace).
struct DeckTipBubble: View {
    let tip: DeckTip
    /// A button of its own, for a tip that can do the thing for you.
    var action: (label: String, run: () -> Void)?
    let onClose: () -> Void

    private var step: Int? { DeckTip.deck.firstIndex(of: tip) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DeckTipIcon(tip: tip)
            VStack(alignment: .leading, spacing: 7) {
                Text(tip.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Glass.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let step { dots(at: step) }
                if let action {
                    Button(action: action.run) {
                        Text(action.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Glass.onAccent)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(Palette.accent))
                    }
                    .buttonStyle(.plain)
                    .overlay { TipTapHand() }
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Glass.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-14)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(12)
        .padding(.trailing, 4)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Glass.stroke, lineWidth: 1)
        }
        .shadow(color: Glass.shadow, radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }

    private func dots(at step: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(DeckTip.deck.indices, id: \.self) { index in
                Circle()
                    .fill(index == step ? Palette.accent : Glass.tertiary)
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Tip \(step + 1) of \(DeckTip.deck.count)")
    }
}

/// The tip's icon. The iPhone in the turn tip tips over onto its side, to show what to do.
private struct DeckTipIcon: View {
    let tip: DeckTip

    var body: some View {
        Group {
            if tip == .turn {
                TipTurningPhone(size: 15)
            } else {
                Image(systemName: tip.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// An iPhone going over onto its side and back.
struct TipTurningPhone: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phone = Image(systemName: DeckTip.turn.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.accent)
        Group {
            if reduceMotion {
                phone.rotationEffect(.degrees(90))
            } else {
                PhaseAnimator([false, true]) { turned in
                    phone.rotationEffect(.degrees(turned ? 90 : 0))
                } animation: { _ in Motion.tipTurn }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the hand acts out: a tap on a spot, or a press that slides along a path from 0 to 1.
enum TipMove {
    case tap(CGPoint)
    case slide((Double) -> CGPoint)
}

/// Where the hand is in one move, from 0 to 1 through it, in pure numbers.
struct TipHandStep {
    /// How far along the path, how far down on the screen, and how much of it can be seen.
    let along: Double, pressed: Bool, shown: Double

    init(_ phase: Double, taps: Bool) {
        shown = min(min(phase / 0.12, (1 - phase) / 0.12), 1)
        if taps {
            along = 0
            pressed = (0.22...0.34).contains(phase) || (0.5...0.62).contains(phase)
        } else {
            let travel = min(max((phase - 0.22) / 0.56, 0), 1)
            along = travel * travel * (3 - 2 * travel)
            pressed = (0.16...0.84).contains(phase)
        }
    }
}

/// A hand acting out a gesture on the real thing, over and over until the tip goes: it comes in,
/// presses, moves and lifts, leaving a spot of light under the fingertip while it is down. It only
/// shows the way, so touches pass straight through it. Reduce Motion holds it still on the spot.
struct TipHand: View {
    private static let size: CGFloat = 40

    let moves: [TipMove]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let (move, phase) = current(at: context.date)
            let step = reduceMotion ? TipHandStep(0.5, taps: false) : TipHandStep(phase, taps: isTap(move))
            let point = spot(move, along: reduceMotion ? 0 : step.along)
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(Palette.accent.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .scaleEffect(step.pressed ? 1 : 0.4)
                    .opacity(step.pressed ? 1 : 0)
                    .position(point)
                // The fingertip of this symbol sits towards its top left.
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: Self.size))
                    .foregroundStyle(Glass.onAccent)
                    // Its outline keeps it clear on anything, even a bright cover or the clock.
                    .overlay {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: Self.size))
                            .foregroundStyle(Vinyl.disc)
                    }
                    .shadow(color: Glass.shadow, radius: 6, y: 3)
                    .scaleEffect(step.pressed ? 0.9 : 1)
                    .position(x: point.x + Self.size * 0.3, y: point.y + Self.size * 0.42)
            }
            .opacity(reduceMotion ? 1 : step.shown)
            .animation(.easeOut(duration: 0.12), value: step.pressed)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func current(at date: Date) -> (TipMove, Double) {
        let time = date.timeIntervalSinceReferenceDate / Motion.tipMoveSeconds
        let index = Int(time.rounded(.down)) % moves.count
        return (moves[index], time - time.rounded(.down))
    }

    private func isTap(_ move: TipMove) -> Bool {
        if case .tap = move { true } else { false }
    }

    private func spot(_ move: TipMove, along: Double) -> CGPoint {
        switch move {
        case .tap(let point): point
        case .slide(let path): path(along)
        }
    }
}

/// The hand tapping the middle of whatever it is laid over.
struct TipTapHand: View {
    var body: some View {
        GeometryReader { proxy in
            TipHand(moves: [.tap(CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2))])
        }
    }
}

/// The hand turning the record clockwise, along the half that shows, over an arrow of the same.
struct RecordTipMark: View {
    private static let from = -52.0, to = 52.0

    let center: CGPoint
    let diameter: CGFloat

    private var radius: CGFloat { diameter * 0.37 }

    private func point(_ degrees: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addArc(center: center, radius: radius, startAngle: .degrees(Self.from), endAngle: .degrees(Self.to), clockwise: false)
            }
            .stroke(Palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 9]))
            TipHand(moves: [.slide { point(Self.from + (Self.to - Self.from) * $0) }])
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hand taking the head of the arm, wherever the song has it, and moving it along the record.
struct ArmTipMark: View {
    /// How far through the song the hand carries the arm.
    private static let reach = 0.35

    @ObservedObject var clock: KnobShiftClock
    let geometry: KnobShiftVinylGeometry

    var body: some View {
        let from = min(clock.duration > 0 ? clock.time / clock.duration : 0, 1 - Self.reach)
        TipHand(moves: [.slide { geometry.stylus(progress: from + Self.reach * $0) }])
    }
}
