import Foundation

/// Unit tests for the YouTube dashboard and the Google sign in, run with the YouTube self test
/// (`--knobshift-youtube-check selftest`), with no network: Google's sign in answers, the YouTube
/// Data API's answers, channel feeds, song lengths and the music filter.
@MainActor
enum KnobShiftYouTubeAPITests {
    static func run(_ expect: (Bool, String) -> Void) {
        signIn(expect)
        answers(expect)
        feeds(expect)
        music(expect)
    }

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    private static func signIn(_ expect: (Bool, String) -> Void) {
        print("Signing in with Google")
        let auth = KnobShiftGoogleAuth.self
        let code = auth.deviceCode(from: data(#"{"device_code":"dc","user_code":"ABCD-EFGH","verification_url":"https://www.google.com/device","interval":5,"expires_in":1800}"#))
        expect(code?.userCode == "ABCD-EFGH" && code?.interval == 5, "a code to show is read")
        let elsewhere = auth.deviceCode(from: data(#"{"device_code":"dc","user_code":"X","verification_url":"https://evil.example/device"}"#))
        expect(elsewhere?.verificationURL.host == "www.google.com", "only Google's own page is ever opened")
        for lookAlike in ["https://evilgoogle.com/device", "https://www.google.com.evil.example/device", "https://www.google.com:8443/device",
                          "https://user@www.google.com/device", "http://www.google.com/device", "https://www.google.com/device/../x"] {
            let opened = auth.deviceCode(from: data(#"{"device_code":"dc","user_code":"X","verification_url":"\#(lookAlike)"}"#))
            expect(opened?.verificationURL.absoluteString == "https://www.google.com/device", "look alike page refused: \(lookAlike)")
        }
        expect(auth.deviceCode(from: data(#"{"error":"invalid_client"}"#)) == nil, "an error is no code")
        expect(auth.poll(from: data(#"{"error":"authorization_pending"}"#)) == .pending, "waiting for the code")
        expect(auth.poll(from: data(#"{"error":"slow_down"}"#)) == .slowDown, "asked to wait longer")
        expect(auth.poll(from: data(#"{"error":"access_denied"}"#)) == .failed(.denied), "turned down")
        expect(auth.poll(from: data(#"{"error":"expired_token"}"#)) == .failed(.expired), "code ran out")
        if case .approved = auth.poll(from: data(#"{"access_token":"a","refresh_token":"r","expires_in":3599}"#)) {
            expect(true, "signed in")
        } else {
            expect(false, "signed in")
        }
        expect(auth.keyProblem(data(#"{"error":"invalid_client","error_description":"Invalid client type."}"#)) == .wrongKeyType,
               "a key for another kind of app")
        expect(auth.keyProblem(data(#"{"error":"invalid_client","error_description":"The OAuth client was not found."}"#)) == .badKey, "an unknown key")
        expect(auth.formBody(["token": "a b&c=d", "id": "1"]) == "id=1&token=a%20b%26c%3Dd", "form values are escaped")
        for problem in [KnobShiftGoogleAuth.Problem.noKey, .badKey, .wrongKeyType, .denied, .expired, .signedOut, .offline, .failed] {
            expect(!problem.message.contains("-"), "\(problem) message has no dashes")
        }
    }

    private static func answers(_ expect: (Bool, String) -> Void) {
        print("Reading YouTube's answers")
        let parse = KnobShiftYouTubeAPIParsing.self
        let videos = parse.videos(data("""
        {"nextPageToken":"N2","items":[
          {"id":"fOT0BUpITw8","snippet":{"title":"Sidhu Moose Wala - 295 (Official Audio)","channelTitle":"Sidhu Moose Wala","categoryId":"10",
            "publishedAt":"2026-10-01T10:00:00Z","thumbnails":{"medium":{"url":"https://i.ytimg.com/vi/fOT0BUpITw8/mqdefault.jpg"}}},
           "contentDetails":{"duration":"PT4M33S"}},
          {"id":"bad","snippet":{"title":"x"}},
          {"id":"aaaaaaaaaaa","snippet":{"title":"Vlog","channelTitle":"C","categoryId":"22","thumbnails":{"default":{"url":"https://evil.example/t.jpg"}}}}
        ]}
        """))
        expect(videos.items.count == 2 && videos.next == "N2" && videos.skipped == 1, "videos and the next page")
        expect(videos.items[0].duration == 273 && videos.items[0].isMusic, "length and music category")
        expect(videos.items[1].thumbnail == nil, "thumbnails only from YouTube's own image server")
        let lookAlike = parse.videos(data(#"{"items":[{"id":"aaaaaaaaaaa","snippet":{"title":"x","thumbnails":{"default":{"url":"https://evilytimg.com/t.jpg"}}}}]}"#))
        expect(lookAlike.items.first?.thumbnail == nil, "a look alike image server is refused")
        let items = parse.playlistItems(data("""
        {"items":[
          {"snippet":{"title":"Song","videoOwnerChannelTitle":"Artist - Topic","resourceId":{"videoId":"fOT0BUpITw8"}},"status":{"privacyStatus":"public"}},
          {"snippet":{"title":"Private video","resourceId":{"videoId":"bbbbbbbbbbb"}},"status":{"privacyStatus":"private"}},
          {"snippet":{"title":"Deleted video","resourceId":{"videoId":"ccccccccccc"}}}
        ]}
        """))
        expect(items.items.map(\.id) == ["fOT0BUpITw8"] && items.skipped == 2, "private and deleted videos are left out and counted")
        let lists = parse.playlists(data(#"{"items":[{"id":"PLx","snippet":{"title":"Drive"},"contentDetails":{"itemCount":12}}]}"#))
        expect(lists.items == [.init(id: "PLx", title: "Drive", count: 12, thumbnail: nil)], "playlists")
        let subscriptions = parse.subscriptions(data(#"{"items":[{"snippet":{"resourceId":{"channelId":"UC1"}}}]}"#))
        expect(subscriptions.items == ["UC1"], "subscribed channels")
        let quota = data(#"{"error":{"code":403,"errors":[{"reason":"quotaExceeded"}]}}"#)
        expect(parse.problem(quota, status: 403) == .quota, "daily limit used up")
        expect(parse.problem(data(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#), status: 403) == .apiOff,
               "YouTube Data API not turned on")
        expect(parse.problem(data(#"{"error":{"code":401,"errors":[{"reason":"authError"}]}}"#), status: 401) == .signedOut, "token refused")
        expect(parse.problem(data(#"{"items":[]}"#), status: 200) == nil, "a normal answer is no problem")
        for problem in [KnobShiftYouTubeAPIParsing.Problem.signedOut, .quota, .apiOff, .notFound, .offline, .failed] {
            expect(!problem.message.contains("-"), "\(problem) message has no dashes")
        }
    }

    private static func feeds(_ expect: (Bool, String) -> Void) {
        print("Reading channel feeds")
        let feed = KnobShiftYouTubeAPIParsing.feed(data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
         <title>Channel</title>
         <entry>
          <id>yt:video:fOT0BUpITw8</id><yt:videoId>fOT0BUpITw8</yt:videoId>
          <title>New Song &amp; More</title>
          <author><name>Artist</name></author>
          <published>2026-10-30T12:00:00+00:00</published>
         </entry>
         <entry><yt:videoId>not-an-id</yt:videoId><title>x</title></entry>
        </feed>
        """))
        expect(feed.count == 1 && feed[0].title == "New Song & More" && feed[0].channel == "Artist", "a feed's videos")
        expect(feed.first?.published != nil, "when it was published")
    }

    private static func music(_ expect: (Bool, String) -> Void) {
        print("Music only")
        let parse = KnobShiftYouTubeAPIParsing.self
        expect(parse.seconds("PT3M41S") == 221 && parse.seconds("PT1H2S") == 3602 && parse.seconds("P0D") == 0, "song lengths")
        expect(parse.seconds("3:41") == nil && parse.seconds("PT3X") == nil, "anything else is no length")
        func video(_ id: String, _ category: String?, _ length: Double?) -> KnobShiftYouTubeAPIParsing.Video {
            .init(id: id, title: "t", channel: "c", categoryId: category, duration: length, thumbnail: nil, published: nil)
        }
        let all = [video("a", "10", 200), video("b", "22", 200), video("c", "10", 30), video("d", "10", 3600), video("e", nil, nil)]
        expect(parse.filtered(all, musicOnly: true).map(\.id) == ["a", "e"], "music only: no vlogs, Shorts or long mixes; unknown stays")
        expect(parse.filtered(all, musicOnly: false).count == 5, "every video when Music only is off")
        let listing = parse.listing([video("fOT0BUpITw8", "10", 200), video("fOT0BUpITw8", "10", 200)], listName: "Liked music")
        expect(listing.songs.count == 1 && listing.songs[0].list_position == 1 && listing.raw["fOT0BUpITw8"] != nil,
               "videos become songs once each, ready for the picker and downloads")
        expect(KnobShiftYouTubeHub.shelf(forPlaylistId: KnobShiftYouTubeHub.likedId) == .liked
               && KnobShiftYouTubeHub.shelf(forPlaylistId: "yt:PLx") == nil, "dashboard lists are told apart from playlists")
    }
}
