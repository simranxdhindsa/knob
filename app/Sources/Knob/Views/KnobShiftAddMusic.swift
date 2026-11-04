import SwiftUI

/// ADD MUSIC: a plain button that opens a DropdownCard with songs on this Mac (the Apple logo),
/// a Spotify playlist (Spotify's mark) and YouTube (YouTube's mark), each where available.
struct KnobShiftAddMusic: View {
    var spotify: Bool
    var youtube: Bool = false
    var onMac: () -> Void
    var onSpotify: () -> Void
    var onYouTube: () -> Void = {}
    /// Sync from your Mac (the iPhone app).
    var sync: Bool = false
    var onSync: () -> Void = {}
    /// Snapshots show the card open.
    var startsOpen = false

    @State private var open = false

    private var hasChoices: Bool { spotify || youtube || sync }

    private var label: some View {
        Label("ADD MUSIC", systemImage: "plus")
            .font(.system(size: 9, weight: .bold)).tracking(0.6)
            .foregroundStyle(Palette.accent)
            .frame(height: 20)
            .contentShape(Rectangle())
    }

    #if os(iOS)
    /// The iPhone's own menu: a popover near the top of the screen had no room and cut off its rows.
    var body: some View {
        Menu {
            Button(action: onMac) { Label("Songs on your iPhone", systemImage: "folder") }
            if spotify { Button(action: onSpotify) { Label("Spotify playlist", systemImage: "link") } }
            if youtube { Button(action: onYouTube) { Label("YouTube", systemImage: "play.rectangle") } }
            if sync { Button(action: onSync) { Label("Sync from your Mac", systemImage: "laptopcomputer.and.iphone") } }
        } label: {
            label
        }
    }
    #else
    var body: some View {
        Button {
            if hasChoices { open.toggle() } else { onMac() }
        } label: {
            label
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityHint(hasChoices ? "Opens a choice of songs on this Mac, Spotify or YouTube" : "Adds songs from this Mac")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            KnobShiftAddMusicCard(spotify: spotify, youtube: youtube, sync: sync,
                                  onMac: { pick(onMac) }, onSpotify: { pick(onSpotify) }, onYouTube: { pick(onYouTube) },
                                  onSync: { pick(onSync) })
        }
        .onAppear { if startsOpen { open = true } }
    }

    private func pick(_ action: @escaping () -> Void) {
        open = false
        // Lets the popover close before a sheet or the file panel opens.
        DispatchQueue.main.async(execute: action)
    }
    #endif
}

/// The dropdown card itself, also drawn on its own for snapshots. Always dark, like the
/// KnobShift screen it opens from.
struct KnobShiftAddMusicCard: View {
    @Environment(\.surface) private var surface
    @Environment(\.colorScheme) private var scheme
    var spotify = true
    var youtube = true
    var sync = false
    var onMac: () -> Void
    var onSpotify: () -> Void
    var onYouTube: () -> Void = {}
    var onSync: () -> Void = {}

    var body: some View {
        DropdownCard(width: 240) {
            #if os(macOS)
            DropdownRow(title: "Songs on your Mac", detail: "Music files from Finder", action: onMac) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            }
            #else
            DropdownRow(title: "Songs on your iPhone", detail: "Music files from Files", action: onMac) {
                Image(systemName: "iphone").font(.system(size: 14, weight: .medium))
            }
            #endif
            if spotify {
                DropdownRow(title: "Spotify playlist", detail: "Playlists, albums or Liked Songs", action: onSpotify) {
                    SpotifyMark().frame(width: 16, height: 16)
                }
            }
            if youtube {
                DropdownRow(title: "YouTube", detail: "Videos, playlists or albums", action: onYouTube) {
                    YouTubeMark().frame(width: 18, height: 18)
                }
            }
            if sync {
                DropdownRow(title: "Sync from your Mac", detail: "Playlists Knob on your Mac has", action: onSync) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 13, weight: .medium))
                }
            }
        }
        .environment(\.colorScheme, surface.scheme(scheme))
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

/// YouTube's mark, drawn: a red rounded rectangle with a white play triangle in the middle.
struct YouTubeMark: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = width * 0.7
            let top = (size.height - height) / 2
            let shape = CGRect(x: 0, y: top, width: width, height: height)
            context.fill(Path(roundedRect: shape, cornerRadius: height * 0.28, style: .continuous), with: .color(Screen.youtube))
            var play = Path()
            play.move(to: CGPoint(x: width * 0.40, y: top + height * 0.28))
            play.addLine(to: CGPoint(x: width * 0.66, y: top + height * 0.5))
            play.addLine(to: CGPoint(x: width * 0.40, y: top + height * 0.72))
            play.closeSubpath()
            context.fill(play, with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}
