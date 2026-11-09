import SwiftUI

/// Picking songs from a Spotify list before anything downloads: a tick box per song (native
/// checkbox Toggle), Select all and Select none, a search field for long lists, and songs
/// already in the queue shown ticked and fixed. The list is a lazy List, so thousands of songs
/// scroll smoothly; the footer always shows how many are ticked.
struct KnobShiftSpotifyPicker: View {
    let review: KnobShiftModel.SpotifyReview
    var onAdd: (Set<String>) -> Void
    /// Adds every new song in the background and closes, for an update of a list already here.
    var onAddAll: () -> Void = {}
    var onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var search = ""
    /// Songs the picker has already ticked or left, so songs arriving later only add their own ticks.
    @State private var seen: Set<String> = []
    /// An update asks first whether to add everything new or choose.
    @State private var choosing = false
    private static let skeletonWidths: [CGFloat] = [55, 70, 48, 65, 58, 72]

    private var shown: [KnobShiftSpotDL.Song] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return review.songs }
        return review.songs.filter { $0.name.lowercased().contains(text) || $0.artists.joined(separator: " ").lowercased().contains(text) }
    }

    private var newCount: Int { selected.subtracting(review.queued).count }

    var body: some View {
        Group {
            if review.isUpdate && !choosing {
                KnobShiftUpdateChoice(review: review, onAddAll: onAddAll, onChoose: { choosing = true }, onCancel: onCancel)
            } else {
                picker
            }
        }
        .onAppear {
            selected = review.initial
            seen = Set(review.songs.map(\.song_id))
        }
        // More of a long list arrived: its songs come in ticked, unless unticked before.
        .onChange(of: review.songs.count) {
            let fresh = Set(review.songs.map(\.song_id)).subtracting(seen)
            selected.formUnion(review.initial.intersection(fresh))
            seen.formUnion(fresh)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Screen.text).lineLimit(1)
                    Text("\(review.songs.count) song\(review.songs.count == 1 ? "" : "s") on \(review.source == .youtube ? "YouTube" : "Spotify")"
                         + (review.queued.isEmpty ? "" : ", \(review.queued.count) in your queue") + (review.loadingMore ? ", reading more…" : ""))
                        .font(.system(size: 10)).foregroundStyle(Screen.textTertiary)
                }
                Spacer()
                Button("ALL") { selected = Set(review.songs.map(\.song_id)) }
                Button("NONE") { selected = review.queued }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.accent)

            if review.songs.count > 12 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(Screen.textTertiary)
                    TextField("Find a song or artist", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(Screen.text)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Screen.tabTrack))
            }

            List {
                ForEach(shown, id: \.song_id) { song in
                    row(song)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
                }
                // The rest of a long list is on its way: rows shaped like songs stand in for it.
                if review.loadingMore && search.isEmpty {
                    ForEach(0..<3, id: \.self) { index in
                        skeletonRow(index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 300)
            .overlay {
                if shown.isEmpty {
                    Text("No songs match").font(.system(size: 11)).foregroundStyle(Screen.textTertiary)
                }
            }

            HStack(spacing: 10) {
                Text(newCount == 0 ? "Nothing new ticked" : "\(newCount) song\(newCount == 1 ? "" : "s") to add")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                Spacer()
                Button("CANCEL", action: onCancel)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Screen.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Button { onAdd(selected) } label: {
                    Text(newCount == 0 ? "ADD" : "ADD \(newCount)").font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(Capsule().fill(newCount > 0 ? Palette.accent : Screen.textTertiary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(newCount == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .screenCard(radius: 14, padding: 12)
    }

    private func skeletonRow(_ index: Int) -> some View {
        let width = Self.skeletonWidths[index % 6]
        return HStack(spacing: 8) {
            Image(systemName: "square").font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(repeating: "W", count: Int(width / 5))).font(.system(size: 11, weight: .semibold))
                Text(String(repeating: "W", count: Int(width / 8))).font(.system(size: 10))
            }
            Spacer()
            Text("0:00").font(.system(size: 10).monospacedDigit())
        }
        .foregroundStyle(Screen.textTertiary)
        .redacted(reason: .placeholder)
        .frame(height: 32)
        .accessibilityHidden(true)
    }

    private func row(_ song: KnobShiftSpotDL.Song) -> some View {
        let inQueue = review.queued.contains(song.song_id)
        return Toggle(isOn: Binding(
            get: { selected.contains(song.song_id) },
            set: { on in if on { selected.insert(song.song_id) } else { selected.remove(song.song_id) } }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                    Text(song.artists.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Screen.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if inQueue {
                    Text("IN QUEUE").font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(Screen.textTertiary)
                } else if let duration = song.duration {
                    Text(KnobShiftNowPlaying.clock(duration)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Screen.textTertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.accent)
        .disabled(inQueue)
        .frame(height: 32)
        .accessibilityLabel("\(song.name) by \(song.artists.joined(separator: ", "))")
    }
}

/// The question an update asks first: add every new song in the background, or choose them.
struct KnobShiftUpdateChoice: View {
    let review: KnobShiftModel.SpotifyReview
    var onAddAll: () -> Void
    var onChoose: () -> Void
    var onCancel: () -> Void

    var body: some View {
        let count = review.newCount
        let upToDate = count == 0 && !review.loadingMore
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(review.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Screen.text).lineLimit(1)
                Text(upToDate ? "Up to date. Every song is already here."
                     : "\(count)\(review.loadingMore ? " or more" : "") new song\(count == 1 && !review.loadingMore ? "" : "s") on Spotify"
                       + (review.loadingMore ? ", still reading the rest of the list." : "."))
                    .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !upToDate {
                    Text("Add All downloads them one by one in the background, so you can keep listening.")
                        .font(.system(size: 10)).foregroundStyle(Screen.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(upToDate ? "DONE" : "CANCEL", action: onCancel)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Screen.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("CHOOSE SONGS", action: onChoose)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Palette.accent)
                if !upToDate {
                    Button(action: onAddAll) {
                        Text("ADD ALL NEW").font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 26)
                            .background(Capsule().fill(Palette.accent))
                            .shadow(color: Palette.accentGlow.opacity(0.5), radius: 6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
                }
            }
        }
        .screenCard(radius: 14, padding: 12)
    }
}
