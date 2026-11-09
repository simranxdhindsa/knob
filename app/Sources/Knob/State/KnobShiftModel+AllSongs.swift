import Foundation

/// The user's own queue, put aside while the All Songs queue plays.
struct KnobShiftOwnQueue {
    let tracks: [KnobShiftModel.Track]
    let unshuffled: [KnobShiftModel.Track]
    let orderBeforeSort: [KnobShiftModel.Track]?
    let nowPlaying: KnobShiftModel.Track?
    let currentIndex: Int
    let isShuffled: Bool
    let isMixOrdered: Bool
    let time: TimeInterval
    /// Every song the All Songs queue started with, so songs added while it plays can go back
    /// to the user's own queue.
    var allSongs: Set<URL> = []
}

/// All Songs as a queue of its own: every playlist's songs, shuffled, playing at once, while the
/// user's own queue waits untouched, with its order, shuffle and place. My Queue brings it back,
/// paused where it was, with any songs added in the meantime at its end. Only the user's own
/// queue is saved, so after a relaunch Knob opens on it.
extension KnobShiftModel {
    func playAllSongsQueue(_ songs: [KnobShiftPlaylistSong]) async {
        let ready = songs.filter { $0.url != nil }
        guard !ready.isEmpty, !isMirroring else { return }
        if !playingAllSongs {
            persistQueueNow()
            ownQueue = KnobShiftOwnQueue(tracks: tracks, unshuffled: unshuffled, orderBeforeSort: orderBeforeSort, nowPlaying: nowPlaying,
                                         currentIndex: currentIndex, isShuffled: isShuffled, isMixOrdered: isMixOrdered, time: playbackTime)
            stop()
            playingAllSongs = true
            log("QUEUE", "All Songs plays as its own queue; your queue of \(tracks.count) song(s) waits as it was.")
        } else {
            stop()
        }
        tracks = []
        unshuffled = []
        orderBeforeSort = nil
        isShuffled = false
        isMixOrdered = false
        currentIndex = 0
        ownQueue?.allSongs = Set(ready.compactMap { $0.url?.standardizedFileURL })
        await shuffleAll(ready)
    }

    /// Back to the user's own queue as it was, paused at the same place.
    func returnToOwnQueue() {
        guard playingAllSongs, let own = ownQueue else { return }
        let added = tracks.filter { !own.allSongs.contains($0.url.standardizedFileURL) && !own.tracks.contains($0) }
        stop()
        playingAllSongs = false
        ownQueue = nil
        tracks = own.tracks + added
        unshuffled = own.unshuffled.isEmpty ? [] : own.unshuffled + added
        orderBeforeSort = own.orderBeforeSort
        isShuffled = own.isShuffled
        isMixOrdered = own.isMixOrdered
        currentIndex = min(own.currentIndex, max(0, tracks.count - 1))
        mixState = tracks.isEmpty ? .idle : .ready
        if let track = own.nowPlaying, tracks.contains(track) {
            try? schedulePrimary(track, from: min(own.time, track.duration), play: false)
        }
        persistQueue()
        log("QUEUE", "Back to your own queue of \(tracks.count) song(s)" + (added.isEmpty ? "." : ", with \(added.count) added while All Songs played."))
    }
}
