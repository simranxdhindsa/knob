import AppKit
import SwiftUI

/// Renders the panel offscreen with the demo engine, in light and dark, to PNG files.
/// Used for visual checks: `Knob --snapshot DIR` writes panel-light.png and panel-dark.png.
@MainActor
enum Snapshot {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let songs = ProcessInfo.processInfo.environment["KNOB_SNAPSHOT_SONGS"] {
            Task { @MainActor in
                await realPlayerShots(of: URL(fileURLWithPath: songs), into: folder)
                exit(0)
            }
            app.run()
            return
        }

        let model = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        model.start()
        let presets = Preset.factory()
        if let preset = presets.first(where: { $0.name == "Music" }) ?? presets.first {
            model.select(preset)
        }
        Task { @MainActor in
            await model.refresh()
            model.panelOpened()
            try? await Task.sleep(for: .milliseconds(900))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for tab in ScreenSection.Tab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: PersistKey.selectedTab.rawValue)
                    render(PanelView(model: model).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("panel-\(name)-\(tab.rawValue).png"))
                }
            }
            // KnobShift's tab as a mini player, playing and mid-mix.
            UserDefaults.standard.set(ScreenSection.Tab.knobShift.rawValue, forKey: PersistKey.selectedTab.rawValue)
            for mixing in [false, true] {
                model.knobShift.showPreviewForSnapshot(mixing: mixing)
                for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    render(PanelView(model: model).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("panel-\(name)-knobShift-\(mixing ? "mixing" : "playing").png"))
                }
            }
            model.knobShift.stop()

            // KnobShift is a separate, resizable player. Render its two responsive breakpoints.
            // Both sizes, light and dark, playing and mid-mix.
            for mixing in [false, true] {
                let shift = KnobShiftModel(restoresQueue: false)
                shift.showPreviewForSnapshot(mixing: mixing)
                for (name, size) in playerSizes {
                    // Full screen is only ever dark: the player's window always is.
                    for (schemeName, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)]
                    where !name.hasPrefix("fullscreen") || scheme == .dark {
                        render(KnobShiftPlayerView(model: shift)
                            .frame(width: size.width, height: size.height)
                            .environment(\.colorScheme, scheme), scheme: scheme,
                               to: folder.appendingPathComponent("knobshift-\(name)-\(schemeName)\(mixing ? "-mixing" : "").png"))
                    }
                }
            }
            // The Playlists view and one playlist opened, from sample songs in a scratch folder.
            let library = sampleLibrary()
            for (schemeName, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                render(KnobShiftPlaylistsView(model: library).padding(14).frame(width: 360, height: 300)
                    .background(SurfaceBackground(radius: 16)).padding(12).background(Palette.of(scheme).panelBottom)
                    .environment(\.surface, .glass).environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("knobshift-playlists-\(schemeName).png"))
                render(KnobShiftPlaylistDetail(model: library, playlist: library.playlists[0], onBack: {}).padding(14).frame(width: 360, height: 420)
                    .background(SurfaceBackground(radius: 16)).padding(12).background(Palette.of(scheme).panelBottom)
                    .environment(\.surface, .glass).environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("knobshift-playlist-\(schemeName).png"))
                let sample = KnobShiftPlaylistSong(id: "sample", name: "Zindagi", artist: "Sucha Yaar", state: .failed("Not found"))
                let found: [KnobShiftYouTubeParsing.Match] = [
                    .init(id: "aaaaaaaaaaa", title: "Zindagi (Official Audio) Sucha Yaar", channel: "Sucha Yaar", duration: 214),
                    .init(id: "bbbbbbbbbbb", title: "Zindagi | Sucha Yaar | New Punjabi Song", channel: "Punjabi Hits", duration: 221)]
                for (name, preset) in [("matches", Optional(found)), ("matches-loading", nil)] {
                    render(KnobShiftSongMatches(model: library, song: sample, onDone: {}, preset: preset, staysLoading: preset == nil).padding(14).frame(width: 360, height: 300, alignment: .top)
                        .background(SurfaceBackground(radius: 16)).padding(12).background(Palette.of(scheme).panelBottom)
                        .environment(\.surface, .glass).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("knobshift-\(name)-\(schemeName).png"))
                }
                render(KnobShiftPlaylistDetail(model: library, playlist: nil, onBack: {}).padding(14).frame(width: 360, height: 300)
                    .background(SurfaceBackground(radius: 16)).padding(12).background(Palette.of(scheme).panelBottom)
                    .environment(\.surface, .glass).environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("knobshift-allsongs-\(schemeName).png"))
            }
            // The Spotify sheet: its one time notice, and the form logged in with a status line.
            let spotify = KnobShiftModel(restoresQueue: false)
            spotify.showSpotifyPreviewForSnapshot()
            for (name, form) in [("notice", false), ("form", true)] {
                render(KnobShiftSpotifySheet(model: spotify, showsForm: form).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("knobshift-spotify-\(name).png"))
            }
            spotify.showSpotifyPickerForSnapshot()
            render(KnobShiftSpotifySheet(model: spotify, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-spotify-picker.png"))
            // The YouTube sheet: its one time notice, the form signed out and signed in, and the picker.
            let youtube = KnobShiftModel(restoresQueue: false)
            for (name, form) in [("notice", false), ("form", true)] {
                render(KnobShiftYouTubeSheet(model: youtube, showsForm: form).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("knobshift-youtube-\(name).png"))
            }
            render(KnobShiftGoogleKey(model: youtube, startsOpen: true).padding(22).frame(width: 460)
                    .background(Screen.bottom).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-key.png"))
            youtube.showYouTubeCodeForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-code.png"))
            youtube.showYouTubeLoadingForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-loading.png"))
            youtube.showYouTubePreviewForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-signedin.png"))
            youtube.showYouTubePickerForSnapshot()
            render(KnobShiftYouTubeSheet(model: youtube, showsForm: true).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-youtube-picker.png"))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                render(HeaderBar(model: model).knobMenu.padding(16).background(Palette.of(scheme).panelBottom)
                        .environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("knob-menu-\(name).png"))
            }
            render(KnobShiftAddMusicCard(onMac: {}, onSpotify: {}).padding(16)
                    .background(Screen.bottom).environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-add-music.png"))
            render(KnobShiftSpotifyKey(model: spotify, startsOpen: true).padding(22).frame(width: 460)
                    .background(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom))
                    .environment(\.colorScheme, .dark), scheme: .dark,
                   to: folder.appendingPathComponent("knobshift-spotify-key.png"))
            model.panelClosed()

            // Engine off: what the panel looks like before the engine is installed or running.
            let offline = KnobModel(engine: SocketEngine(path: "/nonexistent/knob-engine.sock"), volume: DemoVolume())
            offline.start()
            await offline.refresh()
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for tab in ScreenSection.Tab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: PersistKey.selectedTab.rawValue)
                    render(PanelView(model: offline).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("offline-\(name)-\(tab.rawValue).png"))
                }
            }

            // Recovery messages and actions must fit alongside the real panel layout.
            for failure in StartupFailure.allCases {
                offline.showStartupFailure(failure)
                UserDefaults.standard.set(ScreenSection.Tab.effects.rawValue, forKey: PersistKey.selectedTab.rawValue)
                for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    render(PanelView(model: offline).environment(\.colorScheme, scheme), scheme: scheme,
                           to: folder.appendingPathComponent("recovery-\(failure)-\(name).png"))
                }
            }

            // Pressing ON with the engine off: the real launcher's checks, never a silent no-op.
            // (Runs the real device check; it only launches anything if Knob's device is installed.)
            let attempt = KnobModel(engine: SocketEngine(path: "/nonexistent/knob-engine.sock"), volume: DemoVolume(),
                                    launcher: EngineLauncher())
            attempt.start()
            await attempt.refresh()
            if !HardwareDevices.all().contains(where: { $0.uid == HardwareDevices.knobUID }) {
                attempt.setPower(true)
                try? await Task.sleep(for: .milliseconds(500))
                print("power-on notice: \(attempt.notice ?? "none")")
                UserDefaults.standard.set(ScreenSection.Tab.effects.rawValue, forKey: PersistKey.selectedTab.rawValue)
                render(PanelView(model: attempt).environment(\.colorScheme, .dark), scheme: .dark,
                       to: folder.appendingPathComponent("power-attempt-dark.png"))
            }
            exit(0)
        }
        app.run()
    }

    /// `Knob --icons DIR`: the app icon at 1024px, the installer background, and the About window in light and dark.
    static func renderArtwork(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            render(AppIconView(size: 1024), scheme: .dark, to: folder.appendingPathComponent("icon-1024.png"))
            render(AppIconView(size: 1024, fullBleed: true), scheme: .dark, to: folder.appendingPathComponent("icon-ios-1024.png"))
            // The iPhone launch image: the opening's first frame, at 2x and 3x (renders are 2x).
            render(LaunchKnobPose(value: 0.68, size: 220), scheme: .dark, to: folder.appendingPathComponent("launch-knob@2x.png"))
            render(LaunchKnobPose(value: 0.68, size: 330), scheme: .dark, to: folder.appendingPathComponent("launch-knob@3x.png"))
            render(LaunchKnobPose(value: 0.68, size: 220, scheme: .light), scheme: .light, to: folder.appendingPathComponent("launch-knob-light@2x.png"))
            render(LaunchKnobPose(value: 0.68, size: 330, scheme: .light), scheme: .light, to: folder.appendingPathComponent("launch-knob-light@3x.png"))
            render(InstallerBackgroundView(), scheme: .light, to: folder.appendingPathComponent("installer-background.png"))
            let statuses: [(String, UpdateStatus)] = [("checking", .checking), ("downloading", .downloading(progress: nil)),
                                                     ("installing", .installing), ("uptodate", .upToDate),
                                                     ("failed", .failed(message: "Couldn't update Knob. It will try again later."))]
            for (name, status) in statuses {
                render(UpdateStatusLabel(status: status).padding(8).background(Palette.dark.panelTop)
                        .environment(\.colorScheme, .dark),
                       scheme: .dark, to: folder.appendingPathComponent("update-\(name).png"))
            }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                render(AboutView().environment(\.colorScheme, scheme), scheme: scheme,
                       to: folder.appendingPathComponent("about-\(name).png"))
            }
            exit(0)
        }
        app.run()
    }

    /// Two playlists for the Playlists snapshots: three songs downloaded, one on its way and one
    /// not found, in a scratch folder that KNOB_SPOTIFY_ROOT points the playlists at.
    @MainActor
    private static func sampleLibrary() -> KnobShiftModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knob-snapshot-playlists/Spotify")
        setenv("KNOB_SPOTIFY_ROOT", root.path, 1)
        let ids = ["7gBjvaMxE92ezPBMljMAcq", "5tEdOJbKBTR8vibjz1cHTF", "2uBAFvIOvyOm4Glz7LwehN", "0lfiPRY2oD5cj4z4xG3DTL", "26pvjgrXe1GDLHWAZ6VNFE"]
        let road = KnobShiftPlaylist(id: "demoroad", name: "Punjabi Road Trip", link: "", kind: .playlist,
                                     folderName: "Punjabi Road Trip", spotifyOrder: ids, addedAt: Date())
        let liked = KnobShiftPlaylist(id: "liked", name: "Liked Songs", link: "saved", kind: .liked,
                                      folderName: "Liked Songs", spotifyOrder: [], addedAt: Date())
        let folder = KnobShiftPlaylists.folder(for: road)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["Do Gallan - Garry Sandhu", "Ghostface Killah - Sidhu Moose Wala", "No Luck - TEJAY, K28"].enumerated() {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("\(index + 1) \(name) [\(ids[index])].m4a").path, contents: Data())
        }
        let model = KnobShiftModel(restoresQueue: false)
        model.playlists = [road, liked]
        var coming = KnobShiftModel.PendingSong(url: folder.appendingPathComponent("\(ids[3]).pending"))
        coming.spotifyId = ids[3]
        coming.playlistId = road.id
        coming.spotifyName = "Sardaari"
        coming.spotifyArtist = "Himmat Sandhu"
        coming.waitingForDownload = true
        coming.joinsQueue = false
        coming.stage = "Downloading"
        var missing = coming
        missing.spotifyId = ids[4]
        missing.spotifyName = "Zindagi"
        missing.spotifyArtist = "Prem Dhillon"
        missing.stage = nil
        missing.failure = "Not found"
        model.pending = [coming, missing]
        return model
    }

    /// The player's two windows, then full screen as it really is on a 13 inch and a 14 inch
    /// MacBook, both under the notch, and on a 27 inch monitor.
    private static let playerSizes: [(String, CGSize)] = [
        ("compact", CGSize(width: 460, height: 720)), ("wide", CGSize(width: 900, height: 620)),
        ("fullscreen-13in", CGSize(width: 1470, height: 919)), ("fullscreen-14in", CGSize(width: 1710, height: 1074)),
        ("fullscreen-27in", CGSize(width: 2560, height: 1440)),
    ]

    /// KNOB_SNAPSHOT_SONGS names a folder of songs: instead of the usual set, the player alone is
    /// drawn with their real covers, in a long queue with the middle one playing. Covers load in
    /// the background, so this waits for them in a window shown well off every screen.
    private static func realPlayerShots(of songs: URL, into folder: URL) async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: songs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }.sorted { $0.path < $1.path }
        guard files.count >= 2 else { print("No songs in \(songs.path)"); return }
        for mixing in [false, true] {
            let shift = KnobShiftModel(restoresQueue: false)
            shift.showPreviewForSnapshot(mixing: mixing)
            let analysis = shift.tracks[0].analysis
            shift.tracks = files.map {
                KnobShiftModel.Track(url: $0, title: $0.deletingPathExtension().lastPathComponent, duration: 215, tailSilence: 1, analysis: analysis)
            }
            let playing = files.count / 2
            let next = shift.tracks[(playing + 1) % files.count]
            shift.currentIndex = playing
            shift.nowPlaying = shift.tracks[playing]
            shift.nextMix = KnobShiftModel.NextMix(next: next, startsAt: 114.4, endsAt: 124.1, at: Date().addingTimeInterval(mixing ? 0 : 50), blends: true)
            shift.mixingInto = mixing ? next : nil
            for (name, size) in playerSizes {
                let (host, window) = hosted(KnobShiftPlayerView(model: shift).frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .dark), scheme: .dark)
                window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
                window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(4))
                save(host, to: folder.appendingPathComponent("knobshift-\(name)-real\(mixing ? "-mixing" : "").png"))
                window.orderOut(nil)
            }
        }
        await selectionShot(of: files, into: folder)
        await vinylShots(of: files, into: folder)
    }

    /// The record deck, settled, on an iPhone on its side and on the Mac in full screen.
    private static func vinylShots(of files: [URL], into folder: URL) async {
        let shift = KnobShiftModel(restoresQueue: false)
        shift.showPreviewForSnapshot(mixing: false)
        let analysis = shift.tracks[0].analysis
        shift.tracks = files.map {
            KnobShiftModel.Track(url: $0, title: $0.deletingPathExtension().lastPathComponent, duration: 215, tailSilence: 1, analysis: analysis)
        }
        shift.currentIndex = 1
        shift.nowPlaying = shift.tracks[1]
        shift.nextMix = nil
        let key = PersistKey.knobShiftVinyl.rawValue
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let (phone, phoneWindow) = hosted(VinylStage(model: shift, size: CGSize(width: 590, height: 369)).environment(\.surface, .glass)
            .background(Vinyl.base).frame(width: 590, height: 369).environment(\.colorScheme, .dark), scheme: .dark)
        phoneWindow.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        phoneWindow.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(5))
        save(phone, to: folder.appendingPathComponent("vinyl-phone.png"))
        phoneWindow.orderOut(nil)
        let (mac, macWindow) = hosted(KnobShiftPlayerView(model: shift).frame(width: 1710, height: 1074).environment(\.colorScheme, .dark), scheme: .dark)
        macWindow.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        macWindow.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(5))
        save(mac, to: folder.appendingPathComponent("vinyl-mac.png"))
        macWindow.orderOut(nil)
    }

    /// Selects rows through the real list, the way a click does, beside the playing row, and
    /// says whether the system's highlight stayed off.
    private static func selectionShot(of files: [URL], into folder: URL) async {
        let shift = KnobShiftModel(restoresQueue: false)
        shift.showPreviewForSnapshot(mixing: false)
        let analysis = shift.tracks[0].analysis
        shift.tracks = files.map {
            KnobShiftModel.Track(url: $0, title: $0.deletingPathExtension().lastPathComponent, duration: 215, tailSilence: 1, analysis: analysis)
        }
        shift.currentIndex = 1
        shift.nowPlaying = shift.tracks[1]
        let (host, window) = hosted(KnobShiftPlayerView(model: shift).frame(width: 1710, height: 1074).environment(\.colorScheme, .dark), scheme: .dark)
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(3))
        guard let table = findTable(in: host) else { print("selection: no table found"); return }
        for rows in [IndexSet(integer: 3), IndexSet([3, 4])] {
            table.selectRowIndexes(rows, byExtendingSelection: false)
            try? await Task.sleep(for: .seconds(1))
            print("selection: rows \(rows.count), highlight style \(table.selectionHighlightStyle.rawValue), selected \(table.selectedRowIndexes.count)")
        }
        save(host, to: folder.appendingPathComponent("knobshift-selected-real.png"))
        window.orderOut(nil)
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        (view as? NSTableView) ?? view.subviews.lazy.compactMap(findTable).first
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let (host, _) = hosted(view, scheme: scheme)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        save(host, to: url)
    }

    private static func hosted<V: View>(_ view: V, scheme: ColorScheme) -> (NSHostingView<V>, NSWindow) {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private static func save(_ host: NSView, to url: URL) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
