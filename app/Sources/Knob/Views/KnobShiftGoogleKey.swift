import SwiftUI

/// The person's own Google key, which signing in to YouTube needs: a "TVs and Limited Input
/// devices" OAuth client with YouTube Data API v3 turned on. Built like the Spotify key card;
/// folded to one line once a key is saved. The secret is typed into a secure field, never shown.
struct KnobShiftGoogleKey: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var hub: KnobShiftYouTubeHub
    @State private var open: Bool
    @State private var clientId = ""
    @State private var secret = ""
    @State private var saving = false

    /// `startsOpen` shows the steps and fields at once (for snapshots).
    init(model: KnobShiftModel, startsOpen: Bool = false) {
        self.model = model
        hub = model.youtubeHub
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hub.hasKey ? Palette.accent : Screen.textTertiary)
                Text(hub.hasKey ? "Using your Google key" : "Signing in needs your own free Google key")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Screen.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button(hub.hasKey ? "REMOVE" : open ? "CLOSE" : "ADD KEY") {
                    if hub.hasKey { model.removeGoogleKey() } else { withAnimation(Motion.gentle) { open.toggle() } }
                }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(0.7)
                .foregroundStyle(Palette.accent)
                .disabled(saving || model.youtubeSigningIn)
            }
            if open, !hub.hasKey { form }
        }
        .screenCard(radius: 14, padding: 12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                KeyFormStep(number: 1, text: "Open Google Cloud and pick or create a project.")
                KeyFormStep(number: 2, text: "In APIs and Services, Library, turn on YouTube Data API v3.")
                KeyFormStep(number: 3, text: "On the OAuth consent screen, add your Google account as a test user.")
                KeyFormStep(number: 4, text: "In Credentials, create an OAuth client ID of the type TVs and Limited Input devices.")
                KeyFormStep(number: 5, text: "Copy its Client ID and Client secret here. A key you already made for a TV works too.")
            }
            Link(destination: KnobShiftGoogleAuth.consoleURL) {
                Label("OPEN GOOGLE CLOUD", systemImage: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Palette.accent)
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
            let saved = await model.saveGoogleKey(id: clientId, secret: secret)
            saving = false
            if saved {
                secret = ""
                clientId = ""
                withAnimation(Motion.gentle) { open = false }
            }
        }
    }
}
