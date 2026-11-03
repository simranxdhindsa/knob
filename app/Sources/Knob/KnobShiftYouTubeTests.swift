import Foundation

/// Unit tests for KnobShift's YouTube import, run by `--knobshift-youtube-check selftest`, with
/// no network: reading links, cleaning video titles into song names, reading yt-dlp's lists,
/// YouTube ids in file names, folders by source, the arguments handed to yt-dlp, and reading
/// what went wrong.
@MainActor
enum KnobShiftYouTubeTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run() {
        links()
        titles()
        listings()
        fileNames()
        playlists()
        arguments()
        problems()
        print(failures == 0 ? "KnobShift YouTube self test passed" : "KnobShift YouTube self test: \(failures) failure(s)")
    }

    private static func links() {
        print("Links")
        let video = "fOT0BUpITw8"
        let list = "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"
        let parse = KnobShiftYouTubeParsing.parseLink
        expect(parse("https://youtu.be/\(video)?si=abc") == .init(url: "https://www.youtube.com/watch?v=\(video)", id: "yt:\(video)", kind: .song), "short link is a song")
        expect(parse("https://www.youtube.com/watch?v=\(video)&t=42s")?.kind == .song, "watch link is a song")
        expect(parse("https://m.youtube.com/watch?v=\(video)")?.id == "yt:\(video)", "phone link")
        expect(parse("youtube.com/watch?v=\(video)")?.kind == .song, "link without https")
        expect(parse("https://www.youtube.com/shorts/\(video)")?.kind == .song, "shorts link")
        expect(parse("https://www.youtube.com/watch?v=\(video)&list=\(list)") == .init(url: "https://www.youtube.com/playlist?list=\(list)", id: "yt:\(list)", kind: .playlist), "video in a playlist means the playlist")
        expect(parse("https://www.youtube.com/watch?v=\(video)&list=RD\(video)")?.kind == .song, "a mix is endless, so only the video")
        expect(parse("https://www.youtube.com/playlist?list=\(list)")?.kind == .playlist, "playlist link")
        expect(parse("https://music.youtube.com/watch?v=\(video)")?.kind == .song, "YouTube Music song")
        expect(parse("https://music.youtube.com/playlist?list=OLAK5uy_kXbzIvZ2Ab3CdEf4GhIjKlMnOpQrStUvW")?.kind == .album, "YouTube Music album")
        expect(parse("https://music.youtube.com/browse/MPREb_AbCdEfGhIjK") == .init(url: "https://music.youtube.com/browse/MPREb_AbCdEfGhIjK", id: "yt:MPREb_AbCdEfGhIjK", kind: .album), "album page")
        expect(parse("https://www.youtube.com/playlist?list=LL")?.kind == .liked, "Liked videos")
        expect(parse("https://www.youtube.com/@channel") == nil, "a channel is not a list")
        expect(parse("https://youtube.com.example.com/watch?v=\(video)") == nil, "a look alike site is refused")
        expect(parse("https://www.youtube.com/watch?v=short") == nil, "a broken video id is refused")
        expect(parse("https://open.spotify.com/track/37i9dQZF1E8UXBoz02kGID") == nil, "Spotify is not YouTube")
        expect(parse("--exec rm") == nil, "plain text is refused")
    }

    private static func titles() {
        print("Song names from video titles")
        let split = KnobShiftYouTubeParsing.song
        let a = split("BELLAKEO (Video Oficial) - Peso Pluma, Anitta", "Peso Pluma")
        expect(a.name == "BELLAKEO" && a.artists == ["Peso Pluma", "Anitta"], "song first, artists after, by the channel")
        let b = split("Arcángel - FN8 ( Video Lyric )", "Arcangel")
        expect(b.name == "FN8" && b.artists == ["Arcángel"], "artist first; lyric video note dropped")
        let c = split("Becky G - POR EL CONTRARIO (Performance Video) ft. Ángela Aguilar, Leonardo Aguilar", "Becky G")
        expect(c.name == "POR EL CONTRARIO (feat. Ángela Aguilar, Leonardo Aguilar)" && c.artists == ["Becky G"], "featured artists written like Spotify")
        let d = split("Jee Karuga", "Karan Aujla - Topic")
        expect(d.name == "Jee Karuga" && d.artists == ["Karan Aujla"], "YouTube Music topic channel is the artist")
        let e = split("Shubh - Cheques (Remix) [Official Audio]", "Shubh")
        expect(e.name == "Cheques (Remix)" && e.artists == ["Shubh"], "remix kept, official audio dropped")
        let f = split("Kya Baat Aa | Karan Aujla | Latest Punjabi Songs 2026", "Rehaan Records")
        expect(f.name == "Kya Baat Aa" && f.artists == ["Karan Aujla"], "bar separated title")
        let g = split("ਖੀਰ ਤੇ ਵੈਰ (Official Music Video)", "Sidhu Moose Wala")
        expect(g.name == "ਖੀਰ ਤੇ ਵੈਰ" && g.artists == ["Sidhu Moose Wala"], "Gurmukhi kept")
        let h = split("Song Name", "SomeArtistVEVO")
        expect(h.artists == ["SomeArtist"], "VEVO dropped from the channel")
        let i = split("Artist One & Artist Two - Together", "Label")
        expect(i.name == "Together" && i.artists == ["Artist One", "Artist Two"], "two artists joined by &")
    }

    private static let playlistJSON = #"""
    {"_type": "playlist", "id": "PLx", "title": "Road Trip", "channel": "Simran",
     "entries": [
      {"id": "fOT0BUpITw8", "title": "BELLAKEO (Video Oficial) - Peso Pluma, Anitta", "duration": 235, "channel": "Peso Pluma"},
      {"id": "AAAAAAAAAAA", "title": "[Private video]", "duration": null, "channel": null},
      {"id": "BBBBBBBBBBB", "title": "[Deleted video]", "duration": null, "channel": null},
      {"id": "CCCCCCCCCCC", "title": "Members only", "availability": "subscriber_only", "channel": "X"},
      {"id": "NFvDHYMzj9U", "title": "Arcángel - FN8 ( Video Lyric )", "duration": 650.0, "channel": "Arcangel"},
      {"id": "8c7KOGxeY3w", "track": "Por El Contrario", "artists": ["Becky G", "Ángela Aguilar"], "album": "Esquinas",
       "title": "ignored when YouTube Music names it", "duration": 235, "channel": "Becky G"}
     ]}
    """#

    private static func listings() {
        print("Reading yt-dlp's lists")
        guard let list = KnobShiftYouTubeParsing.listing(from: Data(playlistJSON.utf8), kind: .playlist) else {
            expect(false, "playlist read")
            return
        }
        expect(list.name == "Road Trip", "list name")
        expect(list.listing.songs.map(\.song_id) == ["fOT0BUpITw8", "NFvDHYMzj9U", "8c7KOGxeY3w"], "private, deleted and members only videos left out, order kept")
        expect(list.listing.songs.map(\.list_position) == [1, 2, 3], "positions count the songs kept")
        expect(list.skipped == 3, "how many were left out")
        let first = list.listing.songs[0]
        expect(first.name == "BELLAKEO" && first.artist == "Peso Pluma" && first.duration == 235, "names and length")
        expect(first.url == "https://www.youtube.com/watch?v=fOT0BUpITw8", "song link")
        let music = list.listing.songs[2]
        expect(music.name == "Por El Contrario" && music.artists == ["Becky G", "Ángela Aguilar"] && music.album_name == "Esquinas", "YouTube Music's own names win")
        // The raw entries are a save file the Spotify code already reads back (resume, retry).
        let joined = "[" + list.listing.songs.compactMap { list.listing.raw[$0.song_id].map { String(decoding: $0, as: UTF8.self) } }.joined(separator: ",") + "]"
        expect(KnobShiftSpotDL.listing(from: Data(joined.utf8))?.songs == list.listing.songs, "kept songs read back the same")
        let single = #"{"id": "fOT0BUpITw8", "title": "Peso Pluma - BELLAKEO", "duration": 235, "channel": "Peso Pluma"}"#
        let one = KnobShiftYouTubeParsing.listing(from: Data(single.utf8), kind: .song)
        expect(one?.listing.songs.count == 1 && one?.name == "BELLAKEO by Peso Pluma", "a single video")
        expect(KnobShiftYouTubeParsing.listing(from: Data("not json".utf8), kind: .playlist) == nil, "broken output")
    }

    private static func fileNames() {
        print("YouTube ids in file names")
        let file = "03 BELLAKEO - Peso Pluma, Anitta [yt-fOT0BUpITw8]"
        expect(KnobShiftPlaylists.songId(inFileName: file) == "fOT0BUpITw8", "YouTube id from a file name")
        expect(KnobShiftPlaylists.songId(inFileName: "07 Song - Artist [37i9dQZF1E8UXBoz02kGID]") == "37i9dQZF1E8UXBoz02kGID", "Spotify ids still read")
        expect(KnobShiftPlaylists.songId(inFileName: "Song [yt-short]") == nil, "only real YouTube ids")
        expect(KnobShiftPlaylists.songId(inFileName: "Song [Remastered]") == nil, "ordinary brackets are not ids")
        expect(KnobShiftModel.Track.split(file).name == "BELLAKEO" && KnobShiftModel.Track.split(file).artist == "Peso Pluma, Anitta", "shown as song and artists")
        let song = KnobShiftSpotDL.Song(name: "AC/DC: Live 100%", artists: ["Band"], artist: "Band", album_name: nil, duration: 1,
                                        song_id: "fOT0BUpITw8", url: "", list_name: nil, list_position: 3)
        expect(KnobShiftYouTubeParsing.fileName(for: song) == "03 AC DC  Live 100% - Band [yt-fOT0BUpITw8]", "file name safe for Finder")
        expect(KnobShiftYouTubeParsing.outputTemplate(for: song).hasSuffix("100%% - Band [yt-fOT0BUpITw8].%(ext)s"), "percent signs escaped for yt-dlp")
    }

    private static func playlists() {
        print("Playlists by source")
        let youtube = KnobShiftPlaylist(id: "yt:PLx", name: "Road Trip", link: "", kind: .playlist, folderName: "Road Trip",
                                        spotifyOrder: [], addedAt: Date())
        let spotify = KnobShiftPlaylist(id: "37i9dQZF1E8UXBoz02kGID", name: "Road Trip", link: "", kind: .playlist,
                                        folderName: "Road Trip", spotifyOrder: [], addedAt: Date())
        expect(youtube.source == .youtube && spotify.source == .spotify, "source read from the id")
        expect(KnobShiftPlaylists.folder(for: youtube).path.hasSuffix("KnobShift/YouTube/Road Trip")
               || ProcessInfo.processInfo.environment["KNOB_YOUTUBE_ROOT"] != nil, "YouTube songs live in Music, KnobShift, YouTube")
        expect(KnobShiftPlaylists.folder(for: youtube) != KnobShiftPlaylists.folder(for: spotify), "same name, separate folders")
        let old = #"{"playlists":[{"id":"a1","name":"Old","link":"x","kind":"playlist","folderName":"Old","spotifyOrder":[],"addedAt":"2026-10-30T10:00:00Z"}],"removed":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        expect((try? decoder.decode(KnobShiftPlaylists.Index.self, from: Data(old.utf8)))?.playlists.first?.source == .spotify, "playlists saved before YouTube still load")
        var progress = KnobShiftImport.Progress(songs: [KnobShiftSpotDL.Song(name: "A", artists: ["B"], artist: "B", album_name: nil, duration: 1,
                                                                             song_id: "fOT0BUpITw8", url: "", list_name: nil, list_position: 1)])
        progress.markMissing("fOT0BUpITw8")
        expect(progress.missing == ["fOT0BUpITw8"] && progress.finished == 1, "a song can be marked missing by id")
    }

    private static func arguments() {
        print("What yt-dlp is given")
        let song = KnobShiftSpotDL.Song(name: "Song", artists: ["Artist"], artist: "Artist", album_name: nil, duration: 1,
                                        song_id: "fOT0BUpITw8", url: "https://www.youtube.com/watch?v=fOT0BUpITw8", list_name: nil, list_position: 1)
        let folder = URL(fileURLWithPath: "/tmp/knob")
        let download = KnobShiftYouTubeParsing.downloadArguments(for: song, into: folder, ffmpeg: "/x/ffmpeg", cookies: nil)
        expect(download.suffix(2) == ["--", "https://www.youtube.com/watch?v=fOT0BUpITw8"], "the link comes last, after --, so it is never read as an option")
        expect(!download.contains("--cookies"), "no sign in, no cookies")
        let signedIn = KnobShiftYouTubeParsing.downloadArguments(for: song, into: folder, ffmpeg: "/x/ffmpeg", cookies: URL(fileURLWithPath: "/c.txt"))
        expect(signedIn.contains("--cookies") && signedIn.contains("/c.txt"), "signed in uses Knob's own cookie file")
        let search = KnobShiftYouTubeParsing.searchArguments(for: song, into: folder, ffmpeg: "/x/ffmpeg", cookies: nil)
        expect(search.last == "ytsearch1:Artist Song", "a missing video is searched by artist and name")
        let list = KnobShiftYouTubeParsing.listArguments("https://www.youtube.com/playlist?list=PLx", cookies: nil)
        expect(list.contains("--flat-playlist") && list.suffix(2) == ["--", "https://www.youtube.com/playlist?list=PLx"], "listing reads quickly and safely")
    }

    private static func problems() {
        print("Reading what went wrong")
        let classify = KnobShiftYouTubeParsing.classify
        expect(classify(["ERROR: [youtube] x: Sign in to confirm you’re not a bot."]) == .botCheck, "bot check")
        expect(classify(["WARNING: Unable to download webpage: HTTP Error 429: Too Many Requests"]) == .botCheck, "too many requests")
        expect(classify(["ERROR: [youtube] x: Private video. Sign in if you've been granted access to this video"]) == .privateVideo, "private video")
        expect(classify(["ERROR: [youtube] x: Video unavailable. This video has been removed by the uploader"]) == .unavailable, "removed video")
        expect(classify(["ERROR: [youtube] x: The uploader has not made this video available in your country"]) == .unavailable, "blocked in this country")
        expect(classify(["ERROR: [youtube] x: Sign in to confirm your age. This video may be inappropriate for some users."]) == .ageRestricted, "age restricted")
        expect(classify(["ERROR: [youtube:tab] PLx: The playlist does not exist."]) == .unavailable, "missing playlist")
        expect(classify(["<urlopen error [Errno 8] nodename nor servname provided, or not known>"]) == .offline, "offline")
        expect(classify(["ERROR: Postprocessing: [Errno 28] No space left on device"]) == .noSpace, "disk full")
        expect(classify(["[download] 100% of 3.5MiB"]) == nil, "a normal run is no failure")
        expect(!KnobShiftYouTubeParsing.Failure.botCheck.message.contains("-"), "messages have no dashes")
    }
}
