import Foundation

/// What the YouTube dashboard shows: the Google key, the code while signing in, and the rows read
/// from the signed in person's YouTube. Kept apart from KnobShiftModel so the player does not
/// redraw while the dashboard loads; the sheet observes it directly.
/// The actions are in KnobShiftModel+YouTubeDashboard.
@MainActor
final class KnobShiftYouTubeHub: ObservableObject {
    typealias Video = KnobShiftYouTubeAPIParsing.Video
    typealias Playlist = KnobShiftYouTubeAPIParsing.Playlist

    enum Shelf: String, CaseIterable, Identifiable {
        case liked, new, popular
        var id: String { rawValue }
    }

    @Published var hasKey = KnobShiftGoogleAuth.hasKey
    /// The code to enter at google.com/device, while signing in.
    @Published var code: KnobShiftGoogleAuth.DeviceCode?
    /// Each row's videos as read, before the music filter; nil until read.
    @Published var shelves: [Shelf: [Video]] = [:]
    @Published var playlists: [Playlist]?
    @Published var loading = false
    var loadedAt: Date?
    var signInTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    /// Stops a read from Google for the song picker, so CANCEL stops its requests too.
    var cancelRead: (() -> Void)?
    /// Changes on every sign in and sign out, so a load that started before is not shown after.
    var generation = 0

    /// The dashboard ids in KnobShift: Liked videos is YouTube's own list "LL"; the other two are
    /// Knob's.
    static let likedId = KnobShiftPlaylists.youtubePrefix + "LL"
    static let newId = KnobShiftPlaylists.youtubePrefix + "KNOBNEW"
    static let popularId = KnobShiftPlaylists.youtubePrefix + "KNOBPOPULAR"

    static func shelf(forPlaylistId id: String) -> Shelf? {
        switch id {
        case likedId: return .liked
        case newId: return .new
        case popularId: return .popular
        default: return nil
        }
    }

    static func playlistId(_ shelf: Shelf) -> String {
        switch shelf {
        case .liked: return likedId
        case .new: return newId
        case .popular: return popularId
        }
    }

    static func title(_ shelf: Shelf, musicOnly: Bool) -> String {
        switch shelf {
        case .liked: return musicOnly ? "Liked music" : "Liked videos"
        case .new: return musicOnly ? "New music from your subscriptions" : "New from your subscriptions"
        case .popular: return "Popular music in \(KnobShiftYouTubeAPI.regionName)"
        }
    }

    /// The row's songs as they are shown: music only when asked (the chart is music already).
    func videos(_ shelf: Shelf, musicOnly: Bool) -> [Video]? {
        shelves[shelf].map { KnobShiftYouTubeAPIParsing.filtered($0, musicOnly: musicOnly && shelf != .popular) }
    }

    func clear() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        loading = false
        shelves = [:]
        playlists = nil
        loadedAt = nil
        code = nil
    }
}
