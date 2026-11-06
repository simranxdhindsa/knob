import SwiftUI

/// Full screen: the whole cover, square and untouched, with the song's name, the slider and the
/// transport under it on the cover's own blurred colours, lined up with its edges. The window's
/// layout runs the cover off the screen and lays the controls over it, which only suits a window.
extension KnobShiftPlayerView {
    func posterDeck(wide: Bool) -> some View {
        GeometryReader { geometry in
            let layout = KnobShiftPosterLayout(size: geometry.size)
            VStack(spacing: 0) {
                posterCover(layout)
                    .padding(.top, layout.top)
                    .padding(.bottom, layout.gap)
                VStack(spacing: 0) {
                    titleRow(wide: wide, scale: layout.scale)
                        .frame(height: KnobShiftPlayerLayout.title * layout.scale)
                    PlayerTimeline(model: model, clock: model.clock, scrub: scrub, textSize: 12 * layout.scale)
                        .frame(height: KnobShiftPlayerLayout.timeline * layout.scale)
                    PlayerTransport(model: model, scrub: scrub, dialSize: KnobShiftPlayerLayout.dial * layout.scale, scale: layout.scale)
                        .frame(height: KnobShiftPlayerLayout.dial * layout.scale)
                    Text(model.notice ?? " ")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(height: KnobShiftPlayerLayout.caption)
                }
                .frame(width: layout.side)
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Pausing eases the cover back and dims it, as the window does.
    @ViewBuilder private func posterCover(_ layout: KnobShiftPosterLayout) -> some View {
        if model.nowPlaying == nil {
            Image(systemName: "music.note")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: layout.side, height: layout.side)
                .accessibilityHidden(true)
        } else {
            KnobShiftCover(model: model, clock: model.clock, size: layout.side, animated: model.isPlaying, corner: 0.03)
                .brightness(model.isPlaying ? 0 : -0.1)
                .scaleEffect(model.isPlaying ? 1 : 0.96)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.gentle, value: model.isPlaying)
                .allowsHitTesting(false)
        }
    }
}

/// Where full screen's parts sit. A window is never wider than `maximumSize`, so a wider player
/// can only be full screen: that needs no word from the window, and can't be left out of step.
struct KnobShiftPosterLayout {
    static let top: CGFloat = 28, gap: CGFloat = 20, smallest: CGFloat = 420
    private static let controls = KnobShiftPlayerLayout.title + KnobShiftPlayerLayout.timeline
        + KnobShiftPlayerLayout.dial + KnobShiftPlayerLayout.caption + KnobShiftPlayerLayout.bottom

    let size: CGSize

    var top: CGFloat { Self.top }
    var gap: CGFloat { Self.gap }
    /// As big as the height allows, and never wider than the deck.
    var side: CGFloat { min(size.height - Self.top - Self.gap - Self.controls * scale, size.width - 96) }
    /// How much the controls grow: not at all on the smallest screens, and by about a fifth on a
    /// 14 inch MacBook, so they read at full screen distance.
    var scale: CGFloat { min(max(size.height / 900, 1), 1.6) }

    /// A very short screen keeps the window's layout rather than a tiny cover.
    static func fits(_ size: CGSize) -> Bool {
        size.width > KnobShiftPlayerView.maximumSize.width && size.height - top - gap - controls >= smallest
    }

    /// The queue's width: the window's rule, a little wider on a big full screen.
    static func sidebar(_ width: CGFloat, poster: Bool) -> CGFloat {
        poster ? min(420, max(360, width * 0.21)) : min(360, width * 0.42)
    }
}
