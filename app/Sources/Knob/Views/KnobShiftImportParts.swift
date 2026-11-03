import SwiftUI

/// Downloads on their way, each with its progress and Cancel, shown in Add from Spotify and Add
/// from YouTube (a download of either shows in both, since they share one download lane).
struct KnobShiftDownloadsCard: View {
    @ObservedObject var model: KnobShiftModel

    var body: some View {
        let active = model.playlists.filter { model.spotifyProgress[$0.id] != nil }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("DOWNLOADING").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                ForEach(active) { playlist in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                            if let progress = model.spotifyProgress[playlist.id] { KnobShiftImportBar(progress: progress) }
                        }
                        Button("CANCEL") { model.cancelDownload(playlist) }
                            .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.6)
                            .foregroundStyle(Screen.textSecondary)
                            .accessibilityLabel("Cancel downloading \(playlist.name)")
                    }
                }
            }
            .screenCard(radius: 14, padding: 12)
        }
    }
}

/// The import's status line. Always present at the same height, empty or not, so the sheet never
/// jumps; a breathing dot shows while something works, and Cancel stops a list being read.
struct KnobShiftImportStatus: View {
    @ObservedObject var model: KnobShiftModel
    @State private var pulse = false

    private var busy: Bool { model.spotifyReadJob != nil || model.spotifyLoginJob != nil || model.youtubeSigningIn }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
                .shadow(color: Palette.accentGlow, radius: pulse ? 5 : 1)
                .opacity(busy ? (pulse ? 1 : 0.4) : 0)
                // The breathing belongs to the dot alone, so nothing else in the sheet moves.
                .animation(Motion.pulse, value: pulse)
            Text(model.spotifyStatus ?? " ")
                .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if model.spotifyReadJob != nil || model.youtubeSigningIn {
                Button("CANCEL") { if model.youtubeSigningIn { model.cancelYouTubeSignIn() } else { model.cancelSpotifyRead() } }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(height: 32, alignment: .leading)
        .onAppear { DispatchQueue.main.async { pulse = true } }
    }
}
