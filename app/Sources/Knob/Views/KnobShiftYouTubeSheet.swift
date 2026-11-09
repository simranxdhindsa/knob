import SwiftUI

/// Adding music from YouTube: paste a video, playlist or YouTube Music album link, or sign in
/// with Google and pick from your own YouTube (KnobShiftYouTubeDashboard). Every list opens in
/// the song picker first
/// (KnobShiftSpotifyPicker, shared with Spotify), and running downloads show their progress here
/// with Cancel. Built like Add from Spotify, with the same link box, downloads and status line.
struct KnobShiftYouTubeSheet: View {
    @ObservedObject var model: KnobShiftModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PersistKey.knobShiftYouTubeNoticeAccepted.rawValue) private var noticeAccepted = false
    @State private var link = ""
    /// Snapshots show the form or the notice regardless of what was accepted.
    var showsForm: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !(showsForm ?? noticeAccepted) {
                notice
            } else if let review = model.spotifyReview, review.source == .youtube {
                KnobShiftSpotifyPicker(review: review,
                                       onAdd: {
                                           // The songs join the queue and download in the background, so the sheet closes.
                                           model.confirmSpotifyReview(selected: $0)
                                           dismiss()
                                       },
                                       onAddAll: {
                                           model.addAllFromSpotifyReview()
                                           dismiss()
                                       },
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
            YouTubeMark().frame(width: 20, height: 20)
            Text("ADD FROM YOUTUBE").font(.system(size: 12, weight: .heavy)).tracking(1.4).foregroundStyle(Screen.text)
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
            Text("KnobShift saves the sound of each video to Music, KnobShift, YouTube, with its name and cover, so it can mix it like any song on your Mac. Keep only music you have the right to keep.")
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
            LinkField(placeholder: "Paste a YouTube video, playlist or album link", text: $link, enabled: idle,
                      pasteHelp: "Paste the link you copied on YouTube", addHelp: "Add these songs", onPaste: paste, onAdd: add)
            // Signed in, the rows make the sheet tall, so they scroll inside it.
            if model.youtubeSignedIn {
                ScrollView(.vertical, showsIndicators: false) { account }.frame(height: 470)
            } else {
                account
            }
            KnobShiftBrowserChoice()
            KnobShiftDownloadsCard(model: model)
            KnobShiftImportStatus(model: model)
        }
    }

    private var idle: Bool { model.spotifyReadJob == nil && model.spotifyLoginJob == nil && !model.youtubeSigningIn }

    /// Puts the copied text in the box, where the person sees it and presses ADD. Says so when
    /// nothing, or no YouTube link, was copied.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            model.spotifyStatus = "Nothing to paste. On YouTube, choose Share, then Copy."
            return
        }
        link = text
        if KnobShiftYouTubeParsing.parseLink(text) == nil {
            model.spotifyStatus = "That isn't a YouTube video, playlist or album link."
        } else if model.spotifyStatus?.hasPrefix("Nothing to paste") == true || model.spotifyStatus?.hasPrefix("That isn't") == true {
            model.spotifyStatus = nil
        }
    }

    private func add() {
        guard idle, !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = link
        Task {
            await model.addFromYouTube(text)
            // Cleared once the list opened; after a problem the link stays for another try.
            if model.spotifyReview != nil { link = "" }
        }
    }

    /// The Google key, signing in, and the person's YouTube.
    private var account: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.youtubeSignedIn { KnobShiftGoogleKey(model: model) }
            KnobShiftYouTubeDashboard(model: model, idle: idle)
        }
    }
}
