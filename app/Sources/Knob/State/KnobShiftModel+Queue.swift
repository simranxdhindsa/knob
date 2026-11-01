import Foundation

/// Shuffle and drag to reorder. The queue on screen is always the real play order, so what is
/// shown next is what plays next. Shuffle keeps the playing song first and shuffles the rest;
/// turning it off brings back the user's own order. Dragging reorders whichever order is showing.
extension KnobShiftModel {
    func toggleShuffle() {
        if isShuffled {
            tracks = unshuffled
            unshuffled = []
            isShuffled = false
            log("QUEUE", "Shuffle off, back to your order.")
        } else {
            unshuffled = tracks
            if let playing = nowPlaying, tracks.contains(playing) {
                tracks = [playing] + tracks.filter { $0 != playing }.shuffled()
            } else {
                tracks.shuffle()
            }
            isShuffled = true
            log("QUEUE", "Shuffle on: " + tracks.map(\.name).joined(separator: ", ") + ".")
        }
        queueReordered()
    }

    /// Moves songs in the order that is showing. In shuffle the user's own order is left as it
    /// was, so turning shuffle off still restores it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        log("QUEUE", "Reordered: " + tracks.map(\.name).joined(separator: ", ") + ".")
        queueReordered()
    }

    /// Keeps the playing song current at its new place and plans the mix into whatever is now next.
    private func queueReordered() {
        if let playing = nowPlaying, let index = tracks.firstIndex(of: playing) {
            currentIndex = index
        }
        persistQueue()
        refreshPlanIfNeeded()
    }
}
