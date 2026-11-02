import SwiftUI

/// A song's embedded cover art with rounded corners, or, when the file carries none, a cover
/// drawn for it (GeneratedArtwork) that drifts gently while `animated`. `lit` adds the accent
/// glow used for the playing song.
struct AlbumArtwork: View {
    let url: URL?
    var size: CGFloat
    var lit = false
    var animated = false

    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let url {
                GeneratedArtwork(seed: url.deletingPathExtension().lastPathComponent, animated: animated)
            } else {
                LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(Palette.accent.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Screen.highlight, lineWidth: 1))
        .shadow(color: lit ? Palette.accentGlow.opacity(0.45) : .black.opacity(0.35), radius: lit ? size * 0.12 : size * 0.06, y: 2)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = KnobShiftArtwork.cached(url)
            if image == nil { image = await KnobShiftArtwork.load(url) }
        }
        .accessibilityHidden(true)
    }
}
