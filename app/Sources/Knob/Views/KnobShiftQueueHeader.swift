import SwiftUI

/// The queue card's top row: the title, the Playlists switch, sorting, Mix Order, shuffle, the
/// bin and ADD MUSIC.
struct KnobShiftQueueHeader: View {
    @ObservedObject var model: KnobShiftModel
    @Binding var showingPlaylists: Bool
    @Binding var confirmingRemoveAll: Bool
    var onAdd: () -> Void
    var onSpotify: () -> Void
    var onYouTube: () -> Void
    var onSync: () -> Void
    @Environment(\.surface) private var surface

    private var hasSongs: Bool { !model.tracks.isEmpty || !model.queuePending.isEmpty }

    var body: some View {
        HStack {
            Text(showingPlaylists ? "PLAYLISTS" : "QUEUE").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(surface.tertiary)
            if showingPlaylists, !model.playlists.isEmpty {
                Text("\(model.playlists.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(surface.tertiary)
            }
            Spacer()
            playlistsButton
            // Shuffle and the bin are for the queue, so they step aside for Playlists.
            if !showingPlaylists {
                sortMenu
                mixOrderButton
                shuffleButton
                if hasSongs {
                    Button { confirmingRemoveAll = true } label: {
                        Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(surface.tertiary).frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Remove every song from the queue")
                    .accessibilityLabel("Remove all songs")
                    .padding(.trailing, 2)
                }
            }
            addMusic
        }
    }

    private var shuffleButton: some View {
        orderToggle("shuffle", on: model.isShuffled, action: model.toggleShuffle)
            .help(model.isShuffled ? "Shuffle is on. Click to go back to your order." : "Shuffle the queue")
            .accessibilityLabel(model.isShuffled ? "Shuffle on" : "Shuffle off")
    }

    /// Mix Order arranges what is left so neighbours mix well. It and shuffle replace each other.
    private var mixOrderButton: some View {
        orderToggle("waveform", on: model.isMixOrdered, action: model.toggleMixOrder)
            .help(model.isMixOrdered ? "Mix Order is on. Click to go back to your order." : "Arrange the songs so they mix well")
            .accessibilityLabel(model.isMixOrdered ? "Mix Order on" : "Mix Order off")
    }

    /// A button that holds the queue in another order, lit while it does.
    private func orderToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(on ? Palette.accent : surface.tertiary)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(on ? Palette.accent.opacity(0.14) : .clear))
                .shadow(color: on ? Palette.accentGlow.opacity(0.5) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        // Once on it can always be turned off, even after removing all but one song.
        .disabled(model.tracks.count < 2 && !on)
        .padding(.trailing, 2)
    }

    /// Sorting replaces the user's order, so the menu keeps the way back until they make a new one.
    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(KnobShiftQueueSort.allCases, id: \.self) { sort in
                    Button { model.sortQueue(by: sort) } label: { Label(sort.title, systemImage: sort.symbol) }
                }
            }
            if model.orderBeforeSort != nil {
                Button(action: model.restoreOrderBeforeSort) { Label("Back to your order", systemImage: "arrow.uturn.backward") }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.orderBeforeSort != nil ? Palette.accent : surface.tertiary)
                .frame(width: 22, height: 20)
        }
        .labelStyle(.titleAndIcon)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.tracks.count < 2)
        .help("Sort the queue")
        .accessibilityLabel("Sort the queue")
        .padding(.trailing, 2)
    }

    /// Switches between the queue and the Playlists view, where imported and synced songs wait
    /// to be added. Lit while playlists show, and on the Mac while one is downloading.
    private var playlistsButton: some View {
        #if os(macOS)
        let downloading = !model.spotifyProgress.isEmpty
        #else
        let downloading = false
        #endif
        return Button {
            withAnimation(Motion.gentle) { showingPlaylists.toggle() }
        } label: {
            Image(systemName: "music.note.list")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(showingPlaylists || downloading ? Palette.accent : surface.tertiary)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(showingPlaylists ? Palette.accent.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .help(showingPlaylists ? "Back to the queue" : "Playlists")
        .accessibilityLabel(showingPlaylists ? "Back to the queue" : "Playlists")
        .padding(.trailing, 2)
    }

    /// ADD MUSIC: songs on this Mac, or, where Spotify import is available, a dropdown with both
    /// (KnobShiftAddMusic). The header looks the same either way, so it never changes size.
    private var addMusic: some View {
        #if os(macOS)
        KnobShiftAddMusic(spotify: model.spotifyAvailable, youtube: model.youtubeAvailable, onMac: onAdd, onSpotify: onSpotify, onYouTube: onYouTube)
        #else
        KnobShiftAddMusic(spotify: true, youtube: true, onMac: onAdd, onSpotify: onSpotify, onYouTube: onYouTube, sync: true, onSync: onSync)
        #endif
    }
}

/// "95 songs, 5 hr 12 min left" and, where there is room, "Ends at 3:40 AM". The time left is the
/// rest of the playing song plus every song after it. It reads the playback time without watching
/// it, and a minute timer refreshes it, so the rows never redraw with the clock.
struct QueueSummaryLine: View {
    @ObservedObject var model: KnobShiftModel
    /// Songs on screen while a search is filtering, or nil.
    var filteredCount: Int?
    @Environment(\.surface) private var surface

    var body: some View {
        let total = model.tracks.count + model.queuePending.count
        let preparing = model.queuePending.count
        TimelineView(.everyMinute) { context in
            let left = QueueTiming.remaining(
                durations: model.tracks.map(\.duration),
                playingIndex: model.nowPlaying.flatMap { playing in model.tracks.firstIndex { $0.id == playing.id } },
                position: model.playbackTime)
            let lead = filteredCount.map { "\($0) of \(total) songs" }
                ?? "\(total) \(total == 1 ? "song" : "songs"), \(QueueTiming.leftText(left))"
            let tail = preparing > 0 && filteredCount == nil ? ", \(preparing) preparing" : ""
            let ends = filteredCount == nil && model.isPlaying ? QueueTiming.endsText(from: context.date, remaining: left) : nil
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(lead + tail).fixedSize()
                    Spacer(minLength: 4)
                    if let ends { Text(ends).fixedSize() }
                }
                Text(lead + tail)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(surface.tertiary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Replaces the summary while songs are selected: says what is selected, lets it go, and removes it.
struct QueueSelectionBar: View {
    /// The selected song's name when exactly one is selected.
    let name: String?
    let count: Int
    let onClear: () -> Void
    let onRemove: () -> Void
    @Environment(\.surface) private var surface

    private var removeText: String {
        guard let name else { return "REMOVE \(count)" }
        return "REMOVE " + (name.count > 18 ? String(name.prefix(17)) + "…" : name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClear) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    Text(count == 1 ? "Selected" : "\(count) selected").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(surface.secondary)
                .frame(minHeight: QueueRowStyle.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Let go of the selection. Escape does the same.")
            .accessibilityLabel("Clear selection")
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Text(removeText).font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Palette.accent).lineLimit(1)
                    .frame(minHeight: QueueRowStyle.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Take the selected songs out of the queue. Delete does the same.")
            .accessibilityLabel(count == 1 ? "Remove \(name ?? "song")" : "Remove \(count) songs")
        }
    }
}

/// Brings the playing song back into view when it has scrolled away.
struct QueueJumpButton: View {
    /// How far the arrow shoots when pressed.
    private static let shot: CGFloat = 9

    /// Which way the playing song is: true when it is above what is on screen.
    let above: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The arrow is on its way, the moment after a press.
    @State private var shooting = false

    var body: some View {
        Button {
            action()
            shoot()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: above ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
                    .offset(y: shooting ? (above ? -Self.shot : Self.shot) : 0)
                    .opacity(shooting ? 0 : 1)
                Text("PLAYING").font(.system(size: 9, weight: .bold)).tracking(0.6)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 12)
            .frame(height: QueueRowStyle.tap > 30 ? QueueRowStyle.tap : 26)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
            .shadow(color: Palette.accentGlow.opacity(0.35), radius: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(QueueJumpPress())
        .help("Scroll to the song that is playing")
        .accessibilityLabel("Show the playing song")
    }

    /// The arrow leaves the way the list is about to move, then is back in place.
    private func shoot() {
        guard !reduceMotion else { return }
        withAnimation(Motion.queueJumpArrow) { shooting = true }
        Task {
            try? await Task.sleep(for: .seconds(Motion.queueJumpSeconds))
            shooting = false
        }
    }
}

/// The jump button dipping under a press.
private struct QueueJumpPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
