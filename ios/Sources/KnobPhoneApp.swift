import AVFoundation
import SwiftUI

/// Knob on the iPhone: the KnobShift player for songs imported into the app, with Knob's sound
/// controls (power, presets, effects and equalizer) a tap away. Everything KnobShift plays goes
/// through Knob's sound.
@main
struct KnobPhoneApp: App {
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
        Self.playInBackground()
        let model = model, engine = engine
        Task {
            do {
                model.knobShift.insertOutputEffect(try await PhoneEffectUnit.make(for: engine))
            } catch {
                model.knobShift.log("SESSION", "Knob's sound could not be added: \(error.localizedDescription)")
            }
            model.start()
            model.restorePower()
            #if DEBUG
            await Self.runChecks(model)
            #endif
        }
    }

    #if DEBUG
    /// Development checks in the simulator, set with SIMCTL_CHILD_ before `simctl launch`:
    /// KNOB_PHONE_SILENT=1 measures Knob's sound but plays nothing, KNOB_PHONE_ADD=1 queues every
    /// song in KnobShift/Imported, KNOB_PHONE_PLAY=1 turns Knob on and plays, and
    /// KNOB_PHONE_SHEET=1 opens the sound controls.
    private static func runChecks(_ model: KnobModel) async {
        let environment = ProcessInfo.processInfo.environment
        PhoneEffectUnit.silent = environment["KNOB_PHONE_SILENT"] == "1"
        if environment["KNOB_PHONE_ADD"] == "1" {
            let files = (try? FileManager.default.contentsOfDirectory(at: PhoneLibrary.folder, includingPropertiesForKeys: nil)) ?? []
            await model.knobShift.addTracks(files.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path })
        }
        if environment["KNOB_PHONE_PLAY"] == "1" {
            model.userSetPower(true)
            if let first = model.knobShift.tracks.first { model.knobShift.select(first) }
        }
        if environment["KNOB_PHONE_SHEET"] == "1" { PhoneSheets.shared.sound = true }
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

/// The phone's main screen is the KnobShift player; Knob's sound controls (power, presets,
/// effects and equalizer) open from its sound button. There is no volume knob: the iPhone's own
/// volume buttons do that.
struct PhoneRoot: View {
    @ObservedObject var model: KnobModel
    @ObservedObject private var sheets = PhoneSheets.shared
    /// The opening animation runs once per launch, over the player (PhoneLaunch).
    @State private var launching = true
    @State private var revealed = false

    var body: some View {
        ZStack {
            KnobShiftPlayerView(model: model.knobShift, onSound: { sheets.sound = true }, prepareImports: PhoneLibrary.keep)
                .scaleEffect(revealed ? 1 : 1.06)
                .opacity(revealed ? 1 : 0)
            if launching {
                PhoneLaunch(onReveal: { withAnimation(Motion.gentle) { revealed = true } },
                            onFinished: { launching = false })
            }
        }
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
