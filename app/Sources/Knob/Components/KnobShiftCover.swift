import SwiftUI

/// The playing song's cover, which follows a KnobMix: the next song's cover fades and settles in
/// step with the mix itself (the playback clock's blend), so by the handoff it has fully taken
/// over and nothing jumps. It watches only the clock, so the mix's many updates redraw just this.
struct KnobShiftCover: View {
    let model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    var size: CGFloat
    var lit = false
    var animated = false
    var corner: CGFloat = 0.14

    var body: some View {
        ZStack {
            AlbumArtwork(url: model.nowPlaying?.url, size: size, lit: lit, animated: animated, corner: corner)
            if let next = model.mixingInto {
                let share = Self.share(clock.blend)
                AlbumArtwork(url: next.url, size: size, lit: lit, animated: animated, corner: corner)
                    .opacity(share)
                    .scaleEffect(1.04 - 0.04 * share)
            }
        }
    }

    /// Smoothstep from 20 to 85 percent of the mix: the old cover holds while the old song leads,
    /// and the new one is fully in before the handoff.
    static func share(_ blend: Double) -> Double {
        let t = min(max((blend - 0.2) / 0.65, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
