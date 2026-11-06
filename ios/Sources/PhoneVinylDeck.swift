import SwiftUI

/// The player on its side: the record deck (VinylStage), with the song's name, times and
/// transport beside it, which fade in once the deck has settled. On a charger that column becomes
/// Bedside mode: the room goes dim, the screen stays on and a big clock takes the controls' place.
/// The record is the same one throughout, so plugging in never interrupts it, and it still turns
/// and works. A tap on the clock brings the controls back for a few seconds.
struct PhoneVinylDeck: View {
    private static let column: CGFloat = 164
    /// How long the controls stay up in Bedside mode after the last touch.
    private static let awakeSeconds = 6.0
    /// The clock and the controls trade places, one gone before the other comes.
    private static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(Motion.bedsideIn),
                                                       removal: .opacity.animation(Motion.bedsideOut))

    @ObservedObject var model: KnobShiftModel
    @ObservedObject var scrub: PlayerScrub
    @ObservedObject private var charger = PhoneCharger.shared
    @AppStorage(PersistKey.knobShiftBedside.rawValue) private var bedsideAllowed = true
    @AppStorage(PersistKey.knobShiftTipsSeen.rawValue) private var tipsSeen = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var settled = false
    /// The song on the deck, which changes with the cover rather than ahead of it.
    @State private var song: KnobShiftModel.Track?
    /// In Bedside mode, whether the controls are up instead of the clock.
    @State private var awake = false
    /// Counts touches on the controls, each of which gives them longer.
    @State private var touches = 0
    @State private var drift = CGSize.zero

    private var bedside: Bool { charger.plugged && bedsideAllowed }
    private var showsClock: Bool { bedside && settled && !awake }
    private var dim: Double { bedside ? (awake ? Bedside.awake : Bedside.asleep) : 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                VinylStage(model: model, size: CGSize(width: proxy.size.width - Self.column, height: proxy.size.height), showsTips: !bedside, onSettled: {
                    withAnimation(Motion.gentle) { settled = true }
                }, onShowing: { song = $0 })
                .offset(drift)
                Bedside.night
                    .opacity(dim)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(Motion.bedside, value: dim)
                column(height: proxy.size.height)
                    .offset(drift)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .persistentSystemOverlays(bedside ? .hidden : .automatic)
        .onAppear {
            charger.start()
            DeckTip.turn.mark(in: &tipsSeen)
        }
        .onDisappear {
            charger.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: bedside, initial: true) {
            UIApplication.shared.isIdleTimerDisabled = bedside
            awake = false
        }
        #if DEBUG
        .onChange(of: charger.checkTaps) { wake() }
        #endif
        .task(id: touches) { await sleepAgain() }
        .task(id: bedside) { await keepDrifting() }
    }

    private func column(height: CGFloat) -> some View {
        ZStack {
            if showsClock {
                PhoneBedsideClock(song: song ?? model.nowPlaying, percent: charger.percent, height: height, showsTip: !DeckTip.bedside.isSeen(in: tipsSeen))
                    .frame(width: Self.column, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: wake)
                    .overlay { if !DeckTip.bedside.isSeen(in: tipsSeen) { TipTapHand() } }
                    .transition(Self.swap)
            } else {
                details
                    .opacity(settled ? 1 : 0)
                    // Beside the controls' own gestures: any touch on them keeps them up.
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touches += 1 })
                    .transition(Self.swap)
            }
        }
    }

    private var details: some View {
        let shown = song ?? model.nowPlaying
        return VStack(alignment: .leading, spacing: 10) {
            if charger.plugged {
                HStack(spacing: 0) {
                    Text("Bedside")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Glass.secondary)
                    Spacer(minLength: 8)
                    VinylToggle(isOn: $bedsideAllowed, label: "Bedside mode")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shown?.name ?? "Nothing playing")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Glass.text)
                    .lineLimit(2)
                Text(shown?.artist ?? "")
                    .font(.system(size: 13)).foregroundStyle(Glass.secondary)
                    .lineLimit(1)
            }
            .contentTransition(.opacity)
            .animation(Motion.vinylCover, value: shown?.id)
            PlayerTimeline(model: model, clock: model.clock, scrub: scrub, showsChip: false)
                .frame(height: 52)
            HStack(spacing: 0) {
                step("backward.fill", label: "Previous", action: model.previous)
                PlayDial(model: model, clock: model.clock, scrub: scrub, size: 74)
                step("forward.fill", label: "Next", action: model.next)
            }
            if model.mixState == .mixing {
                Text("Record is free after the mix")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(width: Self.column, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    private func step(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.mark()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Glass.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPress())
        .accessibilityLabel(label)
    }

    private func wake() {
        Haptics.mark()
        DeckTip.bedside.mark(in: &tipsSeen)
        awake = true
        touches += 1
    }

    /// Back to the clock once the controls are left alone. VoiceOver keeps them up, since moving
    /// through them takes longer than a tap.
    private func sleepAgain() async {
        guard awake, !voiceOver else { return }
        do {
            try await Task.sleep(for: .seconds(Self.awakeSeconds))
            awake = false
        } catch {
            // Another touch, or the deck left.
        }
    }

    private func keepDrifting() async {
        drift = .zero
        guard bedside else { return }
        var minute = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            minute += 1
            let next = BedsideDrift.offset(minute: minute)
            if reduceMotion { drift = next } else { withAnimation(Motion.bedside) { drift = next } }
        }
    }
}
