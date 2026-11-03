import SwiftUI

/// The person's own Spotify key. spotDL's shared key is used by everyone who uses spotDL, and
/// Spotify pauses it for a day when it is used up; a key of one's own has its own limit. Folded
/// away to one line until it is wanted. The secret is typed into a secure field and never shown.
struct KnobShiftSpotifyKey: View {
    @ObservedObject var model: KnobShiftModel
    @State private var hasKey = KnobShiftSpotifyAccount.hasOwnKey
    @State private var open: Bool
    @State private var clientId = ""
    @State private var secret = ""
    @State private var saving = false

    /// `startsOpen` shows the steps and fields at once (for snapshots).
    init(model: KnobShiftModel, startsOpen: Bool = false) {
        self.model = model
        _open = State(initialValue: startsOpen)
    }

    private static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!
    private static let redirect = "http://127.0.0.1:9900/"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hasKey ? Palette.accent : Screen.textTertiary)
                Text(hasKey ? "Using your own Spotify key" : "Shared Spotify key")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                Spacer()
                Button(hasKey ? "REMOVE" : open ? "CLOSE" : "USE MY OWN KEY") {
                    if hasKey {
                        model.removeSpotifyKey()
                        hasKey = KnobShiftSpotifyAccount.hasOwnKey
                    } else {
                        withAnimation(Motion.gentle) { open.toggle() }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.7)
                .foregroundStyle(Palette.accent)
                .disabled(saving)
            }
            if open, !hasKey { form }
        }
        .screenCard(radius: 14, padding: 12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify sometimes pauses the shared key for a day. Your own free key avoids that. It needs Spotify Premium.")
                .font(.system(size: 10.5)).foregroundStyle(Screen.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                KeyFormStep(number: 1, text: "Open the Spotify developer page and create an app.")
                KeyFormStep(number: 2, text: "Add this Redirect URI: \(Self.redirect)")
                KeyFormStep(number: 3, text: "Tick Web API and save.")
                KeyFormStep(number: 4, text: "In the app's settings, copy the Client ID and the Client secret.")
            }
            HStack(spacing: 12) {
                Link(destination: Self.dashboard) {
                    Label("OPEN SPOTIFY DEVELOPER", systemImage: "arrow.up.right.square")
                        .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Palette.accent)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.redirect, forType: .string)
                    model.spotifyStatus = "Redirect URI copied."
                } label: {
                    Label("COPY REDIRECT URI", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            KeyFormField(label: "Client ID", text: $clientId)
            KeyFormField(label: "Client secret", secure: true, text: $secret)
            HStack {
                Spacer()
                Button(action: save) {
                    Text(saving ? "CHECKING" : "SAVE KEY").font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(Capsule().fill(canSave ? Palette.accent : Screen.textTertiary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        !saving && !clientId.trimmingCharacters(in: .whitespaces).isEmpty && !secret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard canSave else { return }
        saving = true
        Task {
            let saved = await model.saveSpotifyKey(id: clientId, secret: secret)
            saving = false
            if saved {
                secret = ""
                clientId = ""
                hasKey = true
                withAnimation(Motion.gentle) { open = false }
            }
        }
    }
}
