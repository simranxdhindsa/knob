import Foundation

/// The iPhone's side of the panel model (the Mac's is KnobModel+MacEngine.swift). Knob's sound
/// runs inside the app, so there is no engine to start or stop, no audio device to install and
/// one output: ON and OFF only switch the effects in and out, and the current sound is kept in
/// the same session file the Mac uses.
extension KnobModel {
    var keepsSession: Bool { true }
    var stopsWhenOff: Bool { false }
    var isStaleEngine: Bool { false }

    /// Brings back the sound saved last time.
    func startPlatform() {
        guard let session = Self.sessionURL, FileManager.default.fileExists(atPath: session.path) else { return }
        Task { _ = await succeeds("setPreset", ["path": session.path]) }
    }

    func volumeChanged(_ volume: Double, controllable: Bool) {}

    func poweredOn() {}

    func startEngine() async {
        await refresh()
        guard wantsOn else { return }
        _ = await succeeds("setBypass", ["value": false])
        await refreshState(includeControls: true)
    }

    func stopEngine() async {}

    func takeOverOutput(followingSystem: Bool) async {}

    /// Turns the effects back on if they were on when the app last ran.
    func restorePower() {
        guard UserDefaults.standard.bool(forKey: PersistKey.powerOn.rawValue) else { return }
        Task {
            await refresh()
            if !powerOn { setPower(true) }
        }
    }

    /// The iPhone picks its own output (speaker, headphones, AirPods) from Control Center.
    func selectOutput(_ device: OutputDevice) {}

    // The panel offers these only when the Mac engine fails to start or its audio device is
    // missing, which cannot happen inside the iPhone app.
    func retryStartup() { setPower(true) }
    func installAudioDevice() {}
    func openStartupSettings() {}
    func openEngineLog() {}
    func quit() {}
}
