import SwiftUI

/// The Spotify playlists in the queue, each a slim row with its name, how many songs are ready,
/// Update and remove, and below them the playlists removed in the last 30 days with Restore.
/// Every row has a fixed height, so the queue never jumps while songs download. Removing and
/// deleting for good both ask first.
struct KnobShiftPlaylistRows: View {
    @ObservedObject var model: KnobShiftModel
    @State private var confirmRemove: KnobShiftPlaylist?
    @State private var confirmDelete: KnobShiftRemovedPlaylist?
    @State private var showRemoved = false

    var body: some View {
        if !model.playlists.isEmpty || !model.removedPlaylists.isEmpty {
            // Up to three rows show in full; more scroll inside the same height, so the queue
            // below keeps its room.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.playlists) { playlist in row(playlist) }
                    if !model.removedPlaylists.isEmpty { removedSection }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: model.playlists.count + (showRemoved ? model.removedPlaylists.count : 0) > 3 ? 150 : nil)
            .fixedSize(horizontal: false, vertical: model.playlists.count + (showRemoved ? model.removedPlaylists.count : 0) <= 3)
            .confirmationDialog("Remove \(confirmRemove?.name ?? "this playlist")?", isPresented: Binding(
                get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let playlist = confirmRemove { model.removePlaylist(playlist) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its songs leave the queue. You can restore it for 30 days.")
            }
            .confirmationDialog("Delete \(confirmDelete?.playlist.name ?? "this playlist") for good?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let removed = confirmDelete { model.deleteRemovedPlaylist(removed) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its downloaded songs are deleted from your Mac.")
            }
        }
    }

    private func row(_ playlist: KnobShiftPlaylist) -> some View {
        let count = model.songCount(in: playlist)
        let progress = model.spotifyProgress[playlist.id]
        let failed = progress == nil ? model.failedCount(in: playlist) : 0
        return HStack(spacing: 10) {
            Image(systemName: icon(playlist.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                if let progress {
                    KnobShiftImportBar(progress: progress, compact: true)
                } else {
                    Text(failed > 0 ? "\(count.ready) of \(count.total) ready, \(failed) not downloaded" : "\(count.total) song\(count.total == 1 ? "" : "s") from Spotify")
                        .font(.system(size: 9.5)).foregroundStyle(Screen.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if progress != nil {
                Button { model.cancelDownload(playlist) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(Screen.textSecondary)
                .help("Stop downloading")
                .accessibilityLabel("Stop downloading \(playlist.name)")
            } else {
                if failed > 0 {
                    Button("RETRY") { model.retryFailed(playlist) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
                        .help("Try the songs that did not download again")
                        .accessibilityLabel("Retry \(failed) songs of \(playlist.name)")
                }
                Button { Task { await model.updatePlaylist(playlist) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(Screen.textSecondary)
                .disabled(model.spotifyReadJob != nil)
                .help("Update from Spotify and pick songs")
                .accessibilityLabel("Update \(playlist.name) from Spotify")
            }
            Button { confirmRemove = playlist } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(Screen.textTertiary)
            .accessibilityLabel("Remove \(playlist.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Screen.tabTrack))
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(Motion.gentle) { showRemoved.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showRemoved ? 90 : 0))
                    Text("RECENTLY REMOVED \(model.removedPlaylists.count)").font(.system(size: 9, weight: .bold)).tracking(0.8)
                    Spacer()
                }
                .foregroundStyle(Screen.textTertiary)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRemoved {
                ForEach(model.removedPlaylists) { removed in removedRow(removed) }
            }
        }
    }

    private func removedRow(_ removed: KnobShiftRemovedPlaylist) -> some View {
        let daysLeft = max(0, Int((KnobShiftPlaylists.keepRemovedFor - Date().timeIntervalSince(removed.removedAt)) / 86_400))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(removed.playlist.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary).lineLimit(1)
                Text("Deleted for good in \(daysLeft) day\(daysLeft == 1 ? "" : "s")").font(.system(size: 9.5)).foregroundStyle(Screen.textTertiary)
            }
            Spacer(minLength: 4)
            Button("RESTORE") { Task { await model.restorePlaylist(removed) } }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
            Button("DELETE") { confirmDelete = removed }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Screen.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func icon(_ kind: KnobShiftPlaylist.Kind) -> String {
        switch kind {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .liked: return "heart.fill"
        }
    }
}
