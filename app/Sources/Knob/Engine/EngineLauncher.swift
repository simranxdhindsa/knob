import AVFoundation
import Foundation

/// Starts and stops knob-engine through knob-supervisor (both in Knob.app/Contents/Helpers).
/// The supervisor puts the user's previous output back whenever the engine stops or crashes.
@MainActor
final class EngineLauncher {
    enum Problem: LocalizedError {
        case helpersMissing, deviceMissing, noOutput, permissionDenied, launchFailed

        /// Plain-language text shown on the panel.
        var errorDescription: String? {
            switch self {
            case .helpersMissing: "This copy of Knob is missing its sound engine. Rebuild Knob."
            case .deviceMissing: "Knob's audio device isn't installed yet."
            case .noOutput: "There are no speakers or displays to play through."
            case .permissionDenied: "Knob needs audio access. Allow it in System Settings, Privacy & Security, Microphone."
            case .launchFailed: "The sound engine couldn't start. Try again."
            }
        }
    }

    private var supervisor: Process?
    private var launchLogOffset: UInt64?
    private var launchOutputUID: String?

    var startupFailure: StartupFailure {
        if let uid = launchOutputUID, HardwareDevices.device(uid: uid) == nil { return .outputUnavailable }
        guard let offset = launchLogOffset, let url = EngineLog.url,
              let handle = try? FileHandle(forReadingFrom: url) else { return .engineUnavailable }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: 1 << 20) ?? Data()
            return StartupFailure.diagnose(log: String(decoding: bytes, as: UTF8.self)) ?? .engineUnavailable
        } catch { return .engineUnavailable }
    }

    var isRunning: Bool { supervisor?.isRunning == true }

    func start(preset: URL?) async throws {
        launchLogOffset = nil
        launchOutputUID = nil
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let engine = helpers.appendingPathComponent("knob-engine")
        let supervisorURL = helpers.appendingPathComponent("knob-supervisor")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: engine.path), files.isExecutableFile(atPath: supervisorURL.path)
        else { throw Problem.helpersMissing }
        guard HardwareDevices.all().contains(where: { $0.uid == HardwareDevices.knobUID }) else { throw Problem.deviceMissing }
        guard let output = HardwareDevices.preferredPhysicalOutput() else { throw Problem.noOutput }
        launchOutputUID = output.uid
        guard await Self.audioAccess() else { throw Problem.permissionDenied }

        // The supervisor restores whatever output was current when it started, so make sure
        // that is real hardware and not some other virtual device.
        if !HardwareDevices.all().contains(where: { $0.id == HardwareDevices.defaultOutputID && $0.isPhysicalOutput }) {
            HardwareDevices.setDefaultOutput(output.id)
        }

        var arguments = ["--engine", engine.path, "--output", output.uid, "--activate"]
        let fallback = Bundle.main.resourceURL?.appendingPathComponent("presets/Default.fac")
        if let preset { arguments += ["--preset", preset.path] }
        if let fallback, files.fileExists(atPath: fallback.path) { arguments += ["--fallback-preset", fallback.path] }

        let process = Process()
        process.executableURL = supervisorURL
        process.arguments = arguments
        // The supervisor and the engine it runs write their errors here (the engine inherits it).
        if let log = EngineLog.open(note: "Starting the sound engine for output \(output.uid)") {
            launchLogOffset = log.offsetInFile
            process.standardOutput = log
            process.standardError = log
        }
        do { try process.run() } catch { throw Problem.launchFailed }
        supervisor = process
    }

    /// Asks the supervisor to stop: it restores the previous output, then stops the engine.
    func stop() {
        guard let process = supervisor else { return }
        supervisor = nil
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit() }
    }

    private static func audioAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// ~/Library/Logs/Knob/engine.log: everything the engine and supervisor print, so a stop or
/// crash can be explained afterwards. Also visible in the Console app under Log Reports.
/// Kept under 1 MB: the previous log moves to engine.old.log.
enum EngineLog {
    static var url: URL? {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        return logs.appendingPathComponent("Logs/\(isDev ? "Knob (dev)" : "Knob")/engine.log")
    }

    static func open(note: String) -> FileHandle? {
        guard let url else { return nil }
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20 {
            let old = url.deletingLastPathComponent().appendingPathComponent("engine.old.log")
            try? files.removeItem(at: old)
            try? files.moveItem(at: url, to: old)
        }
        if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        let stamp = DateFormatter()
        stamp.dateFormat = "MMM d, h:mm:ss a"   // 12-hour with AM/PM, as everywhere in Knob
        let line = "\n=== \(stamp.string(from: Date())): \(note) ===\n"
        handle.write(Data(line.utf8))
        return handle
    }
}
