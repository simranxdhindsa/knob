#if os(macOS)
import AppKit
import Foundation

/// The Mac's side of the panel model: starting knob-engine through its supervisor, installing
/// Knob's audio device, handing the volume to and from the physical output, Knob's 2% volume
/// keys and the output menu. The iPhone app has its own version of these.
extension KnobModel {
    /// The real engine keeps the current sound in a session file and fully stops when OFF; the
    /// demo engine does neither.
    var keepsSession: Bool { launcher != nil }
    var stopsWhenOff: Bool { launcher != nil }

    func startPlatform() {
        guard launcher != nil else { return }
        // A previous run may have stopped while speakers were raised underneath Knob.
        if !knobIsOutput { VolumeHandoff.giveBack() }
        HardwareDevices.observeDefaultOutput { [weak self] in self?.defaultOutputChanged() }
        HardwareDevices.observeDevices { [weak self] in self?.devicesChanged() }
        volumeKeys.isActive = { [weak self] in self?.knobIsOutput == true }
        volumeKeys.onStep = { [weak self] direction in self?.stepVolume(direction) }
    }

    func volumeChanged(_ volume: Double) {
        if knobIsOutput { VolumeHandoff.remember(volume) }
    }

    func poweredOn() {
        if powerOn, launcher != nil { volumeKeys.enable() }
    }

    /// A volume key press while Knob is the output: 2% instead of macOS's 6%, with Knob's popup.
    private func stepVolume(_ direction: Int) {
        let next = min(max(Int((volume * 100).rounded()) + direction * VolumeKeys.step, 0), 100)
        setVolume(Double(next) / 100)
        VolumeOSD.show(volume: Double(next) / 100, muted: next == 0 && muted)
    }

    /// Turns Knob back on at launch if it was ON when it was last quit. Real engine only.
    func restorePower() {
        guard launcher != nil, UserDefaults.standard.bool(forKey: PersistKey.powerOn.rawValue) else { return }
        Task {
            await refresh()
            if !powerOn && !starting { setPower(true) }
        }
    }

    /// An engine is already answering that this copy of Knob didn't start: left over from the
    /// previous version after an update or a crash. Reusing it is what made the first start after
    /// installing or updating fail, so an installed Knob replaces it. (Dev copies keep theirs on
    /// purpose, so relaunching on every save doesn't restart the sound.)
    var isStaleEngine: Bool {
        guard let launcher else { return false }
        return connection == .online && !launcher.isRunning
            && Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true
    }

    func startEngine() async {
        guard let launcher else { return }
        starting = true
        startupFailure = nil
        notice = "Starting the sound engine..."
        defer { starting = false }
        let physical = HardwareDevices.preferredPhysicalOutput()
        trace("POWER", "Starting the engine for \(outputName(physical?.uid)). The Mac's output is \(systemOutputName).")
        if isStaleEngine { await retireEngine(keepingLauncher: false) }
        let session = Self.sessionURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        // Two tries: a fresh engine every time, because a first start that can't get audio flowing
        // (right after installing or updating) works on the second.
        // An older audio device than this app carries: update it first (one password prompt).
        if DriverInstaller.installedIsOutdated {
            trace("POWER", "Not started: the installed audio device is older than this app's.")
            canInstallDevice = true
            notice = "Knob's audio device has an update that matches your Mac's volume steps. Install it to continue."
            wantsOn = false
            return
        }
        for attempt in 1...2 {
            do {
                try await launcher.start(preset: session ?? currentPreset?.url)
                canInstallDevice = false
            } catch EngineLauncher.Problem.deviceMissing where DriverInstaller.bundledDriver != nil {
                canInstallDevice = true
                notice = "Knob needs to install its audio device first."
                wantsOn = false
                return
            } catch {
                trace("POWER", "The engine could not start: \(error.localizedDescription)")
                switch error as? EngineLauncher.Problem {
                case .permissionDenied: showStartupFailure(.audioAccess)
                case .noOutput: showStartupFailure(.outputUnavailable)
                case .deviceMissing, .helpersMissing:
                    notice = error.localizedDescription
                default: showStartupFailure(.engineUnavailable)
                }
                wantsOn = false
                return
            }
            for _ in 0..<50 where connection != .online {
                try? await Task.sleep(for: .milliseconds(200))
                await refresh()
                if !launcher.isRunning { break }
            }
            if connection == .online {
                _ = await succeeds("setBypass", ["value": false])
                for _ in 0..<40 where !routingActive {   // the engine makes itself the output once audio flows
                    try? await Task.sleep(for: .milliseconds(200))
                    await refreshState(includeControls: true)
                    if !launcher.isRunning { break }
                }
                if routingActive {
                    VolumeHandoff.takeOver(from: physical)
                    notice = nil   // started: the "Starting the sound engine..." message goes away
                    trace("POWER", "Knob is ON, on try \(attempt).")
                    logAudioHealth(after: "turning ON")
                    return
                }
                trace("POWER", "Try \(attempt): the engine answers but did not become the Mac's output.")
                if attempt == 2 { break }
            }
            trace("POWER", "Try \(attempt) failed (engine \(connection == .online ? "online" : "not answering")), starting a fresh engine.")
            notice = "Starting the sound engine again..."
            await retireEngine(keepingLauncher: false)
            try? await Task.sleep(for: .seconds(1))
        }
        if connection == .online && launcher.isRunning {
            await takeOverOutput(followingSystem: false)   // last resort; explains if it fails
            if routingActive { return }
        }
        // Capture the failure before stopping the partial launch. OFF must really mean off.
        let diagnostic = launcher.startupFailure
        let failure: StartupFailure = diagnostic == .engineUnavailable && launcher.isRunning ? .routing : diagnostic
        trace("POWER", "Knob could not turn ON: \(failure).")
        await retireEngine(keepingLauncher: false)
        powerOn = false
        wantsOn = false
        showStartupFailure(failure)
    }

    func retryStartup() {
        guard !starting else { return }
        Self.rememberPower(true)
        setPower(true) // Re-enumerates devices and chooses the Mac's current physical output.
    }

    func openStartupSettings() {
        guard let failure = startupFailure else { return }
        Platform.open(failure.settingsURL)
    }

    func openEngineLog() {
        guard let url = EngineLog.url else { return }
        Platform.open(url)
    }

    /// Stops whatever engine is running without saving over the user's session, waits until it
    /// is really gone, and gives the speakers back.
    private func retireEngine(keepingLauncher: Bool) async {
        trace("POWER", "Retiring the running engine.")
        _ = await succeeds("activateRouting", ["value": false])
        _ = await succeeds("shutdown", [:])
        if !keepingLauncher { launcher?.stop() }
        VolumeHandoff.giveBack()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if (try? await engine.send("getState", [:])) == nil { break }
        }
        connection = .offline
        routingActive = false
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
            Self.rememberPower(true)
            wantsOn = true
            await startEngine()
        }
    }

    /// Makes Knob the Mac's output (playing through the output the user picked last), carrying
    /// the volume over so nothing jumps.
    func takeOverOutput(followingSystem: Bool) async {
        if followingSystem { await followSystemOutput() }
        let physical = outputUID.flatMap(HardwareDevices.device(uid:))
        trace("OUTPUT", "Taking the Mac's output, playing through \(outputName(outputUID)).")
        for attempt in 1...15 {   // the engine refuses until audio is flowing again after an output change
            if await succeeds("activateRouting", ["value": true]) {
                VolumeHandoff.takeOver(from: physical)
                notice = nil
                await refreshState()
                trace("OUTPUT", "Took the Mac's output on try \(attempt). The Mac's output is \(systemOutputName).")
                logAudioHealth(after: "taking the output")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        trace("OUTPUT", "Gave up taking the Mac's output after 15 tries.")
        logAudioHealth(after: "failing to take the output")
        notice = "Knob couldn't take over the sound output. Try again."
    }

    /// If the user picked different speakers in the Sound menu, play there.
    private func followSystemOutput() async {
        let current = HardwareDevices.defaultOutputID
        guard let device = HardwareDevices.all().first(where: { $0.id == current && $0.isPhysicalOutput }),
              device.uid != outputUID else { return }
        trace("OUTPUT", "Following the Sound menu from \(outputName(outputUID)) to \(outputName(device.uid)).")
        if await succeeds("setOutputUID", ["outputUID": device.uid]) { outputUID = device.uid }
    }

    /// Something else became the Mac's output (the Sound menu, or the engine stopping).
    /// Give the volume back right away; if Knob is meant to be on, take over again on the new output.
    private func defaultOutputChanged() {
        trace("OUTPUT", "The Mac's output is now \(systemOutputName) (Knob wants ON: \(wantsOn), switching: \(switchingOutput), engine \(connection == .online ? "online" : "offline")).")
        guard !knobIsOutput else { return }
        VolumeHandoff.giveBack()
        routingActive = false
        guard !switchingOutput else { return }
        powerOn = false
        guard wantsOn, connection == .online, !reclaiming, !starting else { return }
        reclaiming = true
        Task {
            await takeOverOutput(followingSystem: true)
            reclaiming = false
        }
    }

    // MARK: Logging

    private func trace(_ stage: String, _ message: String) { KnobShiftLog.append(stage: stage, message: message) }

    private func outputName(_ uid: String?) -> String {
        guard let uid else { return "no output" }
        return outputs.first { $0.uid == uid }?.name ?? HardwareDevices.outputDevices().first { $0.uid == uid }?.name ?? uid
    }

    private var systemOutputName: String {
        let id = HardwareDevices.defaultOutputID
        guard let device = HardwareDevices.all().first(where: { $0.id == id }) else { return "unknown" }
        return device.uid == HardwareDevices.knobUID ? "Knob" : outputName(device.uid)
    }

    /// What the engine reports a moment after a change, and each device's volume and mute: enough
    /// to tell from the log whether sound reached the output and where it stopped. Reads only.
    private func logAudioHealth(after change: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            guard let root = (try? await engine.send("getState", [:])) as? [String: Any] else {
                trace("HEALTH", "After \(change): the engine is not answering.")
                return
            }
            let metrics = root["metrics"] as? [String: Any] ?? [:]
            func metric(_ key: String) -> String { metrics[key].map { "\($0)" } ?? "?" }
            let uid = root["outputUID"] as? String
            let physical = uid.flatMap(HardwareDevices.device(uid:))
            let knob = HardwareDevices.device(uid: HardwareDevices.knobUID)
            func level(_ device: HardwareDevice?) -> String {
                guard let device else { return "missing" }
                let volume = HardwareDevices.volume(of: device.id).map { "\(Int(($0 * 100).rounded()))%" } ?? "no volume"
                return HardwareDevices.isMuted(device.id) == true ? "\(volume), muted" : volume
            }
            trace("HEALTH", "After \(change): plays through \(outputName(uid)), the Mac's output is \(systemOutputName), "
                + "routing \(root["routingActive"] ?? "?"), ready \(metric("ready")), private path \(metric("privatePath")), "
                + "\(metric("outputSampleRate")) Hz, rendered \(metric("renderedFrames")), delivered \(metric("deliveredFrames")), "
                + "underruns \(metric("underruns")), peaks \(metric("peakLeft")) and \(metric("peakRight")), "
                + "output volume \(level(physical)), Knob volume \(level(knob)).")
        }
    }

    /// Headphones, a Bluetooth speaker or a display came or went: the Output menu lists what is
    /// there now. A Bluetooth device appears a moment before it can tell its name, so the list
    /// is read again shortly after.
    private func devicesChanged() {
        Task { [weak self] in
            for wait in [300, 1_500] {
                try? await Task.sleep(for: .milliseconds(wait))
                await self?.refreshOutputs()
            }
        }
    }

    /// The outputs from the engine while it runs, or straight from the Mac while it is off.
    func refreshOutputs() async {
        var latest = HardwareDevices.outputDevices()
        if connection == .online, let json = try? await engine.send("getDevices", [:]) {
            latest = OutputDevice.list(json: json)
        }
        guard latest != outputs else { return }
        outputs = latest
        knobShift.log("OUTPUT", "Outputs now: \(latest.map(\.name).joined(separator: ", ")).")
    }

    private var knobIsOutput: Bool {
        HardwareDevices.device(uid: HardwareDevices.knobUID)?.id == HardwareDevices.defaultOutputID
    }

    /// Saves the current sound, hands the Mac its normal output back (with Knob's volume),
    /// then stops the engine.
    func stopEngine() async {
        guard launcher != nil, connection == .online else { return }
        trace("POWER", "Stopping the engine and handing the output back.")
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
        startupFailure = nil
        trace("POWER", "Knob is OFF. The Mac's output is \(systemOutputName).")
    }

    func quit() {
        Task {
            await stopEngine()
            NSApp.terminate(nil)
        }
    }

    /// Plays through the output picked in Knob's menu. Switching hands the Mac its old output
    /// back for a moment, so while Knob is ON it takes the output again on the new device.
    func selectOutput(_ device: OutputDevice) {
        guard !switchingOutput, device.uid != outputUID else {
            trace("OUTPUT", "You picked \(device.name), ignored: \(switchingOutput ? "a switch is still running" : "it is already the output").")
            return
        }
        trace("OUTPUT", "You picked \(device.name), switching from \(outputName(outputUID)).")
        let wasOn = powerOn || wantsOn
        let previous = outputUID
        outputUID = device.uid
        switchingOutput = true
        Task {
            defer { switchingOutput = false }
            if await succeeds("setOutputUID", ["outputUID": device.uid]) {
                notice = nil
                // Make it the Mac's output underneath Knob too, so OFF, quitting and the next ON
                // all use the device picked here, not the one that was playing before.
                if let hardware = HardwareDevices.device(uid: device.uid) { HardwareDevices.setDefaultOutput(hardware.id) }
                trace("OUTPUT", "The engine now plays through \(device.name).")
            } else {
                trace("OUTPUT", "The engine could not switch to \(device.name), staying on \(outputName(previous)).")
                outputUID = previous
                notice = "Knob couldn't switch to \(device.name). It is still playing on the previous output."
            }
            if wasOn {
                wantsOn = true
                await takeOverOutput(followingSystem: false)
            }
            await refreshState()
        }
    }
}
#endif
