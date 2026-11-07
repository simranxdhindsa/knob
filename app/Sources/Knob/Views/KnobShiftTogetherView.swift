import SwiftUI

/// Listen Together: start a session, join one nearby, then see who is listening and control the
/// music from any device.
struct KnobShiftTogetherView: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var session = KnobShiftTogetherSession.shared
    @Environment(\.dismiss) private var dismiss
    /// Where a drag on the seek bar has reached, 0...1, until the finger lifts.
    @State private var scrub: Double?
    /// Shown inside Play On's list, with no title or frame of its own.
    var embedded = false

    var body: some View {
        if embedded { ScrollView { running } } else { window }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Listen Together").font(.system(size: 20, weight: .bold)).foregroundStyle(Glass.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Glass.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if session.role == .off { start } else { ScrollView { running } }
            if let status = session.status {
                Text(status).font(.system(size: 13)).foregroundStyle(Glass.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 420)
        .background(Glass.scrim)
        .environment(\.surface, .glass)
        .onAppear { session.startLooking() }
        .onDisappear { session.stopLooking() }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Play the same music on your Mac and iPhones at the same moment, on the same Wi-Fi.")
                .font(.system(size: 13)).foregroundStyle(Glass.secondary).fixedSize(horizontal: false, vertical: true)
            wide("Start on this \(Platform.deviceName)", icon: "dot.radiowaves.left.and.right") { session.startHosting(model) }
            Text("NEARBY").font(.system(size: 11, weight: .bold)).foregroundStyle(Glass.tertiary).padding(.top, 8)
            if session.nearby.isEmpty {
                Text("Nobody is sharing yet. Start on another device, then join here.")
                    .font(.system(size: 13)).foregroundStyle(Glass.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.nearby) { nearby in
                row(nearby.name, action: "Join") { session.join(nearby, model: model) }
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.state?.title ?? "Nothing playing yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Glass.text).lineLimit(1)
                    Text(session.state?.artist ?? " ").font(.system(size: 13)).foregroundStyle(Glass.secondary).lineLimit(1)
                    Text(heading).font(.system(size: 12)).foregroundStyle(Palette.accent).lineLimit(1)
                }
            }
            seekBar
            HStack(spacing: 16) {
                control("shuffle", session.state?.isShuffled == true ? "Turn Shuffle Off" : "Shuffle", on: session.state?.isShuffled == true) { session.send(.shuffle) }
                Spacer()
                control("backward.fill", "Previous") { session.send(.previous) }
                control(session.state?.isPlaying == true ? "pause.fill" : "play.fill", session.state?.isPlaying == true ? "Pause" : "Play") { session.send(.playPause) }
                control("forward.fill", "Next") { session.send(.next) }
                Spacer()
                control("arrow.left.arrow.right", "KnobMix Now") { session.send(.mixNow) }
                    .disabled(session.state?.canMix != true)
                    .opacity(session.state?.canMix == true ? 1 : 0.4)
            }
            if let preset = session.presetName {
                Text("Preset: \(preset)").font(.system(size: 12)).foregroundStyle(Glass.secondary).lineLimit(1)
            }
            if isSharedSound { lineUp }
            if isSharedSound { Text(session.soundIsOff ? "Effects are shared. Turn Knob on here to hear them." : "Effects are shared. A change on any device reaches everyone.")
                .font(.system(size: 12)).foregroundStyle(Glass.tertiary).fixedSize(horizontal: false, vertical: true) }
            if session.role == .hosting {
                Text(session.people.isEmpty ? "Waiting for others to join." : "LISTENING").font(.system(size: 11, weight: .bold)).foregroundStyle(Glass.tertiary)
                ForEach(session.people, id: \.self) { name in row(name, action: "Remove") { session.remove(name) } }
            }
            if session.isRemote {
                wide("Bring Back Here", icon: "arrow.uturn.backward") { KnobShiftPlayOnSession.shared.bringBack() }
            } else if isSharedSound {
                wide(session.role == .hosting ? "End for Everyone" : "Leave", icon: "xmark.circle") { session.leave() }
            }
            if !session.queue.isEmpty {
                Text("QUEUE").font(.system(size: 11, weight: .bold)).foregroundStyle(Glass.tertiary)
                LazyVStack(spacing: 4) {
                    ForEach(session.queue) { song in queueRow(song) }
                }
            }
        }
    }

    private var seekBar: some View {
        let duration = max(session.state?.duration ?? 0, 0.001)
        let time = session.state?.time ?? 0
        let shown = scrub.map { $0 * duration } ?? time
        return VStack(spacing: 2) {
            KnobGroove(value: shown / duration, showsCap: true, accessibilityLabel: "Song position",
                       accessibilityValue: KnobShiftNowPlaying.clock(shown),
                       onChange: { scrub = $0 },
                       onEnd: {
                           if let scrub { session.send(.seek, time: scrub * duration) }
                           scrub = nil
                       })
            .disabled(session.state?.title == nil)
            HStack {
                Text(KnobShiftNowPlaying.clock(shown))
                Spacer()
                Text("-" + KnobShiftNowPlaying.clock(max(0, duration - shown)))
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Glass.secondary)
        }
    }

    private func queueRow(_ song: KnobShiftTogether.Song) -> some View {
        let playing = song.id == session.state?.song
        return Button { session.send(.pick, song: song.id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 14, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? Palette.accent : Glass.text).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.system(size: 12)).foregroundStyle(Glass.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Glass.fill, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "\(song.title), playing" : "Play \(song.title)")
    }

    /// Line up only matters when two devices play at once.
    private var isSharedSound: Bool {
        switch session.role {
        case .hosting, .listening: return true
        default: return false
        }
    }

    private var lineUp: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Line up").font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Spacer()
                Text("\(Int(session.lineUp * 1000)) ms").font(.system(size: 12).monospacedDigit()).foregroundStyle(Glass.secondary)
            }
            Slider(value: $session.lineUp, in: 0...0.4).tint(Palette.accent).accessibilityLabel("Line up")
            Text("If this device sounds late, as Bluetooth does, slide right until they match.")
                .font(.system(size: 12)).foregroundStyle(Glass.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heading: String {
        if case .listening(let name) = session.role { return "Listening to \(name)" }
        if case .remote(let name) = session.role { return "Playing on \(name)" }
        if case .playing(let name) = session.role { return "Moved here from \(name)" }
        let count = session.people.count
        return count == 0 ? "Sharing from this \(Platform.deviceName)" : "\(count) listening"
    }

    private var artwork: some View {
        Group {
            if let cover = session.cover {
                #if os(macOS)
                Image(nsImage: cover).resizable().scaledToFill()
                #else
                Image(uiImage: cover).resizable().scaledToFill()
                #endif
            } else {
                Image(systemName: "music.note").foregroundStyle(Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(Glass.fill)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private func control(_ icon: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(on ? Palette.accent : Glass.text).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func wide(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Glass.onAccent)
                .frame(maxWidth: .infinity, minHeight: 44).background(Palette.accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func row(_ name: String, action title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.system(size: 14)).foregroundStyle(Glass.text).lineLimit(1)
            Spacer()
            Button(title, action: action).buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .background(Glass.fill, in: RoundedRectangle(cornerRadius: 10))
    }
}
