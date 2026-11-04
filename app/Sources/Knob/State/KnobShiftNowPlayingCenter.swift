import Combine
import Foundation
import MediaPlayer

/// KnobShift in Apple's own player: the iPhone's lock screen, Control Center and Dynamic Island,
/// headphone and CarPlay buttons, and the Mac's Now Playing and play keys. It shows the song's
/// name, artist and cover with a moving progress bar, and answers play, pause, previous, a
/// dragged position, and next, which here is KnobMix: a beat matched mix into the next song,
/// like KnobMix Now in the player, never a hard cut. Apple's player has no room for buttons of
/// an app's own, so next is where KnobMix lives.
@MainActor
final class KnobShiftNowPlayingCenter {
    static let shared = KnobShiftNowPlayingCenter()

    private weak var model: KnobShiftModel?
    private var watching: Set<AnyCancellable> = []
    private var refresh: Timer?
    /// The song whose cover is shown, so it is read once per song.
    private var artworkFor: URL?
    private var artwork: MPMediaItemArtwork?

    func start(model: KnobShiftModel) {
        guard self.model == nil else { return }
        self.model = model
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.run { if !$0.isPlaying { $0.pauseOrResume() } } ?? .commandFailed }
        commands.pauseCommand.addTarget { [weak self] _ in self?.run { if $0.isPlaying { $0.pauseOrResume() } } ?? .commandFailed }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.pauseOrResume() } ?? .commandFailed }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.previous() } ?? .commandFailed }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.run { model in
                // KnobMix: mixed in on the next phrase while playing; a plain step when paused.
                if model.isPlaying, model.tracks.count > 1 {
                    model.log("TRANSPORT", "KnobMix from Apple's player.")
                    model.mixNow()
                } else {
                    model.next()
                }
            } ?? .commandFailed
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.run { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
        for command in [commands.skipForwardCommand, commands.skipBackwardCommand, commands.seekForwardCommand,
                        commands.seekBackwardCommand, commands.changeRepeatModeCommand, commands.changeShuffleModeCommand] {
            command.isEnabled = false
        }

        model.$nowPlaying.removeDuplicates { $0?.id == $1?.id }
            .combineLatest(model.$isPlaying.removeDuplicates())
            .sink { [weak self] _ in
                // Published before the change lands: read the model once it has.
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &watching)
        // The position is kept true while playing (a move in the app's own timeline, a mix).
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.isPlaying == true else { return }
                self.update()
            }
        }
    }

    private func run(_ action: (KnobShiftModel) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let model else { return .commandFailed }
        if model.tracks.isEmpty { return .noActionableNowPlayingItem }
        action(model)
        DispatchQueue.main.async { [weak self] in self?.update() }
        return .success
    }

    /// What Apple's player shows: the song, its place and whether it is moving.
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let model, let track = model.nowPlaying else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.playbackTime,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyAlbumTitle: "KnobShift",
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if artworkFor == track.url, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = model.isPlaying ? .playing : .paused
        #endif
        guard artworkFor != track.url else { return }
        model.log("NOW PLAYING", "Apple's player shows \(track.name)\(track.artist.map { " by \($0)" } ?? "").")
        artworkFor = track.url
        artwork = nil
        Task { [weak self] in
            guard let image = await KnobShiftArtwork.load(track.url), let self, self.artworkFor == track.url else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.update()
        }
    }
}
