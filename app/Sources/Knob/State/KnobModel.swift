import AppKit
import Foundation
import SwiftUI

/// Everything the panel shows, and every action it can take. Views only talk to this object;
/// it talks to the engine and to the Mac's volume.
@MainActor
final class KnobModel: ObservableObject {
    enum Connection { case connecting, online, offline }

    @Published private(set) var connection: Connection = .connecting
    @Published var volume = 0.0
    @Published private(set) var muted = false
    @Published private(set) var volumeControllable = true
    @Published private(set) var powerOn = false
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var currentPreset: Preset?
    @Published var effects: [Double] = Array(repeating: 0, count: EffectSlot.allCases.count)
    @Published var eq: [Double] = []
    @Published private(set) var frequencies: [Double] = []
    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var outputUID: String?
    @Published private(set) var spectrum: [Double] = Array(repeating: 0, count: 10)
    @Published private(set) var peakLeft = 0.0
    @Published private(set) var peakRight = 0.0
    /// A plain-language message for the panel, such as why the engine couldn't start.
    @Published private(set) var notice: String?
    @Published private(set) var starting = false
    /// True when ON failed only because the audio device isn't installed and the app can install it.
    @Published private(set) var canInstallDevice = false
    /// True when the Mac's sound actually goes through Knob (Knob is the default output).
    @Published private(set) var routingActive = false

    private let engine: SoundEngine
    private let volumeControl: VolumeControl
    /// Starts the real engine; nil for the demo engine, which is always running.
    private let launcher: EngineLauncher?
    private var liveTask: Task<Void, Never>?
    private var pending: [String: Double] = [:]
    private var flushTask: Task<Void, Never>?
    private var editing = 0
    private var spectrumPeak = 0.05
    private var sessionSaveTask: Task<Void, Never>?
    /// What the user asked for with the switch. While ON, Knob keeps itself as the Mac's output.
    private var wantsOn = false
    private var reclaiming = false

    init(engine: SoundEngine, volume: VolumeControl, launcher: EngineLauncher? = nil) {
        self.engine = engine
        self.volumeControl = volume
        self.launcher = launcher
    }

    func start() {
        volumeControl.onChange = { [weak self] volume, muted, controllable in
            guard let self else { return }
            self.volume = volume
            self.muted = muted
            self.volumeControllable = controllable
            if self.knobIsOutput { VolumeHandoff.remember(volume) }
        }
        volumeControl.start()
        if launcher != nil {
            // A previous run may have stopped while speakers were raised underneath Knob.
            if !knobIsOutput { VolumeHandoff.giveBack() }
            HardwareDevices.observeDefaultOutput { [weak self] in self?.defaultOutputChanged() }
        }
        presets = Preset.all()
        if let path = UserDefaults.standard.string(forKey: PersistKey.lastPreset.rawValue) {
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
        outputUID = state.outputUID
        peakLeft = state.peakLeft
        peakRight = state.peakRight
        spectrumPeak = max(spectrumPeak * 0.995, state.spectrum.max() ?? 0, 0.05)
        let target = state.spectrum.map { min($0 / spectrumPeak, 1) }
        if target.count == spectrum.count {
            spectrum = zip(spectrum, target).map { old, new in new > old ? old + (new - old) * 0.7 : old + (new - old) * 0.25 }
        } else {
            spectrum = target
        }
        guard includeControls else { return }
        if state.effects.count == effects.count { effects = state.effects.map { $0 / 10 } }
        eq = state.eq.map { $0 / 12 }
        frequencies = state.frequencies
    }

    // MARK: Actions

    func setVolume(_ value: Double) {
        volume = value
        volumeControl.setVolume(value)
    }

    func toggleMute() { volumeControl.setMuted(!muted) }

    /// ON starts the engine if needed, turns effects on, and makes Knob the Mac's output.
    /// OFF fully stops the engine Knob started: the speakers are handed back, and macOS stops
    /// showing audio input in use (the orange dot), because nothing reads Knob's device any
    /// more. Every setting is saved first and comes back on the next ON. (An engine Knob didn't
    /// start, and the demo engine, are only bypassed.)
    func setPower(_ on: Bool) {
        guard !starting else { return }
        wantsOn = on
        if on, connection != .online {
            Task { await startEngine() }
            return
        }
        if !on, launcher != nil, connection == .online {
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

    private func startEngine() async {
        guard let launcher else { return }
        starting = true
        notice = "Starting the sound engine..."
        defer { starting = false }
        let physical = HardwareDevices.preferredPhysicalOutput()
        let session = Self.sessionURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        do {
            try await launcher.start(preset: session ?? currentPreset?.url)
            canInstallDevice = false
        } catch EngineLauncher.Problem.deviceMissing where DriverInstaller.bundledDriver != nil {
            canInstallDevice = true
            notice = "Knob needs to install its audio device first."
            wantsOn = false
            return
        } catch {
            notice = error.localizedDescription
            wantsOn = false
            return
        }
        for _ in 0..<50 where connection != .online {
            try? await Task.sleep(for: .milliseconds(200))
            await refresh()
        }
        guard connection == .online else {
            launcher.stop()
            notice = EngineLauncher.Problem.launchFailed.errorDescription
            wantsOn = false
            return
        }
        _ = await succeeds("setBypass", ["value": false])
        for _ in 0..<30 where !routingActive {   // the engine makes itself the output once audio flows
            try? await Task.sleep(for: .milliseconds(200))
            await refreshState(includeControls: true)
        }
        if routingActive {
            VolumeHandoff.takeOver(from: physical)
            notice = nil   // started: the "Starting the sound engine..." message goes away
        } else {
            await takeOverOutput(followingSystem: false)   // clears the message on success, explains on failure
        }
    }

    /// Installs the audio device bundled in the app (one password prompt), then switches Knob on.
    func installAudioDevice() {
        guard !starting else { return }
        Task {
            starting = true
            notice = "Installing Knob's audio device..."
            do {
                try await DriverInstaller.install()
            } catch {
                starting = false
                notice = error.localizedDescription
                return
            }
            starting = false
            canInstallDevice = false
            wantsOn = true
            await startEngine()
        }
    }

    /// Makes Knob the Mac's output (playing through the output the user picked last), carrying
    /// the volume over so nothing jumps.
    private func takeOverOutput(followingSystem: Bool) async {
        if followingSystem { await followSystemOutput() }
        let physical = outputUID.flatMap(HardwareDevices.device(uid:))
        for _ in 0..<15 {   // the engine refuses until audio is flowing again after an output change
            if await succeeds("activateRouting", ["value": true]) {
                VolumeHandoff.takeOver(from: physical)
                notice = nil
                await refreshState()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        notice = "Knob couldn't take over the sound output. Try again."
    }

    /// If the user picked different speakers in the Sound menu, play there.
    private func followSystemOutput() async {
        let current = HardwareDevices.defaultOutputID
        guard let device = HardwareDevices.all().first(where: { $0.id == current && $0.isPhysicalOutput }),
              device.uid != outputUID else { return }
        if await succeeds("setOutputUID", ["outputUID": device.uid]) { outputUID = device.uid }
    }

    /// Something else became the Mac's output (the Sound menu, or the engine stopping).
    /// Give the volume back right away; if Knob is meant to be on, take over again on the new output.
    private func defaultOutputChanged() {
        guard !knobIsOutput else { return }
        VolumeHandoff.giveBack()
        routingActive = false
        powerOn = false
        guard wantsOn, connection == .online, !reclaiming, !starting else { return }
        reclaiming = true
        Task {
            await takeOverOutput(followingSystem: true)
            reclaiming = false
        }
    }

    private var knobIsOutput: Bool {
        HardwareDevices.device(uid: HardwareDevices.knobUID)?.id == HardwareDevices.defaultOutputID
    }

    /// Sends a command and reports whether the engine accepted it (a reply with no data is success).
    private func succeeds(_ command: String, _ arguments: [String: Any]) async -> Bool {
        do { _ = try await engine.send(command, arguments); return true } catch { return false }
    }

    private func refreshState(includeControls: Bool = false) async {
        if let state = try? await engine.send("getState", [:]) { apply(EngineState(json: state), includeControls: includeControls) }
    }

    /// Saves the current sound, hands the Mac its normal output back (with Knob's volume),
    /// then stops the engine.
    func stopEngine() async {
        guard launcher != nil, connection == .online else { return }
        wantsOn = false
        await saveSession()
        _ = await succeeds("activateRouting", ["value": false])
        VolumeHandoff.giveBack()
        _ = await succeeds("shutdown", [:])
        launcher?.stop()
        powerOn = false
        routingActive = false
        connection = .offline
        notice = nil
    }

    func quit() {
        Task {
            await stopEngine()
            NSApp.terminate(nil)
        }
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
        guard launcher != nil else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveSession()
        }
    }

    private func saveSession() async {
        guard launcher != nil, connection == .online, let url = Self.sessionURL else { return }
        _ = try? await engine.send("savePreset", ["path": url.path])
    }

    func setEffect(_ slot: EffectSlot, _ value: Double) {
        effects[slot.rawValue] = value
        queue(slot.parameter, value * 10)
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

    func selectOutput(_ device: OutputDevice) {
        outputUID = device.uid
        Task { _ = try? await engine.send("setOutputUID", ["outputUID": device.uid]) }
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
