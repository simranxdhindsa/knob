import SwiftUI

/// ADD MUSIC: a plain button that opens a DropdownCard with songs on this Mac (the Apple logo)
/// and a Spotify playlist (Spotify's mark).
struct KnobShiftAddMusic: View {
    var spotify: Bool
    var onMac: () -> Void
    var onSpotify: () -> Void
    /// Snapshots show the card open.
    var startsOpen = false

    @State private var open = false

    var body: some View {
        Button {
            if spotify { open.toggle() } else { onMac() }
        } label: {
            Label("ADD MUSIC", systemImage: "plus")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Palette.accent)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityHint(spotify ? "Opens a choice of songs on this Mac or a Spotify playlist" : "Adds songs from this Mac")
        .popover(isPresented: $open, arrowEdge: .bottom) { KnobShiftAddMusicCard(onMac: { pick(onMac) }, onSpotify: { pick(onSpotify) }) }
        .onAppear { if startsOpen { open = true } }
    }

    private func pick(_ action: @escaping () -> Void) {
        open = false
        // Lets the popover close before a sheet or the file panel opens.
        DispatchQueue.main.async(execute: action)
    }
}

/// The dropdown card itself, also drawn on its own for snapshots. Always dark, like the
/// KnobShift screen it opens from.
struct KnobShiftAddMusicCard: View {
    var onMac: () -> Void
    var onSpotify: () -> Void

    var body: some View {
        DropdownCard(width: 240) {
            DropdownRow(title: "Songs on your Mac", detail: "Music files from Finder", action: onMac) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            }
            DropdownRow(title: "Spotify playlist", detail: "Playlists, albums or Liked Songs", action: onSpotify) {
                SpotifyMark().frame(width: 16, height: 16)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Spotify's mark, drawn: a green disc with three curved sound lines, widest at the top.
struct SpotifyMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side)), with: .color(Screen.spotify))
            let lines: [(y: CGFloat, half: CGFloat, width: CGFloat)] = [(0.36, 0.30, 0.105), (0.53, 0.25, 0.085), (0.69, 0.20, 0.07)]
            let centre = side / 2
            for line in lines {
                var path = Path()
                path.move(to: CGPoint(x: centre - side * line.half, y: side * line.y))
                path.addQuadCurve(to: CGPoint(x: centre + side * line.half, y: side * (line.y + 0.03)),
                                  control: CGPoint(x: centre, y: side * (line.y - 0.09)))
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: side * line.width, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
