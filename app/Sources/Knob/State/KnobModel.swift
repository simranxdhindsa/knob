#if os(macOS)
import AppKit
#endif
import Foundation
import SwiftUI

/// Everything the panel shows, and every action it can take. Views only talk to this object;
/// it talks to the engine and to the device's volume. Starting and stopping the engine is per
/// platform: KnobModel+MacEngine.swift on the Mac, the iPhone app's own file there.
@MainActor
final class KnobModel: ObservableObject {
    enum Connection { case connecting, online, offline }

    @Published internal(set) var connection: Connection = .connecting
    @Published var volume = 0.0
    @Published private(set) var muted = false
    @Published private(set) var volumeControllable = true
    @Published internal(set) var powerOn = false
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var currentPreset: Preset?
    @Published var effects: [Double] = Array(repeating: 0, count: EffectSlot.allCases.count)
    @Published var eq: [Double] = []
    @Published private(set) var frequencies: [Double] = []
    @Published internal(set) var outputs: [OutputDevice] = []
    @Published internal(set) var outputUID: String?
    @Published private(set) var spectrum: [Double] = Array(repeating: 0, count: 10)
    @Published private(set) var peakLeft = 0.0
    @Published private(set) var peakRight = 0.0
    /// A plain-language message for the panel, such as why the engine couldn't start.
    @Published internal(set) var notice: String?
    @Published internal(set) var starting = false
    @Published internal(set) var startupFailure: StartupFailure?
    /// True when ON failed only because the audio device isn't installed and the app can install it.
    @Published internal(set) var canInstallDevice = false
    /// True when the Mac's sound actually goes through Knob (Knob is the default output).
    @Published internal(set) var routingActive = false
    /// Local-file playback and transition planning. It never controls streaming-service players.
    let knobShift = KnobShiftModel()

    let engine: SoundEngine
    private let volumeControl: VolumeControl
    #if os(macOS)
    /// Starts the real engine; nil for the demo engine, which is always running.
    let launcher: EngineLauncher?
    let volumeKeys = VolumeKeys()
    #endif
    private var liveTask: Task<Void, Never>?
    private var pending: [String: Double] = [:]
    private var flushTask: Task<Void, Never>?
    private var editing = 0
    private var spectrumPeak = 0.05
    private var sessionSaveTask: Task<Void, Never>?
    /// What the user asked for with the switch. While ON, Knob keeps itself as the Mac's output.
    var wantsOn = false
    var reclaiming = false
    /// True while the user's pick in the output menu is being applied. The engine hands the Mac
    /// its old output back for a moment while it switches, and that must not be "followed".
    var switchingOutput = false

    #if os(macOS)
    init(engine: SoundEngine, volume: VolumeControl, launcher: EngineLauncher? = nil) {
        self.engine = engine
        self.volumeControl = volume
        self.launcher = launcher
        KnobShiftTogetherSession.shared.sound = self
    }
    #else
    init(engine: SoundEngine, volume: VolumeControl) {
        self.engine = engine
        self.volumeControl = volume
        KnobShiftTogetherSession.shared.sound = self
    }
    #endif

    func start() {
        volumeControl.onChange = { [weak self] volume, muted, controllable in
            guard let self else { return }
            self.volume = volume
            self.muted = muted
            self.volumeControllable = controllable
            self.volumeChanged(volume)
        }
        volumeControl.start()
        startPlatform()
        presets = Preset.all()
        if let path = UserDefaults.standard.string(forKey: PersistKey.lastPreset.rawValue).map(Platform.relocated) {
            currentPreset = presets.first { $0.url.path == path }
        }
        Task { await refresh() }
    }

    // MARK: Live updates (only while the panel is open)

    /// Counts open panels: the menu bar panel, plus the dev window in dev mode.
    private var openPanels = 0

    func panelOpened() {
        openPanels += 1
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    func panelClosed() {
        openPanels = max(0, openPanels - 1)
        guard openPanels == 0 else { return }
        liveTask?.cancel()
        liveTask = nil
    }

    func refresh() async {
        do {
            outputs = OutputDevice.list(json: try await engine.send("getDevices", [:]))
            apply(EngineState(json: try await engine.send("getState", [:])), includeControls: true)
            connection = .online
            await keepTenBands()
        } catch {
            connection = .offline
        }
    }

    /// Knob's equalizer has 10 bands. An engine started without a preset comes up with its
    /// built-in 31, which can't fit the panel, so switch it to 10 whenever that happens.
    static let eqBands = 10

    private func keepTenBands() async {
        guard !eq.isEmpty, eq.count != Self.eqBands else { return }
        guard await succeeds("setNumEqBands", ["count": Self.eqBands]) else { return }
        await refreshState(includeControls: true)
        scheduleSessionSave()
    }

    private func poll() async {
        guard connection == .online else {
            await refresh()
            if connection == .offline { try? await Task.sleep(for: .seconds(2)) }
            return
        }
        do { apply(EngineState(json: try await engine.send("getState", [:])), includeControls: editing == 0 && pending.isEmpty) }
        catch { connection = .offline }
    }

    private func apply(_ state: EngineState, includeControls: Bool) {
        routingActive = state.routingActive
        // ON means effects are on AND the Mac's sound goes through Knob; anything else is OFF.
        powerOn = !state.bypassed && state.routingActive
        poweredOn()
        outputUID = state.outputUID
        peakLeft = state.peakLeft
        peakRight = state.peakRight
        spectrumPeak = max(spectrumPeak * 0.995, state.spectrum.max() ?? 0, 0.05)
        // SpectrumView glides to these on every frame, so they are passed on as measured.
        spectrum = state.spectrum.map { min($0 / spectrumPeak, 1) }
        guard includeControls else { return }
        if state.effects.count == effects.count { effects = state.effects.map { $0 / 10 } }
        eq = state.eq.map { $0 / 12 }
        frequencies = state.frequencies
    }

    // MARK: Actions

    /// Volume moves in whole percents: turning the knob or typing 50.5 lands on 1% steps.
    func setVolume(_ value: Double) {
        let stepped = (value * 100).rounded() / 100
        guard stepped != volume else { return }
        volume = stepped
        volumeControl.setVolume(stepped)
    }

    func toggleMute() { volumeControl.setMuted(!muted) }

    /// The switch, flipped by the user: remembered, so the next launch comes back the same way.
    func userSetPower(_ on: Bool) {
        guard !starting else {
            KnobShiftLog.append(stage: "POWER", message: "You turned Knob \(on ? "ON" : "OFF"), ignored because it is still starting.")
            return
        }
        KnobShiftLog.append(stage: "POWER", message: "You turned Knob \(on ? "ON" : "OFF").")
        Self.rememberPower(on)
        setPower(on)
    }

    static func rememberPower(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: PersistKey.powerOn.rawValue)
    }

    /// ON starts the engine if needed, turns effects on, and makes Knob the Mac's output.
    /// OFF fully stops the engine Knob started: the speakers are handed back, and macOS stops
    /// showing audio input in use (the orange dot), because nothing reads Knob's device any
    /// more. Every setting is saved first and comes back on the next ON. (An engine Knob didn't
    /// start, and the demo engine, are only bypassed.)
    func setPower(_ on: Bool) {
        guard !starting else { return }
        wantsOn = on
        if on, connection != .online || isStaleEngine {
            Task { await startEngine() }
            return
        }
        if !on, stopsWhenOff, connection == .online {
            powerOn = false
            notice = nil
            Task { await stopEngine() }
            return
        }
        powerOn = on
        notice = nil
        Task {
            if on {
                _ = await succeeds("setBypass", ["value": false])
                if !routingActive { await takeOverOutput(followingSystem: true) }
            } else {
                _ = await succeeds("setBypass", ["value": true])
            }
            await refreshState()
        }
    }

    func showStartupFailure(_ failure: StartupFailure) {
        startupFailure = failure
        notice = failure.message
    }

    /// Sends a command and reports whether the engine accepted it (a reply with no data is success).
    func succeeds(_ command: String, _ arguments: [String: Any]) async -> Bool {
        do {
            _ = try await engine.send(command, arguments)
            return true
        } catch {
            KnobShiftLog.append(stage: "ENGINE", message: "\(command) refused: \(error.localizedDescription)")
            return false
        }
    }

    func refreshState(includeControls: Bool = false) async {
        if let state = try? await engine.send("getState", [:]) { apply(EngineState(json: state), includeControls: includeControls) }
    }

    // MARK: Session (the current sound, kept across restarts)

    /// Where the current sound is kept between runs. One file per app copy, so the dev copy
    /// never overwrites the installed one.
    static var sessionURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("session.fac")
    }

    /// Saves about a second after the last change, so dragging a knob writes once.
    private func scheduleSessionSave() {
        guard keepsSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveSession()
        }
    }

    func saveSession() async {
        guard keepsSession, connection == .online, let url = Self.sessionURL else { return }
        _ = try? await engine.send("savePreset", ["path": url.path])
    }

    /// Effects move in whole steps, 0 to 10, one per indicator mark on the knob.
    func setEffect(_ slot: EffectSlot, _ value: Double) {
        let stepped = (value * 10).rounded() / 10
        guard stepped != effects[slot.rawValue] else { return }
        effects[slot.rawValue] = stepped
        queue(slot.parameter, stepped * 10)
    }

    func setEQ(band: Int, _ value: Double) {
        guard eq.indices.contains(band) else { return }
        eq[band] = value
        queue("eq\(band + 1)", value * 12)
    }

    func editingChanged(_ active: Bool) { editing = max(0, editing + (active ? 1 : -1)) }

    /// Saves the current sound as a new preset called `name`, adds it to the list and selects it.
    /// Returns false (with a notice) if it couldn't be saved.
    @discardableResult
    func savePreset(named name: String) async -> Bool {
        guard connection == .online, let url = Preset.newUserFile(named: name) else {
            notice = connection == .online ? "Give the preset a name." : "Turn Knob on to save a preset."
            return false
        }
        guard await succeeds("savePreset", ["path": url.path]) else {
            notice = "The preset couldn't be saved. Try again."
            return false
        }
        presets = Preset.all()
        if let saved = presets.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            currentPreset = saved
            UserDefaults.standard.set(saved.url.path, forKey: PersistKey.lastPreset.rawValue)
        }
        notice = nil
        return true
    }

    /// Deletes one of the user's own presets. Factory presets can't be deleted. The current sound
    /// stays as it is; only the saved file goes.
    func deletePreset(_ preset: Preset) {
        guard preset.isUser else { return }
        do { try FileManager.default.removeItem(at: preset.url) }
        catch { notice = "The preset couldn't be deleted. Try again."; return }
        presets = Preset.all()
        if currentPreset == preset {
            currentPreset = nil
            UserDefaults.standard.removeObject(forKey: PersistKey.lastPreset.rawValue)
        }
        notice = nil
    }

    func select(_ preset: Preset) {
        currentPreset = preset
        UserDefaults.standard.set(preset.url.path, forKey: PersistKey.lastPreset.rawValue)
        Task {
            _ = try? await engine.send("setPreset", ["path": preset.url.path])
            if let state = try? await engine.send("getState", [:]) { apply(EngineState(json: state), includeControls: true) }
            scheduleSessionSave()
        }
    }

    func stepPreset(_ offset: Int) {
        guard !presets.isEmpty else { return }
        let index = currentPreset.flatMap { presets.firstIndex(of: $0) } ?? 0
        select(presets[(index + offset + presets.count) % presets.count])
    }

    /// Coalesces fast knob movement into at most one engine message per name every 50ms.
    private func queue(_ name: String, _ value: Double) {
        pending[name] = value
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            let batch = self.pending
            self.pending.removeAll()
            self.flushTask = nil
            for (name, value) in batch { _ = try? await self.engine.send("setParam", ["name": name, "value": value]) }
            self.scheduleSessionSave()
        }
    }
}
