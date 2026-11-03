import SwiftUI

/// Picking songs from a Spotify list before anything downloads: a tick box per song (native
/// checkbox Toggle), Select all and Select none, a search field for long lists, and songs
/// already in the queue shown ticked and fixed. The list is a lazy List, so thousands of songs
/// scroll smoothly; the footer always shows how many are ticked.
struct KnobShiftSpotifyPicker: View {
    let review: KnobShiftModel.SpotifyReview
    var onAdd: (Set<String>) -> Void
    var onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var search = ""

    private var shown: [KnobShiftSpotDL.Song] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return review.songs }
        return review.songs.filter { $0.name.lowercased().contains(text) || $0.artists.joined(separator: " ").lowercased().contains(text) }
    }

    private var newCount: Int { selected.subtracting(review.queued).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Screen.text).lineLimit(1)
                    Text("\(review.songs.count) song\(review.songs.count == 1 ? "" : "s") on \(review.source == .youtube ? "YouTube" : "Spotify")" + (review.queued.isEmpty ? "" : ", \(review.queued.count) in your queue"))
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

            List(shown, id: \.song_id) { song in
                row(song)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
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
        .onAppear { selected = review.initial }
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
