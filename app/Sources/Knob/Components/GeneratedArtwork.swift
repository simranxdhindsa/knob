import SwiftUI

/// A cover for songs whose files carry none: a gradient, two soft light circles and a dark wave,
/// in the style of the README's player animation. Each song's name picks its own colours and
/// layout, so a song always gets the same cover and neighbours look different. While `animated`
/// the shapes drift slowly; queue rows keep it still, and Reduce Motion stops it everywhere.
struct GeneratedArtwork: View {
    let seed: String
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        let look = Look(seed: seed)
        GeometryReader { box in
            let side = box.size.width
            let drift = drifting ? 1.0 : 0.0
            ZStack {
                LinearGradient(colors: look.colors, startPoint: look.start, endPoint: look.end)
                Circle()
                    .fill(look.isLight ? ArtworkPalette.light.opacity(0.55) : ArtworkPalette.light.opacity(0.17))
                    .frame(width: side * look.big.size)
                    .scaleEffect(1 + 0.08 * drift)
                    .position(x: side * (look.big.x + 0.05 * drift), y: side * (look.big.y - 0.04 * drift))
                Circle()
                    .fill(ArtworkPalette.shade.opacity(look.isLight ? 0.10 : 0.22))
                    .frame(width: side * look.small.size)
                    .position(x: side * (look.small.x - 0.04 * drift), y: side * (look.small.y + 0.03 * drift))
                if look.hasWave {
                    Wave(height: look.waveHeight, swell: look.swell)
                        .fill(look.isLight ? look.colors[2].opacity(0.45) : ArtworkPalette.shade.opacity(0.28))
                        .frame(width: side * 1.2, height: side)
                        .offset(x: side * 0.06 * (drift - 0.5))
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(animated && !reduceMotion ? Motion.artworkDrift : .easeOut(duration: 0.6), value: drifting)
        .onAppear { drifting = animated && !reduceMotion }
        .onChange(of: animated) { _, on in drifting = on && !reduceMotion }
    }

    /// Everything that differs between songs, worked out once from the name.
    private struct Look {
        struct Blob { let x: Double; let y: Double; let size: Double }
        let colors: [Color]
        let isLight: Bool
        let start: UnitPoint
        let end: UnitPoint
        let big: Blob
        let small: Blob
        let hasWave: Bool
        let waveHeight: Double
        let swell: Double

        init(seed: String) {
            // FNV-1a: the same name gives the same cover on every launch (Swift's own hash
            // changes between launches).
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            // Mixed once more (splitmix), so similar names still land on different colours.
            hash ^= hash >> 30; hash &*= 0xbf58476d1ce4e5b9
            hash ^= hash >> 27; hash &*= 0x94d049bb133111eb
            hash ^= hash >> 31
            var state = hash
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(UInt64(1) << 53)
            }
            let family = ArtworkPalette.family(hue: next(), shift: next(), light: next() > 0.5)
            colors = family.colors
            isLight = family.isLight
            let angle = next() * 2 * .pi
            start = UnitPoint(x: 0.5 - cos(angle) * 0.5, y: 0.5 - sin(angle) * 0.5)
            end = UnitPoint(x: 0.5 + cos(angle) * 0.5, y: 0.5 + sin(angle) * 0.5)
            big = Blob(x: 0.25 + next() * 0.3, y: 0.25 + next() * 0.3, size: 0.55 + next() * 0.25)
            small = Blob(x: 0.6 + next() * 0.25, y: 0.6 + next() * 0.25, size: 0.3 + next() * 0.2)
            hasWave = next() > 0.4
            waveHeight = 0.18 + next() * 0.14
            swell = 0.05 + next() * 0.07
        }
    }

    /// A soft wave across the bottom of the cover.
    private struct Wave: Shape {
        let height: Double
        let swell: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let top = rect.maxY - rect.height * height
            path.move(to: CGPoint(x: rect.minX, y: top))
            path.addCurve(to: CGPoint(x: rect.maxX, y: top - rect.height * swell * 0.5),
                          control1: CGPoint(x: rect.minX + rect.width * 0.3, y: top - rect.height * swell),
                          control2: CGPoint(x: rect.minX + rect.width * 0.6, y: top + rect.height * swell))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
