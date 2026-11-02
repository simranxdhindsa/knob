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
            let title = await values(.commonKeyTitle).first
            // Several artist tags, or one with "/" between names, show joined like Spotify does.
            let artists = await values(.commonKeyArtist)
                .flatMap { $0.components(separatedBy: "/") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let album = await values(.commonKeyAlbumName).first
            guard title != nil || !artists.isEmpty else { return nil }
            return Tags(title: title, artist: artists.isEmpty ? nil : artists.joined(separator: ", "), album: album)
        }.value
    }
}
