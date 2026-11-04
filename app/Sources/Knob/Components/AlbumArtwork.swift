import SwiftUI

/// A song's embedded cover art with rounded corners, or, when the file carries none, a cover
/// drawn for it (GeneratedArtwork) that drifts gently while `animated`. `lit` adds the accent
/// glow used for the playing song.
struct AlbumArtwork: View {
    let url: URL?
    var size: CGFloat
    var lit = false
    var animated = false
    /// How round the corners are, as a share of the size.
    var corner: CGFloat = 0.14

    @Environment(\.surface) private var surface
    @State private var image: PlatformImage?
    @State private var shown: Bool
    /// Shows only the file's own cover, never the drawn stand in: a song still being prepared.
    private var realOnly = false
    private var holdsGrey = false

    /// `reveal` brings the cover up from grey when it first appears: a song that has just been
    /// prepared. `greyed` holds it there, while the song is prepared. A cover already read is
    /// there from the first frame, so its stand in never flashes.
    @MainActor
    init(url: URL?, size: CGFloat, lit: Bool = false, animated: Bool = false, corner: CGFloat = 0.14, reveal: Bool = false, greyed: Bool = false) {
        self.url = url
        self.size = size
        self.lit = lit
        self.animated = animated
        self.corner = corner
        _image = State(initialValue: url.flatMap(KnobShiftArtwork.cached))
        _shown = State(initialValue: !reveal && !greyed)
        realOnly = greyed
        holdsGrey = greyed
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * corner, style: .continuous)
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else if realOnly {
                Color.clear
            } else if let url {
                GeneratedArtwork(seed: url.deletingPathExtension().lastPathComponent, animated: animated)
            } else {
                LinearGradient(colors: surface.backdrop, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(Palette.accent.opacity(0.85))
            }
        }
        .grayscale(shown ? 0 : 1)
        .opacity(shown ? 1 : 0.45)
        .frame(width: size, height: size)
        .background(surface.grid)
        .clipShape(shape)
        .overlay(shape.stroke(surface.stroke, lineWidth: 1))
        .shadow(color: lit ? Palette.accentGlow.opacity(0.45) : .black.opacity(0.35), radius: lit ? size * 0.12 : size * 0.06, y: 2)
        .onAppear {
            guard !shown, !holdsGrey else { return }
            withAnimation(Motion.artworkReveal) { shown = true }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = KnobShiftArtwork.cached(url)
            // Only a cover read just now fades in, so scrolling past cached ones stays instant.
            if image == nil, let loaded = await KnobShiftArtwork.load(url) {
                withAnimation(Motion.artworkReveal) { image = loaded }
            }
        }
        .accessibilityHidden(true)
    }
}
