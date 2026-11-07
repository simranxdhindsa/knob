import AVFoundation
import SwiftUI

/// Knob on the iPhone: the KnobShift player for songs imported into the app, with Knob's sound
/// controls (power, presets, effects and equalizer) a tap away. Everything KnobShift plays goes
/// through Knob's sound.
@main
struct KnobPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @StateObject private var app = PhoneApp()

    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: app.model)
                .focusEffectDisabled()
        }
    }
}

/// Builds the app's parts once: Knob's engine, the panel model and Knob's sound after the mix.
@MainActor
final class PhoneApp: ObservableObject {
    let engine = PhoneEngine()
    let volume = PhoneVolume()
    let model: KnobModel

    init() {
        model = KnobModel(engine: engine, volume: volume)
        volume.shift = model.knobShift
        let model = model, engine = engine
        Task {
            // After the first frame, so the opening shows at once.
            Self.playInBackground()
            // The lock screen, Control Center and headphone buttons.
            KnobShiftNowPlayingCenter.shared.start(model: model.knobShift)
            // The Live Activity for the Lock Screen and StandBy (when this build carries it).
            PhoneStandby.shared.start(model: model.knobShift)
            do {
                model.knobShift.insertOutputEffect(try await PhoneEffectUnit.make(for: engine))
            } catch {
                model.knobShift.log("SESSION", "Knob's sound could not be added: \(error.localizedDescription)")
            }
            model.start()
            model.restorePower()
            KnobShiftPlayOnSession.shared.start(model: model.knobShift)
            #if DEBUG
            await Self.runChecks(model)
            #endif
        }
    }

    #if DEBUG
    /// KNOB_PHONE_SWAP=n turns the phone on its side after n seconds, then changes song every way
    /// there is, so the record's change can be timed: next, previous, three quick nexts, a KnobMix.
    /// KNOB_PHONE_UX=n walks the deck the way a person would, marking each moment in the log so
    /// the phone's screen can be photographed there: a change, a pause, a change while paused.
    private static func uxCheck(_ shift: KnobShiftModel, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        try? await Task.sleep(for: .seconds(4))
        shift.log("VINYL", "MARK playing")
        try? await Task.sleep(for: .seconds(5))
        shift.log("VINYL", "MARK change")
        shift.next()
        try? await Task.sleep(for: .seconds(3.5))
        shift.log("VINYL", "MARK after change")
        try? await Task.sleep(for: .seconds(1.5))
        shift.pauseOrResume()
        try? await Task.sleep(for: .seconds(1))
        shift.log("VINYL", "MARK paused, playing is \(shift.isPlaying)")
        try? await Task.sleep(for: .seconds(1.5))
        shift.next()
        try? await Task.sleep(for: .seconds(3.5))
        shift.log("VINYL", "MARK changed while paused, playing is \(shift.isPlaying)")
        try? await Task.sleep(for: .seconds(1.5))
        shift.log("VINYL", "MARK end")
    }

    /// KNOB_PHONE_TIPS=n walks the guide from the start, marking each tip so it can be photographed.
    private static func tipsCheck(_ shift: KnobShiftModel, after seconds: Double) async {
        let key = PersistKey.knobShiftTipsSeen.rawValue
        UserDefaults.standard.removeObject(forKey: key)
        try? await Task.sleep(for: .seconds(seconds))
        shift.log("VINYL", "MARK tip turn")
        try? await Task.sleep(for: .seconds(1.5))
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        try? await Task.sleep(for: .seconds(4.5))
        shift.log("VINYL", "MARK tip record, seen \(UserDefaults.standard.string(forKey: key) ?? "nothing")")
        try? await Task.sleep(for: .seconds(1.5))
        for (name, seen) in [("arm", "turn,record"), ("cover", "turn,record,arm")] {
            UserDefaults.standard.set(seen, forKey: key)
            try? await Task.sleep(for: .seconds(1.5))
            shift.log("VINYL", "MARK tip \(name)")
            try? await Task.sleep(for: .seconds(1.5))
        }
        UserDefaults.standard.set("turn,record,arm,cover", forKey: key)
        try? await Task.sleep(for: .seconds(1.5))
        shift.log("VINYL", "MARK tip none")
        try? await Task.sleep(for: .seconds(1.5))
        PhoneCharger.shared.pretend(plugged: true, percent: 82)
        try? await Task.sleep(for: .seconds(3))
        shift.log("VINYL", "MARK tip bedside")
        try? await Task.sleep(for: .seconds(1.5))
        PhoneCharger.shared.tapClock()
        try? await Task.sleep(for: .seconds(1.5))
        shift.log("VINYL", "MARK tip end, seen \(UserDefaults.standard.string(forKey: key) ?? "nothing")")
    }

    /// KNOB_PHONE_BEDSIDE=n turns the phone on its side after n seconds, plugs it in and walks
    /// Bedside mode, marking each moment so the screen can be photographed there.
    /// KNOB_PHONE_BEDSIDE_TIME=21:05 shows that time on the clock.
    private static func bedsideCheck(_ shift: KnobShiftModel, after seconds: Double) async {
        let key = PersistKey.knobShiftBedside.rawValue
        if let parts = ProcessInfo.processInfo.environment["KNOB_PHONE_BEDSIDE_TIME"]?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 {
            PhoneCharger.checkTime = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
        }
        func mark(_ text: String) {
            shift.log("VINYL", "MARK \(text), screen stays on is \(UIApplication.shared.isIdleTimerDisabled)")
        }
        try? await Task.sleep(for: .seconds(seconds))
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        try? await Task.sleep(for: .seconds(4))
        mark("deck")
        try? await Task.sleep(for: .seconds(2.5))
        PhoneCharger.shared.pretend(plugged: true, percent: 82)
        try? await Task.sleep(for: .seconds(3))
        mark("bedside")
        try? await Task.sleep(for: .seconds(1.5))
        shift.next()
        try? await Task.sleep(for: .seconds(3.5))
        mark("bedside after change")
        try? await Task.sleep(for: .seconds(1.5))
        shift.pauseOrResume()
        try? await Task.sleep(for: .seconds(1.5))
        mark("bedside paused")
        try? await Task.sleep(for: .seconds(1.5))
        shift.pauseOrResume()
        for _ in shift.tracks where (shift.nowPlaying?.name.count ?? 0) < 30 {
            shift.next()
            try? await Task.sleep(for: .seconds(3))
        }
        mark("long title")
        try? await Task.sleep(for: .seconds(1.5))
        mark("tapping")
        try? await Task.sleep(for: .seconds(1))
        PhoneCharger.shared.tapClock()
        try? await Task.sleep(for: .seconds(1.5))
        mark("controls up")
        try? await Task.sleep(for: .seconds(6.5))
        mark("clock back")
        try? await Task.sleep(for: .seconds(1.5))
        PhoneCharger.shared.tapClock()
        try? await Task.sleep(for: .seconds(1.5))
        UserDefaults.standard.set(false, forKey: key)
        try? await Task.sleep(for: .seconds(2))
        mark("switched off")
        try? await Task.sleep(for: .seconds(1.5))
        UserDefaults.standard.set(true, forKey: key)
        try? await Task.sleep(for: .seconds(2.5))
        mark("switched on")
        try? await Task.sleep(for: .seconds(1.5))
        PhoneCharger.shared.pretend(plugged: false, percent: 82)
        try? await Task.sleep(for: .seconds(2))
        mark("unplugged")
        try? await Task.sleep(for: .seconds(1.5))
        mark("end")
    }

    private static func environment(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }

    private static func swapCheck(_ shift: KnobShiftModel, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        try? await Task.sleep(for: .seconds(4))
        // Straight back to the same song, cutting the change short: the record must come back out.
        shift.log("VINYL", "CASE next then straight back")
        shift.next()
        try? await Task.sleep(for: .milliseconds(150))
        shift.previous()
        try? await Task.sleep(for: .seconds(3))
        if environment("KNOB_PHONE_SWAP_ONLY_BACK") { return }
        shift.log("VINYL", "CASE next")
        shift.next()
        try? await Task.sleep(for: .seconds(4))
        // Past three seconds in, the first press restarts the song and the second goes back.
        shift.log("VINYL", "CASE previous")
        shift.previous()
        try? await Task.sleep(for: .milliseconds(300))
        shift.previous()
        try? await Task.sleep(for: .seconds(4))
        shift.log("VINYL", "CASE three quick nexts")
        for _ in 0..<3 {
            shift.next()
            try? await Task.sleep(for: .milliseconds(180))
        }
        try? await Task.sleep(for: .seconds(4))
        shift.log("VINYL", "CASE KnobMix")
        shift.mixNow()
        var waited = 0
        while shift.mixState != .mixing, waited < 400 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        shift.log("VINYL", "CASE the mix began")
        while shift.mixState == .mixing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        shift.log("VINYL", "CASE the mix ended")
    }

    /// KNOB_PHONE_TURN=n turns the phone on its side after n seconds, then drives the record deck
    /// the way hands do: the song's position is logged through the turn, then a hand turns the
    /// record one full turn forward and half a turn back, and the arm is moved to 70 percent.
    private static func vinylCheck(_ shift: KnobShiftModel, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        shift.updatePlaybackTime()
        let before = shift.playbackTime
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        shift.log("VINYL", "Turning on its side at \(String(format: "%.2f", before))s.")
        try? await Task.sleep(for: .seconds(4))
        shift.updatePlaybackTime()
        shift.log("VINYL", "Four seconds later the song is at \(String(format: "%.2f", shift.playbackTime))s, and playing is \(shift.isPlaying).")
        let deck = KnobShiftTurntable.shared(for: shift)
        deck.handDown(at: CGPoint(x: 100, y: 0), center: .zero)
        try? await Task.sleep(for: .milliseconds(400))
        for (degrees, count) in [(12.0, 30), (-12.0, 15)] {
            for _ in 0..<count {
                deck.turn(by: degrees)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        shift.log("VINYL", "Under the hand, playing is \(shift.isPlaying).")
        deck.handUp()
        try? await Task.sleep(for: .seconds(3))
        shift.updatePlaybackTime()
        shift.log("VINYL", "After the hand: song at \(String(format: "%.2f", shift.playbackTime))s, playing is \(shift.isPlaying).")
        deck.armLifted(progress: 0.3)
        deck.armMoved(progress: 0.7)
        try? await Task.sleep(for: .seconds(1))
        deck.armDropped()
        try? await Task.sleep(for: .seconds(3))
        shift.updatePlaybackTime()
        shift.log("VINYL", "After the arm: song at \(String(format: "%.2f", shift.playbackTime))s of \(String(format: "%.2f", shift.playbackDuration))s, playing is \(shift.isPlaying).")
        // The review's cases, each from a clean start.
        // The phone turned upright with the arm in the air.
        deck.armLifted(progress: 0.4)
        deck.armMoved(progress: 0.5)
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try? await Task.sleep(for: .seconds(2))
        shift.updatePlaybackTime()
        let upright = shift.playbackTime
        try? await Task.sleep(for: .seconds(2))
        shift.updatePlaybackTime()
        shift.log("VINYL", "CASE turned upright holding the arm: two seconds moved \(String(format: "%.2f", shift.playbackTime - upright))s, deck \(shift.primaryDeck.player.isPlaying), playing \(shift.isPlaying).")
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        try? await Task.sleep(for: .seconds(1))
        // A touch the system takes away must let go of the record.
        deck.handDown(at: CGPoint(x: 100, y: 0), center: .zero)
        try? await Task.sleep(for: .milliseconds(300))
        deck.releaseNow()
        try? await Task.sleep(for: .seconds(1))
        shift.log("VINYL", "CASE touch taken away: active \(deck.isActive), deck \(shift.primaryDeck.player.isPlaying), playing \(shift.isPlaying).")
        // Pause under a hand must not play the song twice.
        deck.handDown(at: CGPoint(x: 100, y: 0), center: .zero)
        try? await Task.sleep(for: .milliseconds(300))
        shift.pauseOrResume()
        shift.log("VINYL", "CASE paused under a hand: active \(deck.isActive), deck \(shift.primaryDeck.player.isPlaying), playing \(shift.isPlaying).")
        try? await Task.sleep(for: .milliseconds(400))
        shift.pauseOrResume()
        deck.handUp()
        try? await Task.sleep(for: .seconds(2))
        shift.updatePlaybackTime()
        shift.log("VINYL", "CASE pause then play under a hand: active \(deck.isActive), deck \(shift.primaryDeck.player.isPlaying), playing \(shift.isPlaying).")
        // The arm dropped at the very end of the song.
        let song = shift.nowPlaying?.title ?? ""
        deck.armLifted(progress: 0.5)
        deck.armMoved(progress: 1)
        deck.armDropped()
        try? await Task.sleep(for: .seconds(3))
        shift.log("VINYL", "CASE arm at the end: active \(deck.isActive), next song \(shift.nowPlaying?.title != song), playing \(shift.isPlaying).")
        // Round and round: the record's sound is wired in and out each time.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        shift.updatePlaybackTime()
        let started = shift.playbackTime
        for turn in 0..<8 {
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: turn % 2 == 0 ? .portrait : .landscapeLeft))
            try? await Task.sleep(for: .seconds(1.2))
        }
        shift.updatePlaybackTime()
        shift.log("VINYL", "Eight turns in 9.6 seconds moved the song \(String(format: "%.2f", shift.playbackTime - started))s, playing is \(shift.isPlaying).")
    }

    /// Development checks in the simulator, set with SIMCTL_CHILD_ before `simctl launch`:
    /// KNOB_PHONE_SILENT=1 measures Knob's sound but plays nothing, KNOB_PHONE_ADD=1 queues every
    /// song in KnobShift/Imported, KNOB_PHONE_PLAY=1 turns Knob on and plays, and
    /// KNOB_PHONE_SHEET=1 opens the sound controls. KNOB_PHONE_MAC=spotify, youtube or sync opens
    /// that sheet, and KNOB_PHONE_SYNC=1 syncs with Knob on the Mac
    /// (a number of seconds instead waits that long first). KNOB_PHONE_QUEUE=1 opens the queue (or
    /// after that many seconds), KNOB_PHONE_MIX=n asks for a KnobMix and KNOB_PHONE_PAUSE=n pauses,
    /// both after n seconds. KNOB_PHONE_HOLD and KNOB_PHONE_SHUFFLE are explained where they run.
    private static func runChecks(_ model: KnobModel) async {
        let environment = ProcessInfo.processInfo.environment
        if let seconds = environment["KNOB_PHONE_TURN"].flatMap(Double.init) {
            Task { await vinylCheck(model.knobShift, after: seconds) }
        }
        if let seconds = environment["KNOB_PHONE_UX"].flatMap(Double.init) {
            Task { await uxCheck(model.knobShift, after: seconds) }
        }
        if let seconds = environment["KNOB_PHONE_TIPS"].flatMap(Double.init) {
            Task { await tipsCheck(model.knobShift, after: seconds) }
        }
        if let seconds = environment["KNOB_PHONE_BEDSIDE"].flatMap(Double.init) {
            Task { await bedsideCheck(model.knobShift, after: seconds) }
        }
        if let seconds = environment["KNOB_PHONE_SWAP"].flatMap(Double.init) {
            Task { await swapCheck(model.knobShift, after: seconds) }
        }
        PhoneEffectUnit.silent = environment["KNOB_PHONE_SILENT"] == "1"
        // KNOB_PHONE_ADD=2 carries on while the songs prepare, so the queue can be seen doing it.
        if let add = environment["KNOB_PHONE_ADD"], add == "1" || add == "2" {
            let files = (try? FileManager.default.contentsOfDirectory(at: PhoneLibrary.folder, includingPropertiesForKeys: nil)) ?? []
            let songs = files.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
            if add == "1" {
                await model.knobShift.addTracks(songs)
            } else {
                model.knobShift.enqueueFiles(songs)
                Task { await model.knobShift.processPending() }
            }
        }
        if environment["KNOB_PHONE_PLAY"] == "1" {
            // The saved queue comes back in the background: wait for it.
            for _ in 0..<150 where model.knobShift.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            model.userSetPower(true)
            if let first = model.knobShift.tracks.first { model.knobShift.select(first) }
        }
        if environment["KNOB_PHONE_SHEET"] == "1" { PhoneSheets.shared.sound = true }
        if let wait = environment["KNOB_PHONE_QUEUE"].flatMap(Double.init) {
            if wait > 1 { try? await Task.sleep(for: .seconds(wait)) }
            PhoneSheets.shared.queue = true
        }
        if let wait = environment["KNOB_PHONE_MIX"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(wait))
            model.knobShift.mixNow()
        }
        if let wait = environment["KNOB_PHONE_PAUSE"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(wait))
            model.knobShift.pauseOrResume()
        }
        // KNOB_PHONE_HOLD=n pauses n seconds into the mix and resumes 3 seconds later.
        if let wait = environment["KNOB_PHONE_HOLD"].flatMap(Double.init) {
            for _ in 0..<1800 where model.knobShift.mixState != .mixing { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .seconds(wait))
            model.knobShift.pauseOrResume()
            try? await Task.sleep(for: .seconds(3))
            model.knobShift.pauseOrResume()
        }
        // KNOB_PHONE_SHUFFLE=1 turns shuffle on once two songs are ready.
        if environment["KNOB_PHONE_SHUFFLE"] == "1" {
            for _ in 0..<1200 where model.knobShift.tracks.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
            if !model.knobShift.isShuffled { model.knobShift.toggleShuffle() }
            model.knobShift.persistQueueNow()
        }
        if let sheet = environment["KNOB_PHONE_MAC"].flatMap(PhoneMacSheet.Source.init(rawValue:)) { PhoneSheets.shared.mac = sheet }
        if let wait = environment["KNOB_PHONE_SYNC"].flatMap(Double.init) {
            // A number above 1 waits that many seconds first, so the sheet is on screen.
            if wait > 1 { try? await Task.sleep(for: .seconds(wait)) }
            await PhoneMacLink.shared.sync(model.knobShift)
        }
        if environment["KNOB_PHONE_PLAY"] == "1" {
            // What Knob's sound measured after a few seconds of playback, for the log.
            try? await Task.sleep(for: .seconds(6))
            let state = EngineState(json: try? await model.engine.send("getState", [:]))
            model.knobShift.log("CHECK", String(format: "Knob's sound: %@, peaks %.3f and %.3f, spectrum total %.3f over %d bands.",
                                                state.bypassed ? "off" : "on", state.peakLeft, state.peakRight,
                                                state.spectrum.reduce(0, +), state.spectrum.count))
        }
    }
    #endif

    /// Music keeps playing with the screen locked or another app open.
    private static func playInBackground() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}

/// The phone's main screen is the KnobShift player (PhonePlayer); Knob's sound controls (power,
/// presets, effects and equalizer) open from its sound button.
struct PhoneRoot: View {
    @ObservedObject var model: KnobModel
    @ObservedObject private var sheets = PhoneSheets.shared
    @ObservedObject private var link = PhoneMacLink.shared
    /// The opening animation runs once per launch, over the player (PhoneLaunch).
    @State private var launching = true
    /// The opening's knob has reached the Play button, so the real one takes over.
    @State private var landed = false
    /// Where the player's Play button is, for the opening's knob to land on.
    @State private var playButton = CGRect.zero

    var body: some View {
        ZStack {
            // The player waits ready under the opening's solid background, which fades off it in
            // one layer. It never moves, so its Play button stays where the knob lands.
            PhonePlayer(model: model.knobShift, knob: model, prepareImports: PhoneLibrary.keep)
                .environment(\.hidesPlayButton, !landed)
                .onPreferenceChange(PlayButtonFrame.self) { playButton = $0 }
                .darkPlayer()
            // A finished sync's "done" card, over the player (KnobDoneCard).
            if let done = link.done {
                KnobDoneCard(title: done.title, detail: done.detail, onFinished: { link.done = nil })
                    .id(done.id)
                    .padding(.horizontal, 24)
            }
            if launching {
                PhoneLaunch(playButton: playButton,
                            onLanded: { landed = true },
                            onFinished: { launching = false })
            }
        }
        .darkWindow(after: launching)
        .sheet(isPresented: $sheets.sound) {
                PhoneSoundSheet(model: model)
                    .presentationDetents([.height(460), .large])
                    .presentationDragIndicator(.visible)
                    .focusEffectDisabled()
            }
    }
}

/// Knob's sound controls on the iPhone: the panel's header (power and menu), presets and the
/// analyser screen with its Effects and Equalizer tabs, on the same faceplate.
struct PhoneSoundSheet: View {
    @ObservedObject var model: KnobModel
    @Environment(\.colorScheme) private var scheme
    @State private var showingAbout = false

    var body: some View {
        let p = Palette.of(scheme)
        ScrollView {
            Group {
                if showingAbout {
                    AboutView(onBack: { withAnimation(Motion.gentle) { showingAbout = false } })
                        .transition(.opacity)
                } else {
                    VStack(spacing: 14) {
                        HeaderBar(model: model, onAbout: { withAnimation(Motion.gentle) { showingAbout = true } })
                        PresetBar(model: model)
                        ScreenSection(model: model)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
        .background {
            ZStack {
                LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)
                Grain(opacity: p.grain)
            }
            .ignoresSafeArea()
        }
        .redacted(reason: model.connection == .connecting ? .placeholder : [])
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }
}

/// Songs picked in the Files app are copied into the app's own KnobShift folder, so they stay
/// playable after the Files app lets go of them.
enum PhoneLibrary {
    static var folder: URL { KnobShiftPlaylists.home.appendingPathComponent("Imported", isDirectory: true) }

    static func keep(_ urls: [URL]) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { url in
            let reading = url.startAccessingSecurityScopedResource()
            defer { if reading { url.stopAccessingSecurityScopedResource() } }
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                do { try FileManager.default.copyItem(at: url, to: target) } catch { return nil }
            }
            return target
        }
    }
}
