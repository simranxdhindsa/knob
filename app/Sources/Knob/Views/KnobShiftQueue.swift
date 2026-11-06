import SwiftUI

/// The song that plays next, shown the same way playing, paused or stopped, at a fixed height,
/// so the layout never jumps when playback changes.
struct KnobShiftUpNext: View {
    @Environment(\.surface) private var surface
    @ObservedObject var model: KnobShiftModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UP NEXT").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(surface.tertiary)
            HStack(spacing: 12) {
                AlbumArtwork(url: model.upNext?.url, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    if let next = model.upNext {
                        Text(next.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(surface.text).lineLimit(1)
                        Text(model.mixState == .mixing ? "Mixing now" : (next.artist ?? "Local music"))
                            .font(.system(size: 11, weight: model.mixState == .mixing ? .semibold : .regular))
                            .foregroundStyle(model.mixState == .mixing ? Palette.accent : surface.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Nothing yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(surface.secondary)
                        Text("Add another song and KnobShift mixes into it.")
                            .font(.system(size: 11)).foregroundStyle(surface.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 46)
        }
        .screenCard(radius: 16, padding: 14)
    }
}

/// Which rows are on screen, kept as plain data (not state) so scrolling never redraws the list.
/// It lets the queue come back to the same place after a search and know when the playing song
/// has scrolled away.
final class QueueViewport {
    var visible = Set<UUID>()
    /// The first song in view when a search began.
    var anchor: UUID?

    func firstVisibleIndex(in ids: [UUID]) -> Int? { ids.firstIndex { visible.contains($0) } }
}

/// The queue: every song with its cover and length, the playing one highlighted and the songs
/// already played dimmed. Songs can be dragged into a new order, and shuffle shows the shuffled
/// order so what plays next is visible. Songs are selected like in Music: click, Shift click for a
/// range, Command click to add one, Command A for all; double click plays. Delete, REMOVE or the
/// right click menu removes the selection, and the bin removes every song after a confirmation.
/// The search box filters by song or artist; while it filters, dragging is off.
struct KnobShiftQueue: View {
    @ObservedObject var model: KnobShiftModel
    var onAdd: () -> Void
    var onSpotify: () -> Void = {}
    var onYouTube: () -> Void = {}
    var onSync: () -> Void = {}
    @State private var selection: Set<UUID> = []
    @State private var confirmingRemoveAll = false
    @State private var search = ""
    /// The one row the pointer is on (Mac). Rows hold no hover state of their own.
    @State private var hovered: UUID?
    @State private var playingOnScreen = true
    @State private var viewport = QueueViewport()
    @AppStorage(PersistKey.knobShiftShowPlaylists.rawValue) private var showingPlaylists = false
    @Environment(\.surface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String { search.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !query.isEmpty }

    private func matches(_ track: KnobShiftModel.Track) -> Bool {
        QueueSearch.matches(query, in: [track.name, track.artist, track.title])
    }
    private func matches(_ song: KnobShiftModel.PendingSong) -> Bool {
        QueueSearch.matches(query, in: [song.name, song.artist, song.title])
    }

    var body: some View {
        let tracks = searching ? model.tracks.filter(matches) : model.tracks
        let pending = searching ? model.queuePending.filter(matches) : model.queuePending
        VStack(alignment: .leading, spacing: 10) {
            KnobShiftQueueHeader(model: model, showingPlaylists: $showingPlaylists, confirmingRemoveAll: $confirmingRemoveAll,
                                 onAdd: onAdd, onSpotify: onSpotify, onYouTube: onYouTube, onSync: onSync)
                .confirmationDialog("Remove all \(model.tracks.count + model.queuePending.count) songs from the queue?",
                                    isPresented: $confirmingRemoveAll) {
                    Button("Remove all", role: .destructive) { selection = []; search = ""; model.removeAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The music files stay on your \(Platform.deviceName), so you can add them again later.")
                }
            if showingPlaylists {
                KnobShiftPlaylistsView(model: model, onSpotify: onSpotify, onYouTube: onYouTube)
                    .transition(.opacity)
            } else if model.tracks.isEmpty && model.queuePending.isEmpty {
                empty
            } else {
                topLine(shown: tracks.count + pending.count)
                QueueSearchField(text: searchBinding)
                queueList(tracks: tracks, pending: pending)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(Palette.accent).lineLimit(2)
            }
        }
        .screenCard(radius: 16, padding: 14)
        // Escape lets go of the selection on the Mac (the search box has its own Escape).
        .onEscapeKey { if !selection.isEmpty { selection = [] } }
    }

    /// Typing remembers the first song in view, so clearing the search lands in the same place.
    private var searchBinding: Binding<String> {
        Binding(get: { search }, set: { new in
            if search.trimmingCharacters(in: .whitespaces).isEmpty, !new.trimmingCharacters(in: .whitespaces).isEmpty {
                viewport.anchor = viewport.firstVisibleIndex(in: model.tracks.map(\.id)).map { model.tracks[$0].id }
            }
            search = new
        })
    }

    /// The summary, or, with songs selected, what is selected and how to drop or remove it.
    @ViewBuilder
    private func topLine(shown: Int) -> some View {
        if selection.isEmpty {
            QueueSummaryLine(model: model, filteredCount: searching ? shown : nil)
            if searching && !model.tracks.isEmpty {
                Text("Reordering is off while you search. Clear the search to drag songs.")
                    .font(.system(size: 9)).foregroundStyle(surface.tertiary).lineLimit(2)
                    .padding(.top, -6)
            }
        } else {
            QueueSelectionBar(name: selectedName, count: selection.count, onClear: { selection = [] }, onRemove: removeSelection)
        }
    }

    private var selectedName: String? {
        guard selection.count == 1, let id = selection.first else { return nil }
        if let track = model.tracks.first(where: { $0.id == id }) { return SongTitle.parts(name: track.name, artist: track.artist).name }
        return model.queuePending.first { $0.id == id }.map { SongTitle.parts(name: $0.name, artist: $0.artist).name }
    }

    private func queueList(tracks: [KnobShiftModel.Track], pending: [KnobShiftModel.PendingSong]) -> some View {
        let playingID = model.nowPlaying?.id
        // Rows before the playing song, in the order on screen, are the ones already played.
        let playedIDs: Set<UUID> = playingID.flatMap { id in model.tracks.firstIndex { $0.id == id } }
            .map { Set(model.tracks.prefix($0).map(\.id)) } ?? []
        let shownIDs = tracks.map(\.id)
        let playingShown = playingID.map(shownIDs.contains) ?? false
        return ScrollViewReader { reader in
            ZStack(alignment: .bottom) {
                if tracks.isEmpty && pending.isEmpty {
                    Text("No songs match \u{201C}\(query)\u{201D}. Try part of the song name or the artist.")
                        .font(.system(size: 11)).foregroundStyle(surface.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
                } else {
                    // A List gives native drag to reorder, in your order and in shuffle alike.
                    List(selection: $selection) {
                        ForEach(tracks) { track in
                            queueRow(trackRow(track, playingID: playingID, played: playedIDs.contains(track.id)), id: track.id, track: track)
                        }
                        .onMove(perform: searching ? nil : { model.move(fromOffsets: $0, toOffset: $1) })
                        ForEach(pending) { song in
                            queueRow(pendingRow(song), id: song.id, track: nil)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .tint(Palette.accent)
                    .hidesListHighlight(selected: selection.count)
                    .onDeleteKey(perform: removeSelection)
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if !ids.isEmpty {
                            // CONTEXT MENU: Play Next and other song actions go here, above Remove.
                            Button(ids.count == 1 ? "Remove from Queue" : "Remove \(ids.count) Songs from Queue") {
                                selection.subtract(ids)
                                model.remove(ids: ids)
                            }
                        }
                    } primaryAction: { ids in
                        if ids.count == 1, let id = ids.first, let track = model.tracks.first(where: { $0.id == id }) { model.select(track) }
                    }
                    // Songs that left the queue (removed, or finished preparing under a new id) drop
                    // out of the selection.
                    .onChange(of: model.tracks.count + model.queuePending.count) {
                        let present = Set(model.tracks.map(\.id)).union(model.queuePending.map(\.id))
                        selection.formIntersection(present)
                    }
                    // Shuffle animates; mapping every song's id on each change was slow with
                    // thousands of songs.
                    .animation(Motion.respecting(Motion.gentle, reduce: reduceMotion), value: model.isShuffled)
                    // After the list has laid out: before that there is nothing to scroll to.
                    .task {
                        try? await Task.sleep(for: .milliseconds(80))
                        showPlaying(reader)
                    }
                    .onChange(of: model.nowPlaying?.id) { playingOnScreen = true; showPlaying(reader) }
                    #if os(iOS)
                    .padding(.leading, -8)
                    #endif
                }
                if playingShown, !playingOnScreen {
                    let above = (playingID.flatMap { id in shownIDs.firstIndex(of: id) } ?? 0)
                        < (viewport.firstVisibleIndex(in: shownIDs) ?? 0)
                    QueueJumpButton(above: above) { showPlaying(reader, force: true) }
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .animation(Motion.respecting(Motion.snappy, reduce: reduceMotion), value: playingOnScreen)
            // Selection in a search keeps only songs still shown, so REMOVE never takes a hidden one.
            .onChange(of: search) {
                if searching {
                    selection.formIntersection(Set(shownIDs).union(pending.map(\.id)))
                } else {
                    returnToPlace(reader)
                }
            }
        }
    }

    /// Strips the list's own look, leaves room on the right for the scroll bar, adds the swipe to
    /// remove on the iPhone, and tells the list which rows are on screen.
    private func queueRow<Content: View>(_ content: Content, id: UUID, track: KnobShiftModel.Track?) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 2, leading: Self.rowLeading, bottom: 2, trailing: 6))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .id(id)
            #if os(macOS)
            .onHover { inside in
                if inside { hovered = id } else if hovered == id { hovered = nil }
            }
            #else
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { removeOne(id) } label: { Label("Remove", systemImage: "trash") }
            }
            #endif
            .onAppear {
                viewport.visible.insert(id)
                if id == model.nowPlaying?.id { playingOnScreen = true }
            }
            .onDisappear {
                viewport.visible.remove(id)
                if id == model.nowPlaying?.id { playingOnScreen = false }
            }
    }

    private func trackRow(_ track: KnobShiftModel.Track, playingID: UUID?, played: Bool) -> some View {
        QueueTrackRow(
            track: track, playing: track.id == playingID, selected: selection.contains(track.id), played: played,
            hovered: hovered == track.id, reveal: model.justPrepared.contains(track.id),
            voiceNote: voiceNote(track), offersRetry: offersVoiceRetry(track),
            onRetry: { model.rereadVoice(track) }, onRemove: { removeOne(track.id) })
    }

    private func pendingRow(_ song: KnobShiftModel.PendingSong) -> some View {
        QueuePendingRow(song: song, selected: selection.contains(song.id), hovered: hovered == song.id,
                        onRetry: { model.retry(song) }, onRemove: { removeOne(song.id) })
    }

    /// The rows sit flush with the card's header. The iPhone's list cuts off anything drawn past
    /// its edge, which squared off the playing row's left corners, so there the list itself moves.
    #if os(macOS)
    private static let rowLeading: CGFloat = -8
    #else
    private static let rowLeading: CGFloat = 0
    #endif

    /// Brings the playing song into view when the queue opens and when the song changes, unless
    /// rows are selected, which means someone is working in the list. The jump button forces it.
    private func showPlaying(_ reader: ScrollViewProxy, force: Bool = false) {
        guard force || selection.isEmpty, let id = model.nowPlaying?.id else { return }
        reader.scrollTo(id, anchor: .center)
    }

    /// After a search is cleared: back to what was selected, else the song that was at the top.
    private func returnToPlace(_ reader: ScrollViewProxy) {
        let target = model.tracks.first { selection.contains($0.id) }?.id ?? viewport.anchor
        guard let target else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            reader.scrollTo(target, anchor: .top)
        }
    }

    private func removeOne(_ id: UUID) {
        selection.remove(id)
        model.remove(ids: [id])
    }

    private func offersVoiceRetry(_ track: KnobShiftModel.Track) -> Bool {
        track.voiceUnread && track.voiceRetried && !model.rereading.contains(track.id)
    }

    /// The quiet second try shows nothing; only a song that missed twice says so.
    private func voiceNote(_ track: KnobShiftModel.Track) -> String? {
        guard track.voiceUnread, track.voiceRetried else { return nil }
        return model.rereading.contains(track.id) ? "Reading voice" : "Voice not read"
    }

    private func removeSelection() {
        let ids = selection
        selection = []
        model.remove(ids: ids)
    }

    #if os(macOS)
    private static let emptyHint = "KnobShift mixes them into each other like a DJ. Spotify and YouTube links work too, from ADD MUSIC."
    #else
    private static let emptyHint = "KnobShift mixes them into each other like a DJ. Tap ADD MUSIC to pick songs from the Files app."
    #endif

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 24)).foregroundStyle(Palette.accent.opacity(0.85))
            Text("Add songs from your \(Platform.deviceName)").font(.system(size: 12, weight: .semibold)).foregroundStyle(surface.text)
            Text(Self.emptyHint)
                .font(.system(size: 10)).foregroundStyle(surface.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
