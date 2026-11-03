import SwiftUI

/// The signed in part of Add from YouTube: the account line, the code while signing in, the
/// Music only switch, and rows of the person's YouTube (Liked music, their playlists, new music
/// from subscriptions, popular music in their country). Clicking a row's ADD or any of its
/// thumbnails opens the row in the song picker; a playlist card opens that playlist.
struct KnobShiftYouTubeDashboard: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var hub: KnobShiftYouTubeHub
    @AppStorage(PersistKey.knobShiftYouTubeMusicOnly.rawValue) private var musicOnly = true
    let idle: Bool

    init(model: KnobShiftModel, idle: Bool) {
        self.model = model
        hub = model.youtubeHub
        self.idle = idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            account
            if let code = hub.code { KnobShiftYouTubeCode(code: code) }
            if model.youtubeSignedIn {
                Toggle(isOn: $musicOnly) {
                    Text("Music only").font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Palette.accent)
                shelf(.liked)
                playlistsRow
                shelf(.new)
                shelf(.popular)
            }
        }
        .onAppear { model.loadYouTubeDashboard() }
    }

    private var account: some View {
        HStack(spacing: 8) {
            Circle().fill(model.youtubeSignedIn ? Palette.accent : Screen.textTertiary).frame(width: 7, height: 7)
            Text(model.youtubeSignedIn ? "Signed in to YouTube" : "Your own YouTube music")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary).lineLimit(1)
            Spacer()
            if model.youtubeSignedIn {
                Button("SIGN OUT") { model.signOutOfYouTube() }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Palette.accent).disabled(!idle)
            } else if !model.youtubeSigningIn {
                Button(action: model.signInWithGoogle) {
                    Label("SIGN IN WITH GOOGLE", systemImage: "person.crop.circle")
                        .font(.system(size: 10, weight: .bold)).tracking(0.7)
                        .foregroundStyle(canSignIn ? Palette.accent : Screen.textTertiary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().strokeBorder(Palette.accent.opacity(canSignIn ? 0.45 : 0.15), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSignIn)
                .help(hub.hasKey ? "Shows a code to enter on Google's page" : "Add your Google key first")
            }
        }
    }

    private var canSignIn: Bool { idle && hub.hasKey }

    // MARK: Rows

    private func shelf(_ shelf: KnobShiftYouTubeHub.Shelf) -> some View {
        let videos = hub.videos(shelf, musicOnly: musicOnly)
        return row(KnobShiftYouTubeHub.title(shelf, musicOnly: musicOnly), count: videos?.count,
                   onAdd: { Task { await model.openYouTubeShelf(shelf) } }) {
            if let videos {
                if videos.isEmpty {
                    empty(musicOnly && shelf != .popular ? "No music here. Turn off Music only to see every video." : "Nothing here yet.")
                } else {
                    ForEach(videos.prefix(12)) { video in
                        KnobShiftYouTubeTile(title: video.title, detail: video.channel, thumbnail: video.thumbnail) {
                            Task { await model.openYouTubeShelf(shelf) }
                        }
                        .disabled(!idle)
                    }
                }
            } else {
                notLoaded
            }
        }
    }

    private var playlistsRow: some View {
        row("Your playlists", count: hub.playlists?.count, onAdd: nil) {
            if let lists = hub.playlists {
                if lists.isEmpty { empty("You have no playlists on YouTube yet.") }
                ForEach(lists) { list in
                    KnobShiftYouTubeTile(title: list.title, detail: "\(list.count) video\(list.count == 1 ? "" : "s")",
                                         thumbnail: list.thumbnail) {
                        Task { await model.openYouTubePlaylist(id: list.id, name: list.title) }
                    }
                    .disabled(!idle)
                }
            } else {
                notLoaded
            }
        }
    }

    private func row<Content: View>(_ title: String, count: Int?, onAdd: (() -> Void)?,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                    .lineLimit(1)
                if let count { Text("\(count)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(Screen.textTertiary) }
                Spacer()
                if let onAdd, (count ?? 0) > 0 {
                    Button("ADD", action: onAdd)
                        .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundStyle(Palette.accent).disabled(!idle)
                        .accessibilityLabel("Add from \(title)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) { content() }
            }
            .frame(height: 112)
        }
        .screenCard(radius: 14, padding: 12)
    }

    /// Skeleton tiles while loading; after a failed load, a way to try again.
    @ViewBuilder private var notLoaded: some View {
        if hub.loading {
            KnobShiftYouTubeTileSkeleton(count: 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not loaded yet.").font(.system(size: 10.5)).foregroundStyle(Screen.textTertiary)
                Button("TRY AGAIN") { model.loadYouTubeDashboard(force: true) }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Palette.accent).disabled(!idle)
            }
            .frame(height: 100)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Screen.textTertiary).frame(height: 100)
    }
}

/// The code to enter on Google's page while signing in, large enough to read across a desk.
struct KnobShiftYouTubeCode: View {
    let code: KnobShiftGoogleAuth.DeviceCode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ENTER THIS CODE AT \(code.verificationURL.host?.uppercased() ?? "GOOGLE.COM/DEVICE")\(code.verificationURL.path.uppercased())")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
            HStack {
                Text(code.userCode).font(.system(size: 26, weight: .bold).monospaced()).foregroundStyle(Screen.text)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: {
                    Label("COPY", systemImage: "doc.on.doc").font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                Link(destination: code.verificationURL) {
                    Label("OPEN PAGE", systemImage: "arrow.up.right.square").font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Palette.accent)
                }
            }
            Text("Choose your Google account there and allow Knob to see your YouTube. Knob can only read, never change anything.")
                .font(.system(size: 10)).foregroundStyle(Screen.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .screenCard(radius: 14, padding: 12)
    }
}

/// One video or playlist: its thumbnail, title and channel (or song count).
struct KnobShiftYouTubeTile: View {
    let title: String
    let detail: String
    let thumbnail: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Screen.tabTrack)
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Screen.highlight, lineWidth: 1))
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                Text(detail).font(.system(size: 9)).foregroundStyle(Screen.textTertiary).lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Tiles still loading, in the same layout, with uneven text widths.
struct KnobShiftYouTubeTileSkeleton: View {
    let count: Int
    private static let widths: [CGFloat] = [55, 70, 48, 65, 58, 72]

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Screen.tabTrack).frame(width: 120, height: 68)
                Capsule().fill(Screen.tabTrack).frame(width: 120 * Self.widths[index % 6] / 100 + 20, height: 8)
                Capsule().fill(Screen.tabTrack.opacity(0.7)).frame(width: Self.widths[(index + 3) % 6], height: 7)
            }
            .frame(width: 120, alignment: .leading)
        }
    }
}
