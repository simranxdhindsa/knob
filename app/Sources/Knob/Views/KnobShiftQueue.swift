import SwiftUI

/// What plays next and when it mixes in, counted down live.
struct KnobShiftUpNext: View {
    @ObservedObject var model: KnobShiftModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UP NEXT").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(Screen.textTertiary)
            if let mix = model.nextMix {
                HStack(spacing: 12) {
                    AlbumArtwork(url: mix.next.url, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mix.next.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                        if let artist = mix.next.artist {
                            Text(artist).font(.system(size: 11)).foregroundStyle(Screen.textSecondary).lineLimit(1)
                        }
                        countdown(mix)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text(model.tracks.count > 1 ? "Play a song to see its next mix." : "Add another song and KnobShift mixes into it.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Screen.textSecondary)
            }
        }
        .screenCard(radius: 16, padding: 14)
    }

    /// "Mixing now" while the mix plays; no times are shown.
    @ViewBuilder private func countdown(_ mix: KnobShiftModel.NextMix) -> some View {
        if model.mixState == .mixing {
            Text("Mixing now").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
        }
    }
}

/// The queue: every song with its cover, tempo and length; the playing one highlighted.
struct KnobShiftQueue: View {
    @ObservedObject var model: KnobShiftModel
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("QUEUE").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(Screen.textTertiary)
                if !model.tracks.isEmpty || !model.pending.isEmpty {
                    Text("\(model.tracks.count + model.pending.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(Screen.textTertiary)
                }
                Spacer()
                Button(action: onAdd) {
                    Label("ADD MUSIC", systemImage: "plus")
                        .font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            if model.tracks.isEmpty && model.pending.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.tracks) { track in row(track) }
                        ForEach(model.pending) { song in pendingRow(song) }
                    }
                }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(Palette.accent).lineLimit(2)
            }
        }
        .screenCard(radius: 16, padding: 14)
    }

    private func row(_ track: KnobShiftModel.Track) -> some View {
        let playing = model.nowPlaying == track
        return HStack(spacing: 10) {
            AlbumArtwork(url: track.url, size: 34, lit: playing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.system(size: 12, weight: playing ? .bold : .medium))
                    .foregroundStyle(playing ? Palette.accent : Screen.text).lineLimit(1)
                Text([track.artist, track.analysis.tempo.map { String(format: "%.0f BPM", $0) }].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(Screen.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(KnobShiftNowPlaying.clock(track.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Screen.textTertiary)
            Button { model.remove(track) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Screen.textTertiary)
                .accessibilityLabel("Remove \(track.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(playing ? Palette.accent.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(track) }
    }

    /// A song still being prepared: its ring fills as the analysis moves on; a failed song
    /// offers Retry.
    private func pendingRow(_ song: KnobShiftModel.PendingSong) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Screen.grid)
                if song.failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(Palette.accent)
                } else {
                    PreparingRing(progress: song.progress, active: song.isActive)
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(song.failure == nil ? Screen.textSecondary : Screen.text).lineLimit(1)
                Text([song.artist, song.failure ?? (song.isActive ? "Preparing \(Int(song.progress * 100))%" : "Waiting to prepare")]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(song.failure == nil ? Screen.textTertiary : Palette.accent).lineLimit(1)
            }
            Spacer(minLength: 4)
            if song.failure != nil {
                Button("Retry") { model.retry(song) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
            }
            Button { model.removePending(song) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Screen.textTertiary)
                .accessibilityLabel("Remove \(song.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 24)).foregroundStyle(Palette.accent.opacity(0.85))
            Text("Add songs from your Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(Screen.text)
            Text("KnobShift mixes them into each other like a DJ. Apple Music, Spotify and YouTube stay in their own apps.")
                .font(.system(size: 10)).foregroundStyle(Screen.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// A small progress ring for a song being prepared: a faint track, the filled share in orange,
/// and nothing filled while the song waits its turn.
struct PreparingRing: View {
    let progress: Double
    let active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Screen.textTertiary.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: active ? max(0.04, min(progress, 1)) : 0)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.accentGlow.opacity(0.6), radius: 2)
        }
        .frame(width: 18, height: 18)
        .animation(Motion.gentle, value: progress)
        .accessibilityLabel(active ? "Preparing, \(Int(progress * 100)) percent" : "Waiting to prepare")
    }
}
