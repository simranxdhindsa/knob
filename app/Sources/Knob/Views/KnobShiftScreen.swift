import SwiftUI

/// KnobShift in Knob's sound-control panel. With nothing playing it is a title card that opens
/// the player; while music plays it becomes a mini player with the song, play/pause and the next
/// mix, so KnobShift can be followed without opening its window.
struct KnobShiftScreen: View {
    @ObservedObject var model: KnobShiftModel

    var body: some View {
        Group {
            if let track = model.nowPlaying {
                miniPlayer(track)
            } else {
                titleCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.gentle, value: model.nowPlaying?.id)
    }

    private var titleCard: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 2)
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Palette.accent)
                .shadow(color: Palette.accentGlow.opacity(0.55), radius: 10)
            VStack(spacing: 5) {
                Text("KNOBSHIFT")
                    .font(.system(size: 14, weight: .heavy)).tracking(2)
                    .foregroundStyle(Screen.text)
                Text("Seamless playing, with beat matched mixes for the music on your Mac.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Screen.textSecondary)
            }
            openButton(title: "OPEN PLAYER")
            Spacer(minLength: 2)
        }
    }

    private func miniPlayer(_ track: KnobShiftModel.Track) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AlbumArtwork(url: track.url, size: 56, lit: model.mixState == .mixing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Screen.text).lineLimit(1)
                    Text(track.artist ?? "Local music").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Screen.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.pauseOrResume() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.accent))
                        .shadow(color: Palette.accentGlow.opacity(0.55), radius: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            }
            status
            HStack {
                Spacer()
                openButton(title: "OPEN PLAYER")
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var status: some View {
        if let mix = model.nextMix, model.mixState != .mixing {
            HStack(spacing: 6) {
                Text("NEXT").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(Screen.textTertiary)
                Text(mix.next.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Screen.tabTrack))
        }
    }

    private func openButton(title: String) -> some View {
        Button {
            KnobShiftWindow.show(model: model)
        } label: {
            Label(title, systemImage: "music.note.list")
                .font(.system(size: 10, weight: .bold)).tracking(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Capsule().fill(Palette.accent))
                .shadow(color: Palette.accentGlow.opacity(0.55), radius: 6)
        }
        .buttonStyle(.plain)
    }
}
