import SwiftUI

/// Adding music from Spotify: paste a playlist, album or song link, or log in and pick from your
/// own playlists and Liked Songs. Every list opens in the song picker first
/// (KnobShiftSpotifyPicker), and running downloads show their progress here with Cancel. The
/// link field follows the 21st.dev Url Input by ruixen.ui (an icon inside the field, the action
/// at its end), rebuilt in SwiftUI on Knob's dark screen. The status line always keeps its
/// height, so nothing in the sheet moves while it works.
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
            if !(showsForm ?? noticeAccepted) {
                notice
            } else if let review = model.spotifyReview {
                KnobShiftSpotifyPicker(review: review,
                                       onAdd: { model.confirmSpotifyReview(selected: $0) },
                                       onCancel: { model.dismissSpotifyReview() })
            } else {
                form
            }
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
            downloads
            status
        }
        .task {
            if model.spotifyLoggedIn, model.spotifyAccount == nil { await model.loadSpotifyAccount() }
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

    private var idle: Bool { model.spotifyReadJob == nil && model.spotifyLoginJob == nil }
    private var canAdd: Bool { idle && !link.trimmingCharacters(in: .whitespaces).isEmpty }

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
                Text(model.spotifyLoggedIn ? "Logged in" + (model.spotifyAccount?.name.map { " as \($0)" } ?? " to Spotify") : "Log in for your playlists and Liked Songs")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                Spacer()
                Button {
                    if model.spotifyLoginJob != nil { model.cancelSpotifyLogin() }
                    else if model.spotifyLoggedIn { model.logOutOfSpotify() }
                    else { Task { await model.logInToSpotify() } }
                } label: {
                    Text(model.spotifyLoginJob != nil ? "CANCEL" : model.spotifyLoggedIn ? "LOG OUT" : "LOG IN")
                        .font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.spotifyReadJob != nil)
            }
            Button { Task { await model.addLikedSongs() } } label: {
                Label("ADD LIKED SONGS", systemImage: "heart.fill").font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(model.spotifyLoggedIn ? Palette.accent : Screen.textTertiary)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().strokeBorder(Palette.accent.opacity(model.spotifyLoggedIn ? 0.45 : 0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!model.spotifyLoggedIn || !idle)
            if model.spotifyLoggedIn { yourPlaylists }
        }
        .screenCard(radius: 14, padding: 12)
    }

    /// Every playlist the account owns or follows, each with Add (or Update when it is already
    /// in KnobShift). Skeleton rows stand in while they load.
    private var yourPlaylists: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR PLAYLISTS\(model.spotifyAccount.map { " \($0.playlists.count)" } ?? "")")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let account = model.spotifyAccount {
                        if account.playlists.isEmpty {
                            Text("No playlists on this account.").font(.system(size: 11)).foregroundStyle(Screen.textTertiary)
                                .frame(height: 30)
                        }
                        ForEach(account.playlists) { playlist in accountRow(playlist) }
                    } else {
                        ForEach(0..<4, id: \.self) { index in skeletonRow(index) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: 150)
        }
        .padding(.top, 4)
    }

    private func accountRow(_ playlist: KnobShiftSpotifyAccount.Playlist) -> some View {
        let added = model.playlists.contains { $0.id == playlist.id }
        return HStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(playlist.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                Text("\(playlist.songs) song\(playlist.songs == 1 ? "" : "s")" + (playlist.owner.map { " by \($0)" } ?? ""))
                    .font(.system(size: 9.5)).foregroundStyle(Screen.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(added ? "UPDATE" : "ADD") { Task { await model.addAccountPlaylist(playlist) } }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(idle ? Palette.accent : Screen.textTertiary)
                .disabled(!idle)
                .accessibilityLabel("\(added ? "Update" : "Add") \(playlist.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Screen.tabTrack.opacity(0.6)))
    }

    private func skeletonRow(_ index: Int) -> some View {
        let widths: [CGFloat] = [55, 70, 48, 65, 58, 72]
        return HStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 10)).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(repeating: "W", count: Int(widths[index % 6] / 5))).font(.system(size: 11, weight: .semibold))
                Text("00 songs").font(.system(size: 9.5))
            }
            Spacer()
        }
        .foregroundStyle(Screen.textTertiary)
        .redacted(reason: .placeholder)
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    /// Downloads on their way, each with its progress and Cancel.
    @ViewBuilder private var downloads: some View {
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

    /// Always present at the same height, empty or not, so the sheet never jumps.
    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
                .shadow(color: Palette.accentGlow, radius: pulse ? 5 : 1)
                .opacity(!idle ? (pulse ? 1 : 0.4) : 0)
                // The breathing belongs to the dot alone, so nothing else in the sheet moves.
                .animation(Motion.pulse, value: pulse)
            Text(model.spotifyStatus ?? " ")
                .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if model.spotifyReadJob != nil {
                Button("CANCEL") { model.cancelSpotifyRead() }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(height: 32, alignment: .leading)
        .onAppear { DispatchQueue.main.async { pulse = true } }
    }
}
