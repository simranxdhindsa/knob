import SwiftUI

/// The player on its side: the record deck (VinylStage), with the song's name, times and
/// transport beside it, which fade in once the deck has settled.
struct PhoneVinylDeck: View {
    private static let column: CGFloat = 164

    @ObservedObject var model: KnobShiftModel
    @ObservedObject var scrub: PlayerScrub
    @State private var settled = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VinylStage(model: model, size: CGSize(width: proxy.size.width - Self.column, height: proxy.size.height)) {
                    withAnimation(Motion.gentle) { settled = true }
                }
                details.opacity(settled ? 1 : 0)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.name ?? "Nothing playing")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Glass.text)
                    .lineLimit(2)
                Text(model.nowPlaying?.artist ?? "")
                    .font(.system(size: 13)).foregroundStyle(Glass.secondary)
                    .lineLimit(1)
            }
            VinylTimes(clock: model.clock, playing: model.nowPlaying != nil)
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
}

/// The song's times, alone in watching the clock so its ticks redraw nothing else.
private struct VinylTimes: View {
    @ObservedObject var clock: KnobShiftClock
    let playing: Bool

    var body: some View {
        HStack {
            Text(playing ? KnobShiftNowPlaying.clock(clock.time) : "0:00")
            Spacer()
            Text(playing ? KnobShiftNowPlaying.clock(max(0, clock.duration - clock.time)) + " left" : "0:00")
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Glass.secondary)
    }
}
