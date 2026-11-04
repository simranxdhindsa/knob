import CoreGraphics
import SwiftUI

/// The player's background: the cover and its reflection shrunk to a few pixels and blurred, so a
/// soft wash of its colours fills the screen, and costs almost nothing to draw. Dark mode fades it
/// towards black. Light mode turns it into bright pastels of the same colours (`pastel`), because
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
                Image(decorative: image, scale: 1).resizable().scaledToFill()
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

    /// Every pixel keeps its hue at one bright level and a capped strength, so text stays readable.
    /// Near black has no real colour of its own, so it fades to white instead of a random hue.
    private static func pastel(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for pixel in stride(from: 0, to: width * height * 4, by: 4) {
            let (hue, saturation, brightness) = hsb(Double(data[pixel]) / 255, Double(data[pixel + 1]) / 255, Double(data[pixel + 2]) / 255)
            let strength = min(saturation * 1.5, 0.5) * min(brightness / 0.2, 1)
            let (red, green, blue) = rgb(hue, strength, 0.96)
            data[pixel] = UInt8(red * 255)
            data[pixel + 1] = UInt8(green * 255)
            data[pixel + 2] = UInt8(blue * 255)
        }
        return context.makeImage() ?? image
    }

    /// Hue (0...1), saturation and brightness of a colour, as UIColor and NSColor give them.
    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        guard high > 0, range > 0 else { return (0, 0, high) }
        var hue: Double
        if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, range / high, high)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> (Double, Double, Double) {
        let sector = hue * 6, step = Int(sector) % 6, f = sector - Double(Int(sector))
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f), t = brightness * (1 - saturation * (1 - f))
        switch step {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
