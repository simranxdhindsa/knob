import Combine
import Foundation

/// The fast changing numbers of playback: where the song is, how long it is, and how far a
/// blend has gone. Kept apart from KnobShiftModel so their many updates a second redraw only
/// the timelines that show them.
@MainActor
final class KnobShiftClock: ObservableObject {
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    /// Not shown on screen; kept here so its updates never redraw anything.
    var blend: Double = 0
}
