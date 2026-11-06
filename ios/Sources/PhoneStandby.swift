import Combine
import SwiftUI
import UIKit

#if KNOB_STANDBY
import ActivityKit
import WidgetKit

/// Keeps the Live Activity (Lock Screen, StandBy and Dynamic Island) and the last song widget
/// true to the player. It watches the model the way Apple's player does (KnobShiftNowPlayingCenter).
///
/// iOS only lets an app start a Live Activity while it is on screen. So the card begins the
/// first time a song is playing with Knob open, or when Knob is next opened with a song loaded.
/// After that Knob updates it from the background (it plays audio there): song changes, pause
/// and play, and the bar's position when it jumps. The bar and the time left move on their own.
@MainActor
final class PhoneStandby {
    static let shared = PhoneStandby()

    private weak var model: KnobShiftModel?
    private var watching: Set<AnyCancellable> = []
    private var refresh: Timer?
    private var activity: Activity<KnobStandbyAttributes>?
    private var sent: KnobStandbyAttributes.ContentState?
    /// The song whose cover is in the shared folder, and that file's name.
    private var coverFor: URL?
    private var coverName: String?
    private var coverTask: Task<Void, Never>?
    private var generation = 0

    func start(model: KnobShiftModel) {
        guard self.model == nil else { return }
        self.model = model
        StandbyActions.handler = { [weak self] kind in self?.run(kind) }
        // A card left from an earlier run is ended: this run starts its own.
        Task { [weak self] in
            for old in Activity<KnobStandbyAttributes>.activities where old.id != self?.activity?.id {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }

        model.$nowPlaying.removeDuplicates { $0?.id == $1?.id }
            .combineLatest(model.$isPlaying.removeDuplicates())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &watching)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &watching)
        // A jump in the song (a move in the timeline, a mix) shows on the card within seconds.
        refresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func run(_ kind: StandbyActions.Kind) {
        guard let model else { return }
        switch kind {
        case .playPause: model.pauseOrResume()
        case .previous: model.previous()
        case .next: model.next()
        case .mix:
            if model.isPlaying, model.tracks.count > 1, model.mixState != .mixing { model.mixNow() }
        }
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    private func update() {
        guard let model else { return }
        guard let track = model.nowPlaying else {
            end()
            return
        }
        if coverFor != track.url {
            // The cover first, so the card never shows a new name over the old picture.
            coverFor = track.url
            coverName = nil
            generation += 1
            let mine = generation
            coverTask?.cancel()
            coverTask = Task { [weak self] in
                let name = await Self.saveCover(for: track.url)
                guard let self, self.generation == mine else { return }
                self.coverName = name
                self.saveLastSong(name: track.name, artist: track.artist, cover: name)
                self.push()
            }
            return
        }
        push()
    }

    private func push() {
        guard let model, let track = model.nowPlaying, coverFor == track.url else { return }
        let elapsed = min(max(model.playbackTime, 0), track.duration)
        let state = KnobStandbyAttributes.ContentState(
            title: Self.short(track.name), artist: track.artist.map(Self.short), isPlaying: model.isPlaying,
            started: Date().addingTimeInterval(-elapsed), duration: track.duration, elapsed: elapsed, cover: coverName,
            next: model.upNext.map { Self.short($0.name) }, mixing: model.mixState == .mixing || model.mixNowWaiting)
        if let sent, !Self.changed(sent, state) { return }
        // While paused the card holds still as long as it likes. It only goes out of date if the
        // song should have ended and Knob has gone, and a late update brings it back.
        let content = ActivityContent(state: state, staleDate: state.isPlaying ? state.ends.addingTimeInterval(90) : nil)
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            sent = state
            Task { await activity.update(content) }
        } else if UIApplication.shared.applicationState == .active {
            // Only allowed while Knob is on screen. Whatever is left of the last card goes first.
            if let old = activity {
                activity = nil
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            do {
                activity = try Activity.request(attributes: KnobStandbyAttributes(), content: content, pushType: nil)
                sent = state
                model.log("STANDBY", "Started the Live Activity for \(track.name).")
            } catch {
                model.log("STANDBY", "Live Activity not started: \(error.localizedDescription)")
            }
        }
    }

    /// A new song, a play or pause, a jump of more than a second, or a different cover.
    private static func changed(_ old: KnobStandbyAttributes.ContentState, _ new: KnobStandbyAttributes.ContentState) -> Bool {
        if old.title != new.title || old.artist != new.artist || old.isPlaying != new.isPlaying || old.cover != new.cover { return true }
        if old.next != new.next || old.mixing != new.mixing { return true }
        if new.isPlaying { return abs(old.started.timeIntervalSince(new.started)) > 1 }
        return abs(old.elapsed - new.elapsed) > 0.5
    }

    private func end() {
        sent = nil
        coverFor = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Words for the card: Apple allows 4 KB of state in all, so a long title is cut.
    private static func short(_ text: String) -> String { String(text.prefix(120)) }

    // MARK: The shared folder

    /// Saves the song's cover (or, for a song with none, the one KnobShift draws for it) small
    /// enough for the extension, under a new name, and removes the old ones.
    private static func saveCover(for url: URL) async -> String? {
        guard let folder = StandbyGroup.folder else { return nil }
        guard let image = await KnobShiftArtwork.load(url) ?? Self.drawnCover(for: url) else { return nil }
        let name = "cover-\(UInt32(truncatingIfNeeded: url.path.hashValue))-\(Int(Date().timeIntervalSince1970)).jpg"
        // Shrinking and writing happen off the main thread, so skipping through songs stays smooth.
        return await Task.detached(priority: .utility) { Self.write(image, as: name, in: folder) }.value
    }

    private nonisolated static func write(_ image: UIImage, as name: String, in folder: URL) -> String? {
        guard let data = shrunk(image).jpegData(compressionQuality: 0.82) else { return nil }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix("cover-") && old != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        return name
    }

    private static func drawnCover(for url: URL) -> UIImage? {
        let renderer = ImageRenderer(content: GeneratedArtwork(seed: url.deletingPathExtension().lastPathComponent).frame(width: 300, height: 300))
        renderer.scale = 1
        return renderer.uiImage
    }

    private nonisolated static func shrunk(_ image: UIImage) -> UIImage {
        let side: CGFloat = 360
        guard max(image.size.width, image.size.height) > side else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func saveLastSong(name: String, artist: String?, cover: String?) {
        guard let file = StandbyGroup.songFile,
              let data = try? JSONEncoder().encode(StandbySong(title: Self.short(name), artist: artist.map(Self.short), cover: cover)) else { return }
        try? data.write(to: file, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#else

/// A build without the StandBy extension (a real iPhone with no profile for it) has no card.
@MainActor
final class PhoneStandby {
    static let shared = PhoneStandby()
    func start(model: KnobShiftModel) {}
}

#endif
