import CoreGraphics
import SwiftUI

/// The player's background: the cover and its reflection shrunk to a few pixels and blurred, so a
/// soft wash of its colours fills the screen, and costs almost nothing to draw. Dark mode fades it
/// towards black. Light mode lifts the cover's own colours into a light range (`pastel`), because
/// white laid over a cover greys a dark one and bleaches a bright one. It fades from song to song.
/// The iPhone player and the Mac's KnobShift window share it.
struct PlayerAmbient: View {
    let url: URL?
    @State private var wash: CGImage?
    /// The last song's wash, kept underneath so the next fades in over it with no dark dip.
    @State private var previous: CGImage?
    @State private var shown = 0.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        ZStack {
            LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)
            if let previous { blurred(previous) }
            if let wash { blurred(wash).opacity(shown) }
            if scheme == .dark { Glass.scrim }
        }
        .task(id: "\(url?.path ?? "")\(scheme)") {
            guard let url, let image = await KnobShiftArtwork.load(url).flatMap(Self.cgImage),
                  let reflected = Self.reflected(image) else {
                previous = nil
                wash = nil
                return
            }
            previous = wash
            shown = 0
            wash = scheme == .dark ? reflected : Self.pastel(reflected)
            // A frame at nothing first, so the fade has somewhere to start from.
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(Motion.ambient) { shown = 1 }
        }
        .accessibilityHidden(true)
    }

    private func blurred(_ image: CGImage) -> some View {
        Color.clear
            .overlay {
                // Stretched, not cropped: a wide window would otherwise show only a thin slice
                // where the cover meets its reflection, and that slice's colours would be all of it.
                Image(decorative: image, scale: 1).resizable()
                    .blur(radius: scheme == .dark ? 40 : 90).saturation(scheme == .dark ? 1.5 : 1)
                    .scaleEffect(scheme == .dark ? 1.3 : 1.7)
            }
            .clipped()
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        image.cgImage
        #endif
    }

    /// The whole cover at 40 pixels with its reflection under it, so its strongest colours reach
    /// the bottom too.
    private static func reflected(_ image: CGImage) -> CGImage? {
        let side = 40
        guard let context = CGContext(data: nil, width: side, height: side * 2, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        // Core Graphics counts up from the bottom: the cover goes in the top half, its mirror below.
        context.draw(image, in: CGRect(x: 0, y: side, width: side, height: side))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// The cover's own colours lifted into a light range, so text stays readable: its dark and
    /// bright areas stay apart and a grey poster stays grey. Colour is taken as the distance from
    /// grey, not as a share of brightness, or the faint tint in near black parts would become the
    /// whole wash (a black and white poster came out pink).
    private static func pastel(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for pixel in stride(from: 0, to: width * height * 4, by: 4) {
            let red = Double(data[pixel]) / 255, green = Double(data[pixel + 1]) / 255, blue = Double(data[pixel + 2]) / 255
            let grey = 0.3 * red + 0.59 * green + 0.11 * blue
            let lifted = 0.66 + 0.32 * grey
            for (channel, value) in [red, green, blue].enumerated() {
                data[pixel + channel] = UInt8(min(max(lifted + (value - grey) * 1.1, 0), 1) * 255)
            }
        }
        return context.makeImage() ?? image
    }
}
