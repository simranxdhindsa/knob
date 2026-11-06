import AVFoundation

/// Cover art embedded in a local song file (the picture most MP3 and M4A files carry), read once
/// in the background and kept in memory for the player. Nothing is fetched from the internet.
@MainActor
enum KnobShiftArtwork {
    private static var cache: [URL: PlatformImage] = [:]
    private static var missing: Set<URL> = []

    static func cached(_ url: URL) -> PlatformImage? { cache[url] }

    // MARK: Sharp covers

    /// Spotify song files carry a 640 pixel cover, which looks soft at full screen. Spotify has
    /// the same cover at up to 2000 pixels, so large views read it from there: once per song,
    /// kept on disk, so existing songs get sharper with no change to their files. Only the last
    /// few are held in memory, since each takes about 16 MB once drawn.
    private static var sharpCache: [URL: PlatformImage] = [:]
    private static var sharpOrder: [URL] = []
    private static var noSharp: Set<URL> = []
    private static let sharpKept = 4

    static func cachedSharp(_ url: URL) -> PlatformImage? { sharpCache[url] }

    static func sharp(_ url: URL) async -> PlatformImage? {
        if let image = sharpCache[url] { return image }
        guard !noSharp.contains(url), let id = KnobShiftPlaylists.songId(inFileName: url.deletingPathExtension().lastPathComponent),
              id.count == 22 else { return nil }
        let data = await Task.detached(priority: .utility) { await sharpData(id) }.value
        guard let image = data.flatMap({ PlatformImage(data: $0) }) else {
            noSharp.insert(url)
            return nil
        }
        sharpCache[url] = image
        sharpOrder.append(url)
        if sharpOrder.count > sharpKept { sharpCache[sharpOrder.removeFirst()] = nil }
        return image
    }

    private nonisolated static func sharpData(_ id: String) async -> Data? {
        let folder = URL.cachesDirectory.appendingPathComponent("KnobShift Covers", isDirectory: true)
        let file = folder.appendingPathComponent("\(id).jpg")
        if let saved = try? Data(contentsOf: file) { return saved }
        guard let page = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id)"),
              let reply = await fetch(page),
              let thumbnail = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["thumbnail_url"] as? String,
              let large = sharpLink(fromThumbnail: thumbnail), let data = await fetch(large) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private nonisolated static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 12_000_000 else { return nil }
        return data
    }

    /// The largest size of a Spotify cover from any size's link: only its first 16 letters differ.
    nonisolated static func sharpLink(fromThumbnail link: String) -> URL? {
        guard let name = link.split(separator: "/").last, name.count == 40, name.hasPrefix("ab67616d"),
              name.allSatisfy(\.isHexDigit) else { return nil }
        return URL(string: "https://i.scdn.co/image/ab67616d000082c1\(name.suffix(24))")
    }

    static func load(_ url: URL) async -> PlatformImage? {
        if let image = cache[url] { return image }
        if missing.contains(url) { return nil }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            if KnobShiftFlacTags.isFlac(url) { return KnobShiftFlacTags.read(url)?.cover }
            let asset = AVURLAsset(url: url)
            guard let items = try? await asset.load(.commonMetadata) else { return nil }
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue) { return data }
            }
            return nil
        }.value
        let image = data.flatMap { PlatformImage(data: $0) }
        if let image { cache[url] = image } else { missing.insert(url) }
        return image
    }
}
