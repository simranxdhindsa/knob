import Foundation

/// How the queue is sorted from its menu.
enum KnobShiftQueueSort: CaseIterable {
    case bpm, length, artist, recentlyAdded

    /// The name for a menu.
    var title: String {
        switch self {
        case .bpm: "BPM"
        case .length: "Length"
        case .artist: "Artist"
        case .recentlyAdded: "Recently added"
        }
    }
}

/// Mix Order, Play Next and sorting. Like shuffle they only change the order of `tracks` and
/// where the playing song is in it; the song on the decks is never touched, so playing carries
/// on and the next song and any planned mix follow the new order (`queueReordered`).
extension KnobShiftModel {
    /// Arranges the songs after the playing one so neighbours mix well (KnobShiftMixOrder).
    /// The user's own order is kept, one more tap brings it back, and it replaces shuffle.
    func toggleMixOrder() {
        shuffleToRestore = nil
        mixOrderToRestore = false
        if isMixOrdered {
            tracks = unshuffled
            unshuffled = []
            isMixOrdered = false
            log("QUEUE", "Mix Order off, back to your order.")
        } else {
            // Coming from shuffle the user's own order is already kept; it stays the one restored.
            if isShuffled { isShuffled = false } else { unshuffled = tracks }
            isMixOrdered = true
            arrangeByMix()
            log("QUEUE", "Mix Order on: " + tracks.map(\.name).joined(separator: ", ") + ".")
        }
        queueReordered()
    }

    /// Arranges the queue again while Mix Order is on, for songs added since. Songs before the
    /// playing one and the playing song stay where they are.
    func refreshMixOrder() {
        guard isMixOrdered else { return }
        arrangeByMix()
        queueReordered()
    }

    private func arrangeByMix() {
        tracks = KnobShiftMixOrder.arranged(tracks, playingIndex: playingIndex)
    }

    /// Where the playing song is in the queue, nil when nothing is playing.
    var playingIndex: Int? {
        nowPlaying.flatMap { playing in tracks.firstIndex(of: playing) }
    }

    /// Moves these songs to straight after the playing song, in the order they have in the
    /// queue now. The playing song itself stays put. With nothing playing they go to the top,
    /// where Play starts. In shuffle or Mix Order only the showing order changes, as with a drag.
    func playNext(ids: Set<UUID>) {
        let moving = tracks.filter { ids.contains($0.id) && $0 != nowPlaying }
        guard !moving.isEmpty else { return }
        let playing = nowPlaying.flatMap { tracks.contains($0) ? $0 : nil }
        var rest = tracks.filter { track in !moving.contains(track) }
        let at = playing.flatMap { rest.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        rest.insert(contentsOf: moving, at: at)
        tracks = rest
        if playing == nil { currentIndex = 0 }
        log("QUEUE", "Play next: " + moving.map(\.name).joined(separator: ", ") + ".")
        queueReordered()
    }

    /// Sorts the whole queue; the playing song keeps playing and just moves with it. The sorted
    /// order becomes the user's own, so shuffle and Mix Order go off (and a plain drag after it
    /// works on the sorted queue). Songs with nothing to sort by go last, in their order.
    func sortQueue(by sort: KnobShiftQueueSort) {
        let own = isArranged ? unshuffled : tracks
        if orderBeforeSort == nil { orderBeforeSort = own }
        replaceOwnOrder(with: Self.sorted(own, by: sort))
        log("QUEUE", "Sorted by \(sort.title).")
    }

    /// Takes a sort back: the order from before it, with songs removed since left out and songs
    /// added since after it.
    func restoreOrderBeforeSort() {
        guard let saved = orderBeforeSort else { return }
        let present = Set(tracks.map(\.id)), known = Set(saved.map(\.id))
        orderBeforeSort = nil
        replaceOwnOrder(with: saved.filter { present.contains($0.id) } + tracks.filter { !known.contains($0.id) })
        log("QUEUE", "Back to the order from before sorting.")
    }

    /// A new order of the user's own, so shuffle and Mix Order go off. The playing song keeps
    /// playing and moves with it.
    private func replaceOwnOrder(with order: [Track]) {
        let anchor = nowPlaying ?? (tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil)
        shuffleToRestore = nil
        mixOrderToRestore = false
        isShuffled = false
        isMixOrdered = false
        unshuffled = []
        tracks = order
        if let anchor, let index = tracks.firstIndex(of: anchor) { currentIndex = index }
        queueReordered()
    }

    /// The songs in this sort. Songs carry no date they were added, so "recently added" uses
    /// the order they were added in: the queue appends, so the last song is the newest.
    static func sorted(_ list: [Track], by sort: KnobShiftQueueSort) -> [Track] {
        let order = Array(list.enumerated())
        func lower(_ a: String?, _ b: String?) -> Bool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?):
                let result = a.localizedCaseInsensitiveCompare(b)
                return result == .orderedSame ? nil : result == .orderedAscending
            }
        }
        let sorted = order.sorted { x, y in
            let a = x.element, b = y.element
            var decided: Bool?
            switch sort {
            case .bpm:
                switch (a.analysis.tempo, b.analysis.tempo) {
                case let (p?, q?): decided = p == q ? nil : p < q
                case (nil, nil): decided = nil
                case (nil, _): decided = false
                default: decided = true
                }
            case .length: decided = a.duration == b.duration ? nil : a.duration < b.duration
            case .artist: decided = lower(a.artist, b.artist) ?? lower(a.name, b.name)
            case .recentlyAdded: decided = x.offset == y.offset ? nil : x.offset > y.offset
            }
            return decided ?? (x.offset < y.offset)
        }
        return sorted.map(\.element)
    }
}
