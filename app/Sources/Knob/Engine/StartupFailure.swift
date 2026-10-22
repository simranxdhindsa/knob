import Foundation

/// User-facing recovery guidance, based only on errors from the current launch attempt.
enum StartupFailure: CaseIterable {
    case audioAccess, outputUnavailable, audioTimeout, engineUnavailable, routing

    var message: String {
        switch self {
        case .audioAccess:
            "Knob needs audio access. Allow Knob in Microphone settings, then retry."
        case .outputUnavailable:
            "The sound output is unavailable. Connect your speakers or choose an output in Sound settings, then retry."
        case .audioTimeout:
            "Audio didn't start flowing. Check your output in Sound settings and Knob's Microphone access, then retry."
        case .engineUnavailable:
            "The sound engine couldn't start. Retry, or open the log for details."
        case .routing:
            "Knob couldn't take over the output. Choose an available output in Sound settings, then retry."
        }
    }

    var settingsURL: URL {
        URL(string: self == .audioAccess
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            : "x-apple.systempreferences:com.apple.preference.sound")!
    }

    static func diagnose(log: String) -> StartupFailure? {
        // Later engine failures take precedence; supervisor retry lines are not the cause.
        for line in log.split(separator: "\n").reversed() where line.hasPrefix("knob-engine:") {
            if line.contains("audio device unavailable:") { return .outputUnavailable }
            if line.contains("capture/render readiness timed out") { return .audioTimeout }
        }
        return nil
    }
}
