import Combine
import Foundation

/// The fast changing numbers of playback: where the song is, how long it is, and how far a
/// blend has gone. Kept apart from KnobShiftModel so their many updates a second redraw only
/// the timelines and the cover that show them.
@MainActor
final class KnobShiftClock: ObservableObject {
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    /// How far a KnobMix has gone (0...1); the cover follows it from one song to the next.
    @Published var blend: Double = 0
}
