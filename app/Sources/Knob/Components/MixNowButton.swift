import SwiftUI

/// KnobMix Now, where Apple Music has its star: a glass button that pulses while it waits for
/// the next phrase, and draws an orange ring around itself as the mix runs.
struct MixNowButton: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock

    var body: some View {
        let mixing = model.mixState == .mixing
        let waiting = model.mixNowWaiting && !mixing
        let ready = model.isPlaying && model.tracks.count > 1 && !mixing && !waiting
        Button {
            Haptics.detent()
            model.mixNow()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .bold))
                .symbolEffect(.pulse, isActive: waiting)
                .foregroundStyle(mixing || waiting ? Palette.accent : Glass.text)
                .opacity(ready || mixing || waiting ? 1 : 0.45)
                .frame(width: 40, height: 40)
                .overlay {
                    if mixing {
                        Circle().trim(from: 0, to: clock.blend)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                    }
                }
                .playerGlass()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .accessibilityLabel(waiting ? "KnobMix Now, waiting for the beat" : "KnobMix Now")
    }
}

/// The three dots: everything else there is to do with the music.
struct PlayerMoreMenu: View {
    @ObservedObject var model: KnobShiftModel
    var onFiles: () -> Void
    var onSpotify: () -> Void
    var onYouTube: () -> Void
    /// Only on the iPhone: bring playlists over from Knob on the Mac.
    var onSync: (() -> Void)?

    var body: some View {
        Menu {
            Section {
                Button { model.mixNow() } label: { Label("KnobMix Now", systemImage: "arrow.left.arrow.right") }
                    .disabled(!model.isPlaying || model.tracks.count < 2 || model.mixState == .mixing || model.mixNowWaiting)
                Button { model.toggleShuffle() } label: {
                    Label(model.isShuffled ? "Turn Shuffle Off" : "Shuffle", systemImage: "shuffle")
                }
                .disabled(model.tracks.count < 2)
            }
            Section {
                Button { KnobShiftTogetherSession.shared.show(model) } label: {
                    Label("Listen Together", systemImage: "hifispeaker.2")
                }
            }
            Section("Add music") {
                Button(action: onSpotify) { Label("From Spotify", systemImage: "link") }
                Button(action: onYouTube) { Label("From YouTube", systemImage: "play.rectangle") }
                if let onSync {
                    Button(action: onSync) { Label("Sync from your Mac", systemImage: "laptopcomputer.and.iphone") }
                }
                Button(action: onFiles) { Label("Songs on your \(Platform.deviceName)", systemImage: "folder") }
            }
            if let track = model.nowPlaying {
                Section {
                    Button(role: .destructive) { model.remove(ids: [track.id]) } label: {
                        Label("Take Out of Queue", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Glass.text)
                .frame(width: 40, height: 40)
                .playerGlass()
                .contentShape(Circle())
        }
        #if os(macOS)
        // The Mac draws a menu as a bordered button with an arrow unless told not to.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel("More")
    }
}
