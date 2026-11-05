import Foundation

/// What `getState` reports, decoded from the engine's JSON.
struct EngineState {
    var bypassed = true
    var effects: [Double] = []          // 0...10, order matches `EffectSlot`
    var eq: [Double] = []               // dB, -12...12
    var frequencies: [Double] = []      // Hz
    var spectrum: [Double] = []         // raw band levels
    var outputUID: String?
    var routingActive = false
    var peakLeft = 0.0
    var peakRight = 0.0

    init() {}

    init(json: Any?) {
        guard let root = json as? [String: Any] else { return }
        let controls = root["controls"] as? [String: Any] ?? [:]
        let metrics = root["metrics"] as? [String: Any] ?? [:]
        bypassed = controls["bypassed"] as? Bool ?? true
        effects = Self.numbers(controls["effects"])
        eq = Self.numbers(controls["eq"])
        frequencies = Self.numbers(controls["frequencies"])
        spectrum = Self.numbers(controls["spectrum"])
        outputUID = root["outputUID"] as? String
        routingActive = root["routingActive"] as? Bool ?? false
        peakLeft = (metrics["peakLeft"] as? NSNumber)?.doubleValue ?? 0
        peakRight = (metrics["peakRight"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func numbers(_ value: Any?) -> [Double] {
        (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
    }
}

/// One physical output from `getDevices`.
struct OutputDevice: Hashable, Identifiable {
    let uid: String
    let name: String
    var id: String { uid }

    static func list(json: Any?) -> [OutputDevice] {
        (json as? [[String: Any]] ?? []).compactMap { device in
            guard let uid = device["uid"] as? String, let name = device["name"] as? String,
                  (device["outputs"] as? NSNumber)?.intValue ?? 0 > 0,
                  device["virtual"] as? Bool != true, !isSystemHelper(uid) else { return nil }
            return OutputDevice(uid: uid, name: name)
        }
    }

    /// The device macOS makes behind the scenes for an app's own player (KnobShift's): never
    /// something to pick as an output.
    static func isSystemHelper(_ uid: String) -> Bool { uid.hasPrefix("CADefaultDeviceAggregate") }
}

/// The five effects, in the engine's order. `parameter` is the engine's name for it.
enum EffectSlot: Int, CaseIterable, Identifiable {
    case clarity, ambience, surround, dynamicBoost, bass
    var id: Int { rawValue }
    var parameter: String { ["fidelity", "ambience", "surround", "dynamicBoost", "bass"][rawValue] }
    /// Display name, as people know these effects.
    var title: String { ["Clarity", "Ambience", "Surround Sound", "Dynamic Boost", "Bass Boost"][rawValue] }
}
