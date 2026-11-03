#if os(macOS)
import AppKit
/// A picture as each platform draws it: NSImage on the Mac, UIImage on the iPhone.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import AVFoundation

/// Cover art embedded in a local song file (the picture most MP3 and M4A files carry), read once
/// in the background and kept in memory for the player. Nothing is fetched from the internet.
@MainActor
enum KnobShiftArtwork {
    private static var cache: [URL: PlatformImage] = [:]
    private static var missing: Set<URL> = []

    static func cached(_ url: URL) -> PlatformImage? { cache[url] }

    static func load(_ url: URL) async -> PlatformImage? {
        if let image = cache[url] { return image }
        if missing.contains(url) { return nil }
        let data = await Task.detached(priority: .utility) { () -> Data? in
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
