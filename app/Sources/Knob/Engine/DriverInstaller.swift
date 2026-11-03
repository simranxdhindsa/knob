import Foundation

/// Installs Knob's audio device from inside the app (Contents/Resources/Knob.driver), so a
/// drag-to-Applications install is complete: macOS asks for the password once, then the
/// Mac's audio service restarts and the device appears.
enum DriverInstaller {
    enum Problem: LocalizedError {
        case notBundled, cancelled, failed, didNotAppear

        var errorDescription: String? {
            switch self {
            case .notBundled: "This copy of Knob doesn't include its audio device. Rebuild Knob."
            case .cancelled: "Knob's audio device wasn't installed. Turn Knob on to try again."
            case .failed: "Knob's audio device couldn't be installed. Try again."
            case .didNotAppear: "The audio device was installed, but macOS hasn't loaded it yet. Try again in a moment."
            }
        }
    }

    /// True when the installed audio device is older than the one inside this app (its
    /// CFBundleVersion), so an update that changed how it sounds, like version 2's volume curve,
    /// reaches Macs that installed Knob before. App updates replace only the app.
    static var installedIsOutdated: Bool {
        guard let bundled = bundledDriver.flatMap({ version(of: $0) }),
              let installed = version(of: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Knob.driver")) else { return false }
        return installed < bundled
    }

    private static func version(of driver: URL) -> Int? {
        let info = driver.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info), let text = plist["CFBundleVersion"] as? String else { return nil }
        return Int(text)
    }

    static var bundledDriver: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Knob.driver"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static let script = """
    on run argv
        set source to quoted form of (item 1 of argv)
        set target to "/Library/Audio/Plug-Ins/HAL/Knob.driver"
        do shell script "rm -rf " & target & " && cp -R " & source & " " & target & ¬
            " && chown -R root:wheel " & target & " && killall coreaudiod" ¬
            with prompt "Knob needs to install its audio device." with administrator privileges
    end run
    """

    static func install() async throws {
        guard let source = bundledDriver else { throw Problem.notBundled }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script, source.path]
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                do { try process.run() } catch { continuation.resume(returning: -1); return }
                process.waitUntilExit()
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // osascript reports a cancelled password prompt as error -128.
                continuation.resume(returning: message.contains("-128") ? -128 : process.terminationStatus)
            }
        }
        if status == -128 { throw Problem.cancelled }
        guard status == 0 else { throw Problem.failed }
        for _ in 0..<50 {
            if HardwareDevices.device(uid: HardwareDevices.knobUID) != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw Problem.didNotAppear
    }
}
