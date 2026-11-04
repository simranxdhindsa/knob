import SwiftUI

/// The Playlists view, in the queue's place from the queue's playlists button: every Spotify and
/// YouTube playlist, and once one is opened its songs, with Play all, Add all and a plus on each
/// song. Imports and syncs fill playlists rather than the queue, so this is where their songs are
/// picked. On the Mac the list is the playlist rows with Update, Retry and Remove
/// (KnobShiftPlaylistRows); the iPhone, which gets its songs by syncing, lists them plainly.
struct KnobShiftPlaylistsView: View {
    @ObservedObject var model: KnobShiftModel
    var onSpotify: () -> Void = {}
    var onYouTube: () -> Void = {}
    @State private var openId: String?
    @Environment(\.surface) private var surface

    var body: some View {
        Group {
            if let playlist = model.playlists.first(where: { $0.id == openId }) {
                KnobShiftPlaylistDetail(model: model, playlist: playlist) {
                    withAnimation(Motion.gentle) { openId = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if model.playlists.isEmpty && model.removedPlaylists.isEmpty {
                Text(Self.emptyHint)
                    .font(.system(size: 11)).foregroundStyle(surface.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
            } else {
                list.transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var list: some View {
        #if os(macOS)
        KnobShiftPlaylistRows(model: model, onSpotify: onSpotify, onYouTube: onYouTube, fills: true, onOpen: open)
        #else
        ScrollView {
            VStack(spacing: 6) {
                ForEach(model.playlists) { playlist in phoneRow(playlist) }
            }
        }
        .scrollIndicators(.never)
        #endif
    }

    private func open(_ playlist: KnobShiftPlaylist) {
        Haptics.tick()
        withAnimation(Motion.gentle) { openId = playlist.id }
    }

    #if os(iOS)
    private func phoneRow(_ playlist: KnobShiftPlaylist) -> some View {
        let count = model.playlistCount(playlist)
        return Button { open(playlist) } label: {
            HStack(spacing: 12) {
                Image(systemName: KnobShiftPlaylistDetail.icon(playlist.kind))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KnobShiftPlaylistDetail.title(playlist)).font(.system(size: 15, weight: .semibold)).foregroundStyle(surface.text).lineLimit(1)
                    Text("\(count.ready) of \(count.total) ready from \(playlist.source == .youtube ? "YouTube" : "Spotify")")
                        .font(.system(size: 12)).foregroundStyle(surface.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(surface.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(KnobShiftPlaylistDetail.title(playlist)), \(count.ready) of \(count.total) songs ready")
    }
    #endif

    #if os(macOS)
    private static let emptyHint = "No playlists yet. Add a Spotify or YouTube playlist from ADD MUSIC, and its songs wait here until you add them."
    #else
    private static let emptyHint = "No playlists yet. Sync from your Mac, and its playlists wait here until you add their songs."
    #endif
}

/// One playlist's songs, in its own order: Play all, Add all to the queue, and a plus on each
/// song that is here; songs still on their way show where they are, and ones that could not be
/// downloaded say why. Tapping a song adds it; its menu also plays it now.
struct KnobShiftPlaylistDetail: View {
    @ObservedObject var model: KnobShiftModel
    let playlist: KnobShiftPlaylist
    var onBack: () -> Void
    @Environment(\.surface) private var surface

    #if os(iOS)
    private static let rowHeight: CGFloat = 48, nameSize: CGFloat = 14, detailSize: CGFloat = 11.5
    #else
    private static let rowHeight: CGFloat = 36, nameSize: CGFloat = 12, detailSize: CGFloat = 10
    #endif

    var body: some View {
        let songs = model.playlistSongs(playlist)
        let ready = songs.filter { $0.url != nil }
        let fresh = ready.filter { !model.isQueued($0.url!) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(surface.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All playlists")
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(playlist)).font(.system(size: Self.nameSize + 1, weight: .semibold)).foregroundStyle(surface.text).lineLimit(1)
                    Text("\(ready.count) of \(songs.count) songs ready").font(.system(size: Self.detailSize)).foregroundStyle(surface.tertiary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                action("PLAY ALL", symbol: "play.fill", filled: true) { Task { await model.play(ready) } }
                    .disabled(ready.isEmpty)
                action(fresh.isEmpty ? "ALL IN QUEUE" : "ADD \(fresh.count) TO QUEUE", symbol: fresh.isEmpty ? "checkmark" : "plus", filled: false) {
                    Task { await model.addToQueue(fresh) }
                }
                .disabled(fresh.isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        row(song, number: index + 1)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func action(_ title: String, symbol: String, filled: Bool, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.mark()
            perform()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6)
            }
            .foregroundStyle(filled ? Glass.onAccent : Palette.accent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(filled ? Palette.accent : Palette.accent.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ song: KnobShiftPlaylistSong, number: Int) -> some View {
        let queued = song.url.map(model.isQueued) ?? false
        return HStack(spacing: 10) {
            Text("\(number)").font(.system(size: Self.detailSize, weight: .medium).monospacedDigit())
                .foregroundStyle(surface.tertiary).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.name).font(.system(size: Self.nameSize, weight: .semibold))
                    .foregroundStyle(song.url == nil ? surface.secondary : surface.text).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.system(size: Self.detailSize)).foregroundStyle(surface.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing(song, queued: queued)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard song.url != nil, !queued else { return }
            Haptics.tick()
            Task { await model.addToQueue([song]) }
        }
        .contextMenu {
            if song.url != nil {
                Button { Task { await model.play([song]) } } label: { Label("Play Now", systemImage: "play.fill") }
                if !queued {
                    Button { Task { await model.addToQueue([song]) } } label: { Label("Add to Queue", systemImage: "plus") }
                }
            }
        }
    }

    @ViewBuilder private func trailing(_ song: KnobShiftPlaylistSong, queued: Bool) -> some View {
        switch song.state {
        case .ready:
            Image(systemName: queued ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(queued ? surface.tertiary : Palette.accent)
                .frame(width: 28, height: 28)
                .accessibilityLabel(queued ? "In the queue" : "Add to queue")
        case .waiting(let stage):
            Text(stage).font(.system(size: Self.detailSize - 0.5)).foregroundStyle(surface.tertiary).lineLimit(1)
        case .failed(let reason):
            HStack(spacing: 8) {
                Text(reason).font(.system(size: Self.detailSize - 0.5)).foregroundStyle(Palette.accent).lineLimit(1)
                if let row = model.pending.first(where: { $0.playlistId == playlist.id && $0.spotifyId == song.id }) {
                    Button("RETRY") { model.retry(row) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
                }
            }
        }
    }

    /// Spotify names sometimes carry spaces around them.
    static func title(_ playlist: KnobShiftPlaylist) -> String { playlist.name.trimmingCharacters(in: .whitespaces) }

    static func icon(_ kind: KnobShiftPlaylist.Kind) -> String {
        switch kind {
        case .liked: return "heart.fill"
        case .song: return "music.note"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        }
    }
}
