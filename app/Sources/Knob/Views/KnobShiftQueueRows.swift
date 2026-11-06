import SwiftUI

/// What the queue's rows share: how a row looks when it is playing, selected or already played,
/// and the size of a tap target. Rows hold no state: the list passes in everything, including
/// which row the pointer is on, so a long queue carries one hover state and no animation per row.
enum QueueRowStyle {
    #if os(iOS)
    static let tap: CGFloat = 44
    #else
    static let tap: CGFloat = 24
    #endif

    /// Selected is a neutral lift with an outline and a tick on the cover; playing is the orange
    /// text, a faint orange wash and a bar on the left. A row can be both.
    @ViewBuilder
    static func background(playing: Bool, selected: Bool, landing: Bool = false, surface: Surface) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(selected ? surface.text.opacity(0.14) : (playing ? Palette.accent.opacity(0.10) : .clear))
            .overlay(shape.stroke(selected ? surface.text.opacity(0.45) : .clear, lineWidth: 1))
            .overlay(shape.stroke(Palette.accent.opacity(landing ? 0.9 : 0), lineWidth: 1.5)
                .shadow(color: Palette.accentGlow.opacity(landing ? 0.8 : 0), radius: 7))
            .overlay(alignment: .leading) {
                if playing {
                    Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 8).padding(.leading, 2)
                        .shadow(color: Palette.accentGlow.opacity(0.6), radius: 3)
                }
            }
    }
}

/// The small circle on a selected row's cover.
struct QueueSelectedTick: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(Glass.onAccent, Palette.accent)
            .accessibilityHidden(true)
    }
}

/// The X that takes a song out. Always laid out so rows never shift, shown only on the Mac on the
/// hovered or selected row; the iPhone swipes instead and VoiceOver uses the row's Remove action.
struct QueueRemoveButton: View {
    let visible: Bool
    let action: () -> Void
    @Environment(\.surface) private var surface

    var body: some View {
        #if os(macOS)
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .frame(width: QueueRowStyle.tap, height: QueueRowStyle.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(surface.secondary)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(true)
        .help("Take this song out of the queue")
        #endif
    }
}

/// How the mix into a song will feel, beside its length: faint when smooth, orange when the tempo
/// has to stretch, bright orange for a big jump, so a long list stays quiet until something stands out.
struct QueueJumpMark: View {
    private static let size: CGFloat = 6

    let jump: KnobShiftMixJump
    @Environment(\.surface) private var surface

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Self.size, height: Self.size)
            .shadow(color: jump == .big ? Palette.accentGlow.opacity(0.7) : .clear, radius: 3)
            .help(jump.title)
            .accessibilityLabel(jump.title)
    }

    private var color: Color {
        switch jump {
        case .smooth: surface.tertiary.opacity(0.5)
        case .stretch: Palette.accent.opacity(0.5)
        case .big: Palette.accent
        case .unknown: .clear
        }
    }
}

/// One ready song. The song name on top; the second line holds the artist, where it is from and
/// its tempo.
struct QueueTrackRow: View {
    let track: KnobShiftModel.Track
    let playing: Bool
    let selected: Bool
    /// Before the playing song in the order on screen.
    let played: Bool
    let hovered: Bool
    let reveal: Bool
    /// The list has just come to this row.
    var landing = false
    /// How the mix into this song will feel, for songs still to come.
    let jump: KnobShiftMixJump?
    let voiceNote: String?
    let offersRetry: Bool
    let onRetry: () -> Void
    let onPlayNext: () -> Void
    let onRemove: () -> Void
    @Environment(\.surface) private var surface

    var body: some View {
        let parts = SongTitle.parts(name: track.name, artist: track.artist)
        HStack(spacing: 10) {
            AlbumArtwork(url: track.url, size: 34, lit: playing, reveal: reveal)
                .overlay(alignment: .topLeading) { if selected { QueueSelectedTick().offset(x: -4, y: -4) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.name).font(.system(size: 12, weight: playing ? .bold : .medium))
                    .foregroundStyle(playing ? Palette.accent : surface.text).lineLimit(1)
                Text(voiceNote ?? Self.detail(parts: parts, track: track))
                    .font(.system(size: 10)).foregroundStyle(surface.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if offersRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: QueueRowStyle.tap)
                    .accessibilityLabel("Read the voice of \(parts.name) again")
            }
            if let jump, jump != .unknown { QueueJumpMark(jump: jump) }
            Text(KnobShiftNowPlaying.clock(track.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(surface.tertiary)
            QueueRemoveButton(visible: hovered || selected, action: onRemove)
        }
        .opacity(played && !playing ? 0.5 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(QueueRowStyle.background(playing: playing, selected: selected, landing: landing, surface: surface))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(playing ? "Playing" : (played ? "Played" : ""))
        .accessibilityAction(named: "Play next", onPlayNext)
        .accessibilityAction(named: "Remove from queue", onRemove)
    }

    /// The second line: artist, where the song is from, tempo. Tempo marks and other extras join here.
    private static func detail(parts: (name: String, source: String?, artist: String?), track: KnobShiftModel.Track) -> String {
        [parts.artist, parts.source, track.analysis.tempo.map { String(format: "%.0f BPM", $0) }]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }
}

/// A song still being prepared: its ring fills as the analysis moves on; a failed song offers Retry.
struct QueuePendingRow: View {
    let song: KnobShiftModel.PendingSong
    let selected: Bool
    let hovered: Bool
    let onRetry: () -> Void
    let onRemove: () -> Void
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(surface.grid)
                if !song.waitingForDownload, song.failure == nil { AlbumArtwork(url: song.url, size: 34, greyed: true) }
                if song.failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(Palette.accent)
                } else {
                    PreparingRing(progress: song.progress, active: song.isActive || song.stage == "Downloading")
                }
            }
            .frame(width: 34, height: 34)
            .overlay(alignment: .topLeading) { if selected { QueueSelectedTick().offset(x: -4, y: -4) } }
            VStack(alignment: .leading, spacing: 2) {
                let parts = SongTitle.parts(name: song.name, artist: song.artist)
                Text(parts.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(song.failure == nil ? surface.secondary : surface.text).lineLimit(1)
                Text([parts.artist, parts.source, song.failure ?? song.stage ?? (song.isActive ? "Preparing \(Int(song.progress * 100))%" : "Waiting to prepare")]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(song.failure == nil ? surface.tertiary : Palette.accent).lineLimit(1)
            }
            Spacer(minLength: 4)
            if song.failure != nil {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: QueueRowStyle.tap)
            }
            QueueRemoveButton(visible: hovered || selected, action: onRemove)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(QueueRowStyle.background(playing: false, selected: selected, surface: surface))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Remove from queue", onRemove)
        .accessibilityAction(named: "Retry") { if song.failure != nil { onRetry() } }
    }
}

/// A small progress ring for a song being prepared: a faint track, the filled share in orange,
/// and nothing filled while the song waits its turn.
struct PreparingRing: View {
    @Environment(\.surface) private var surface
    let progress: Double
    let active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(surface.tertiary.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: active ? max(0.04, min(progress, 1)) : 0)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.accentGlow.opacity(0.6), radius: 2)
        }
        .frame(width: 18, height: 18)
        .animation(Motion.gentle, value: progress)
        .accessibilityLabel(active ? "Preparing, \(Int(progress * 100)) percent" : "Waiting to prepare")
    }
}
