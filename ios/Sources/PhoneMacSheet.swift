import SwiftUI

/// Add from Spotify, Add from YouTube and Sync on the iPhone, in one sheet. A pasted link goes to
/// Knob on the Mac, which downloads the songs (iPhone apps cannot run the download helpers), and
/// Sync brings every playlist the Mac has into the app (PhoneMacLink). Its songs join the queue
/// at once and fill in as they are copied.
struct PhoneMacSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case spotify, youtube, sync
        var id: String { rawValue }
        var title: String {
            switch self {
            case .spotify: return "Spotify"
            case .youtube: return "YouTube"
            case .sync: return "Sync"
            }
        }
    }

    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var link = PhoneMacLink.shared
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var text = ""
    @State private var declinedCount = KnobShiftSyncPlan.declined.count

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SegmentedTabs(options: Source.allCases, selection: $source, title: \.title)
                if source != .sync { linkForm }
                syncCard
                if let library = link.library, !library.playlists.isEmpty { playlists(library) }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                switch source {
                case .spotify: SpotifyMark().frame(width: 18, height: 18)
                case .youtube: YouTubeMark().frame(width: 20, height: 20)
                case .sync: Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
                }
            }
            Text(source == .sync ? "SYNC FROM YOUR MAC" : "ADD FROM \(source.title.uppercased())")
                .font(.system(size: 12, weight: .heavy)).tracking(1.4).foregroundStyle(Screen.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Screen.textSecondary)
                    .frame(width: 30, height: 30).background(Circle().fill(Screen.tabTrack))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinkField(placeholder: source == .spotify ? "Paste a Spotify playlist, album or song link" : "Paste a YouTube video, playlist or album link",
                      text: $text, enabled: !link.busy, pasteHelp: "Paste the copied link", addHelp: "Add these songs",
                      onPaste: { text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
                      onAdd: add)
            Text("Knob on your Mac downloads the songs and sends them to this iPhone over Wi-Fi, so keep it open on the same Wi-Fi. Keep only music you have the right to keep.")
                .font(.system(size: 11)).foregroundStyle(Screen.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        let pasted = text
        Task {
            await link.add(pasted, to: model)
            if !link.failed { text = "" }
        }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(Screen.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.macName ?? "Your Mac").font(.system(size: 13, weight: .semibold)).foregroundStyle(Screen.text)
                    Text("Spotify and YouTube playlists from Knob on your Mac")
                        .font(.system(size: 10)).foregroundStyle(Screen.textTertiary)
                }
                Spacer()
            }
            Button { Task { await link.sync(model) } } label: {
                HStack(spacing: 8) {
                    // Turned by the clock, not a repeating animation: a repeating animation also
                    // caught the label's width changes and slid the arrows from side to side.
                    TimelineView(.animation(paused: !link.busy)) { timeline in
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(link.busy ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 : 0))
                    }
                    .frame(width: 16, height: 16)
                    Text(syncLabel)
                }
                .transaction { $0.animation = nil }
                .font(.system(size: 12, weight: .bold)).tracking(0.8).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Capsule().fill(link.busy ? Screen.textTertiary.opacity(0.5) : Palette.accent))
                .shadow(color: Palette.accentGlow.opacity(link.busy ? 0 : 0.35), radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(link.busy)
            .accessibilityHint("Copies the playlists your Mac has to this iPhone")
            if link.phase == .syncing, link.toCopy > 0 {
                ProgressView(value: Double(link.copied), total: Double(link.toCopy)).tint(Palette.accent)
            }
            if let status = link.status {
                Text(status).font(.system(size: 11)).foregroundStyle(link.failed ? Palette.accent : Screen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if declinedCount > 0 {
                Button {
                    KnobShiftSyncPlan.forgetDeclined()
                    declinedCount = 0
                } label: {
                    Text("Bring back \(declinedCount == 1 ? "1 song" : "\(declinedCount) songs") you took out, on the next sync")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Screen.tabTrack))
    }

    private var syncLabel: String {
        switch link.phase {
        case .idle: return "SYNC FROM MAC"
        case .looking: return "LOOKING FOR YOUR MAC"
        case .adding: return "YOUR MAC IS READING"
        case .syncing: return link.toCopy > 0 ? "COPYING \(link.copied) OF \(link.toCopy)" : "SYNCING"
        }
    }

    private func playlists(_ library: KnobShiftLink.Library) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ON YOUR MAC").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Screen.textTertiary)
            ForEach(library.playlists, id: \.playlist.id) { entry in
                PhoneMacPlaylistRow(entry: entry, here: here(entry))
            }
        }
    }

    /// Songs of a playlist already in this iPhone's folder for it.
    private func here(_ entry: KnobShiftLink.Library.Entry) -> Int {
        guard let playlist = model.playlists.first(where: { $0.id == entry.playlist.id }) else { return 0 }
        let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
        return entry.songs.filter { files[$0.id] != nil }.count
    }
}

/// One of the Mac's playlists: where it is from, its name, and how many of its songs are here.
struct PhoneMacPlaylistRow: View {
    let entry: KnobShiftLink.Library.Entry
    let here: Int

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if entry.playlist.source == .youtube { YouTubeMark().frame(width: 18, height: 18) }
                else { SpotifyMark().frame(width: 16, height: 16) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.playlist.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Screen.text).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(Screen.textTertiary)
            }
            Spacer()
            if here >= entry.songs.count, !entry.songs.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).accessibilityLabel("All on this iPhone")
            }
        }
        .padding(.vertical, 6)
    }

    private var detail: String {
        let total = entry.songs.count
        var text = "\(here) of \(total) song\(total == 1 ? "" : "s") on this iPhone"
        if entry.downloading { text += ", more downloading on your Mac" }
        return text
    }
}
