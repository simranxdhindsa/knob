import AVFoundation

/// A song's own title, artists and album from its file's tags, so songs show the way the music
/// service named them ("Karan Aujla, Ikky") rather than whatever the file is called. Songs
/// without tags fall back to their file name.
enum KnobShiftTags {
    struct Tags: Equatable {
        let title: String?
        let artist: String?
        let album: String?
    }

    static func read(_ url: URL) async -> Tags? {
        await Task.detached(priority: .utility) { () -> Tags? in
            if KnobShiftFlacTags.isFlac(url) {
                guard let found = KnobShiftFlacTags.read(url) else { return nil }
                return tags(title: found.all("TITLE").first, artists: found.all("ARTIST"), album: found.all("ALBUM").first)
            }
            let asset = AVURLAsset(url: url)
            guard let items = try? await asset.load(.commonMetadata) else { return nil }
            func values(_ key: AVMetadataKey) async -> [String] {
                var found: [String] = []
                for item in AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common) {
                    if let text = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty, !found.contains(text) {
                        found.append(text)
                    }
                }
                return found
            }
            return tags(title: await values(.commonKeyTitle).first, artists: await values(.commonKeyArtist),
                        album: await values(.commonKeyAlbumName).first)
        }.value
    }

    /// Several artist tags, or one with "/" between names, show joined like Spotify does.
    static func tags(title: String?, artists: [String], album: String?) -> Tags? {
        let names = artists
            .flatMap { $0.components(separatedBy: "/") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard title != nil || !names.isEmpty else { return nil }
        return Tags(title: title, artist: names.isEmpty ? nil : names.joined(separator: ", "), album: album)
    }
}
