import SwiftUI

/// The Spotify playlists in the queue, each a slim row with its name, how many songs are ready,
/// Update and remove, and below them the playlists removed in the last 30 days with Restore.
/// Every row has a fixed height, so the queue never jumps while songs download. Removing and
/// deleting for good both ask first.
struct KnobShiftPlaylistRows: View {
    @Environment(\.surface) private var surface
    @ObservedObject var model: KnobShiftModel
    /// Open the Add sheets: the song picker for an update lives there.
    var onSpotify: () -> Void = {}
    var onYouTube: () -> Void = {}
    /// In the Playlists view the rows take the whole height and open a playlist when clicked;
    /// otherwise up to three show and more scroll.
    var fills = false
    var onOpen: ((KnobShiftPlaylist) -> Void)? = nil
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
            .frame(maxHeight: !fills && model.playlists.count + (showRemoved ? model.removedPlaylists.count : 0) > 3 ? 150 : nil)
            .fixedSize(horizontal: false, vertical: !fills && model.playlists.count + (showRemoved ? model.removedPlaylists.count : 0) <= 3)
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

    private func service(_ playlist: KnobShiftPlaylist) -> String { playlist.source == .youtube ? "YouTube" : "Spotify" }

    private func row(_ playlist: KnobShiftPlaylist) -> some View {
        let count = model.playlistCount(playlist)
        let progress = model.spotifyProgress[playlist.id]
        let failed = progress == nil ? model.failedCount(in: playlist) : 0
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: KnobShiftPlaylistDetail.icon(playlist.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(surface.text).lineLimit(1)
                    if let progress {
                        KnobShiftImportBar(progress: progress, compact: true)
                    } else {
                        Text(failed > 0 ? "\(count.ready) of \(count.total) ready, \(failed) not downloaded" : "\(count.total) song\(count.total == 1 ? "" : "s") from \(service(playlist))")
                            .font(.system(size: 9.5)).foregroundStyle(surface.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if onOpen != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(surface.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?(playlist) }
            .help(onOpen == nil ? "" : "Open \(playlist.name) to add its songs")
            if progress != nil {
                Button { model.cancelDownload(playlist) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(surface.secondary)
                .help("Stop downloading")
                .accessibilityLabel("Stop downloading \(playlist.name)")
            } else {
                if failed > 0 {
                    Button("RETRY") { model.retryFailed(playlist) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
                        .help("Try the songs that did not download again")
                        .accessibilityLabel("Retry \(failed) songs of \(playlist.name)")
                }
                Button {
                    if playlist.source == .youtube { onYouTube() } else { onSpotify() }
                    Task { await model.updatePlaylist(playlist) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(surface.secondary)
                .disabled(model.spotifyReadJob != nil)
                .help("Update from \(service(playlist)) and pick songs")
                .accessibilityLabel("Update \(playlist.name) from \(service(playlist))")
            }
            Button { confirmRemove = playlist } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(surface.tertiary)
            .accessibilityLabel("Remove \(playlist.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(surface.fill))
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
                .foregroundStyle(surface.tertiary)
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
                Text(removed.playlist.name).font(.system(size: 11, weight: .medium)).foregroundStyle(surface.secondary).lineLimit(1)
                Text(daysLeft == 0 ? "Last day to restore this" : "You can restore this for \(daysLeft) more day\(daysLeft == 1 ? "" : "s")")
                    .font(.system(size: 9.5)).foregroundStyle(surface.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("RESTORE") { Task { await model.restorePlaylist(removed) } }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
            Button("DELETE") { confirmDelete = removed }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(surface.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }
}
