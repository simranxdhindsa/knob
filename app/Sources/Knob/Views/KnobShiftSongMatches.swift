import SwiftUI

/// Under a song Knob could not find: its top YouTube matches, where one click loads the video into
/// Knob under that song, and the paste box for when the right one is not listed. The Mac only:
/// the iPhone cannot download.
struct KnobShiftSongMatches: View {
    @ObservedObject var model: KnobShiftModel
    let song: KnobShiftPlaylistSong
    var onDone: () -> Void
    /// Snapshots show fixed matches, or the loading rows, without searching.
    var preset: [KnobShiftYouTubeParsing.Match]? = nil
    var staysLoading = false

    @Environment(\.surface) private var surface
    @State private var matches: [KnobShiftYouTubeParsing.Match] = []
    @State private var searching = true
    @State private var problem: String?
    @State private var link = ""
    @State private var job: UUID?

    private static let widths: [CGFloat] = [0.55, 0.7, 0.48, 0.65, 0.58, 0.72]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if searching && preset == nil {
                ForEach(0..<3, id: \.self) { skeleton($0) }
            } else {
                ForEach(preset ?? matches) { row($0) }
            }
            if let problem {
                Text(problem).font(.system(size: 10)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LinkField(placeholder: "Or paste this song's YouTube link", text: $link, enabled: true,
                      pasteHelp: "Paste the link you copied on YouTube", addHelp: "Download this video for this song",
                      onPaste: { link = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
                      onAdd: { finish(model.useYouTubeLink(link, forSong: song.id)) })
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
        .task { await search() }
        .onDisappear { job.map(KnobShiftYouTube.shared.cancel) }
    }

    private func search() async {
        guard preset == nil, !staysLoading, searching else { return }
        // A fresh id each time: scrolled away and back, the last one is already cancelled.
        let id = UUID()
        job = id
        do {
            matches = try await KnobShiftYouTube.shared.matches(for: [song.artist, song.name].compactMap { $0 }.joined(separator: " "), id: id)
            if matches.isEmpty { problem = "YouTube found nothing for this song. Paste a link instead." }
        } catch is CancellationError {
            return
        } catch {
            problem = (error as? KnobShiftYouTubeParsing.Failure)?.message ?? "Could not search YouTube. Paste a link instead."
        }
        searching = false
    }

    private func finish(_ failure: String?) {
        problem = failure
        if failure == nil { onDone() }
    }

    private func row(_ match: KnobShiftYouTubeParsing.Match) -> some View {
        Button {
            Haptics.tick()
            finish(model.useYouTubeVideo(match.id, forSong: song.id))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(surface.text).lineLimit(1)
                    Text([match.channel, match.duration.map(KnobShiftNowPlaying.clock)].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 9.5)).foregroundStyle(surface.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(surface.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Load this video as \(song.name)")
        .accessibilityLabel("Load \(match.title)")
    }

    /// The same height as a match, with varied widths, while YouTube answers.
    private func skeleton(_ index: Int) -> some View {
        GeometryReader { size in
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(surface.tertiary.opacity(0.28)).frame(width: size.size.width * Self.widths[index % 6], height: 8)
                Capsule().fill(surface.tertiary.opacity(0.16)).frame(width: size.size.width * Self.widths[(index + 3) % 6] * 0.6, height: 6)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.leading, 30)
        }
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(surface.fill))
        .accessibilityHidden(true)
    }
}
