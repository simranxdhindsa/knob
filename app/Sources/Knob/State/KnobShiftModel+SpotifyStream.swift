import Foundation

/// Long Spotify lists without the wait. Spotify's player shows the first 100 songs of a list in
/// about a second; the rest needs spotDL, which Spotify can keep waiting for minutes. So the
/// picker opens with those 100 at once and the rest joins them as it arrives. Add All closes the
/// picker straight away: the songs download one by one in the background, the rest of the list
/// joins them when it comes, and nothing already in the queue is ever added twice.
extension KnobShiftModel {
    /// How long spotDL may stay silent over the rest of a long list. The first songs are already
    /// showing, so nobody is stuck waiting on it.
    static let restOfListIdle: TimeInterval = 180

    /// Opens the picker on a list read from Spotify.
    func showSpotifyReview(playlistId: String, name: String, kind: KnobShiftPlaylist.Kind, query: String,
                           songs: [KnobShiftSpotDL.Song], queued: Set<String>, skipped: Set<String>,
                           isUpdate: Bool, loadingMore: Bool) {
        let initial = KnobShiftImport.initialSelection(songs: songs, skipped: skipped).union(queued)
        spotifyReview = SpotifyReview(playlistId: playlistId, name: name, kind: kind, query: query, songs: songs,
                                      queued: queued, initial: initial, isUpdate: isUpdate, loadingMore: loadingMore,
                                      skipped: skipped)
        spotifyStatus = nil
    }

    /// More of the list on screen: each song once, in the list's order, ticked unless unticked
    /// before. Songs of any other list are ignored.
    func addToSpotifyReview(playlistId: String, songs more: [KnobShiftSpotDL.Song], skipped: Set<String>, finished: Bool) {
        guard var review = spotifyReview, review.playlistId == playlistId else { return }
        let known = Set(review.songs.map(\.song_id))
        review.songs = KnobShiftImport.merged(review.songs, more)
        let fresh = review.songs.filter { !known.contains($0.song_id) }
        review.initial.formUnion(KnobShiftImport.initialSelection(songs: fresh, skipped: skipped))
        review.skipped.formUnion(skipped)
        if finished { review.loadingMore = false }
        spotifyReview = review
    }

    /// Add All: every song except those unticked before. The picker closes at once; when the
    /// rest of the list is still coming, it is added in the background as it arrives.
    func addAllFromSpotifyReview() {
        guard let review = spotifyReview else { return }
        spotifyReview = nil
        if review.loadingMore { spotifyAddingAll = review.playlistId }
        applySpotifySelection(review, selected: KnobShiftImport.addAllSelection(songs: review.songs, skipped: review.skipped))
        log("SPOTIFY", "\(review.name): Add All, \(review.newCount) new song(s)" + (review.loadingMore ? ", the rest joins as it is read." : "."))
        if review.loadingMore { spotifyStatus = "Adding all of \(review.name). The rest of its songs join in the background." }
    }

    /// Shows the first part of a long list at once and reads the rest, for the picker or for an
    /// Add All already running in the background.
    func readRestOfList(query: String, id: String, kind: KnobShiftPlaylist.Kind, job: UUID,
                        first: KnobShiftSpotDL.Listing, title: String?) async {
        let ordered = KnobShiftImport.merged([], first.songs)
        spotifyRaw[id, default: [:]].merge(first.raw) { _, new in new }
        let existing = playlists.first { $0.id == id }
        let name = existing?.name ?? title ?? ordered.first?.list_name ?? "Spotify playlist"
        let skipped = Set(existing?.skipped ?? [])
        showSpotifyReview(playlistId: id, name: name, kind: kind, query: query, songs: ordered, queued: queuedSpotifyIds(in: id),
                          skipped: skipped, isUpdate: existing != nil, loadingMore: true)
        log("SPOTIFY", "\(name): showing the first \(ordered.count) song(s) while spotDL reads the rest.")
        var rest: [KnobShiftSpotDL.Song] = []
        do {
            let listing = try await KnobShiftSpotDL.shared.list(query, userAuth: spotifyLoggedIn, id: job, idleLimit: Self.restOfListIdle)
            spotifyRaw[id, default: [:]].merge(listing.raw) { _, new in new }
            rest = listing.songs
            log("SPOTIFY", "\(name): the rest arrived, \(listing.songs.count) song(s) in all.")
        } catch is CancellationError {
            if spotifyAddingAll == id { spotifyAddingAll = nil }
            return
        } catch {
            log("SPOTIFY", "\(name): could not read past the first \(ordered.count) song(s) (\(error)).")
            spotifyStatus = "Spotify showed only the first \(ordered.count) songs of \(name). Update it later for the rest."
        }
        guard spotifyReadJob == job else {
            if spotifyAddingAll == id { spotifyAddingAll = nil }
            return
        }
        finishRestOfList(id: id, kind: kind, query: query, first: ordered, rest: rest, skipped: skipped)
    }

    /// The rest of a long list arrived: into the picker if it is still open, otherwise into the
    /// Add All running in the background.
    func finishRestOfList(id: String, kind: KnobShiftPlaylist.Kind, query: String, first: [KnobShiftSpotDL.Song],
                          rest: [KnobShiftSpotDL.Song], skipped: Set<String>) {
        if spotifyReview?.playlistId == id {
            addToSpotifyReview(playlistId: id, songs: rest, skipped: skipped, finished: true)
            return
        }
        guard spotifyAddingAll == id else { return }
        spotifyAddingAll = nil
        guard !rest.isEmpty, let playlist = playlists.first(where: { $0.id == id }) else { return }
        let full = KnobShiftImport.merged(first, rest)
        let review = SpotifyReview(playlistId: id, name: playlist.name, kind: kind, query: query, songs: full,
                                   queued: queuedSpotifyIds(in: id), initial: [], isUpdate: true, skipped: skipped)
        log("SPOTIFY", "\(playlist.name): adding the rest of the list in the background, \(review.newCount) more song(s).")
        applySpotifySelection(review, selected: KnobShiftImport.addAllSelection(songs: full, skipped: skipped))
    }
}
