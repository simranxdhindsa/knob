import SwiftUI

/// Adding music from Spotify: paste a playlist, album or song link, or log in to add private
/// playlists and Liked Songs. The link field follows the 21st.dev Url Input by ruixen.ui (an
/// icon inside the field, the action at its end), rebuilt in SwiftUI on Knob's dark screen. The
/// status line always keeps its height, so nothing in the sheet moves while it works.
struct KnobShiftSpotifySheet: View {
    @ObservedObject var model: KnobShiftModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PersistKey.knobShiftSpotifyNoticeAccepted.rawValue) private var noticeAccepted = false
    @State private var link = ""
    @State private var pulse = false
    /// Snapshots show the form or the notice regardless of what was accepted.
    var showsForm: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if showsForm ?? noticeAccepted { form } else { notice }
        }
        .padding(22)
        .frame(width: 460)
        .background(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("ADD FROM SPOTIFY").font(.system(size: 12, weight: .heavy)).tracking(1.4).foregroundStyle(Screen.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Screen.textSecondary)
                    .frame(width: 24, height: 24).background(Circle().fill(Screen.tabTrack))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    /// Shown once, before the first import.
    private var notice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where the songs come from").font(.system(size: 13, weight: .bold)).foregroundStyle(Screen.text)
            Text("KnobShift reads the list from Spotify, then finds each song on YouTube and saves it to Music, KnobShift, Spotify with Spotify's names and covers. Spotify itself never plays here. Keep only music you have the right to keep.")
                .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { withAnimation(Motion.gentle) { noticeAccepted = true } } label: {
                Text("I UNDERSTAND").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(Capsule().fill(Palette.accent))
                    .shadow(color: Palette.accentGlow.opacity(0.5), radius: 6)
            }
            .buttonStyle(.plain)
        }
        .screenCard(radius: 14, padding: 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            linkField
            account
            status
        }
    }

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.textTertiary)
            TextField("Paste a Spotify playlist, album or song link", text: $link)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Screen.text)
                .onSubmit(add)
            Button(action: add) {
                Text("ADD").font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(canAdd ? Palette.accent : Screen.textTertiary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 34)
        .background(Capsule().fill(Screen.tabTrack))
        .overlay(Capsule().strokeBorder(Screen.highlight, lineWidth: 1))
    }

    private var canAdd: Bool { !model.spotifyBusy && !link.trimmingCharacters(in: .whitespaces).isEmpty }

    private func add() {
        guard canAdd else { return }
        let text = link
        Task {
            await model.addFromSpotify(text)
            if model.spotifyStatus?.hasPrefix("Paste") != true { link = "" }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.spotifyLoggedIn ? Palette.accent : Screen.textTertiary).frame(width: 7, height: 7)
                Text(model.spotifyLoggedIn ? "Logged in to Spotify" : "Log in for private playlists and Liked Songs")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                Spacer()
                Button {
                    if model.spotifyLoggedIn { model.logOutOfSpotify() } else { Task { await model.logInToSpotify() } }
                } label: {
                    Text(model.spotifyLoggedIn ? "LOG OUT" : "LOG IN").font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.spotifyBusy)
            }
            Button { Task { await model.addLikedSongs() } } label: {
                Label("ADD LIKED SONGS", systemImage: "heart.fill").font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(model.spotifyLoggedIn ? Palette.accent : Screen.textTertiary)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().strokeBorder(Palette.accent.opacity(model.spotifyLoggedIn ? 0.45 : 0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!model.spotifyLoggedIn || model.spotifyBusy)
        }
        .screenCard(radius: 14, padding: 12)
    }

    /// Always present at the same height, empty or not, so the sheet never jumps.
    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
                .shadow(color: Palette.accentGlow, radius: pulse ? 5 : 1)
                .opacity(model.spotifyBusy ? (pulse ? 1 : 0.4) : 0)
            Text(model.spotifyStatus ?? " ")
                .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(height: 32, alignment: .leading)
        .onAppear { withAnimation(Motion.pulse) { pulse = true } }
    }
}
