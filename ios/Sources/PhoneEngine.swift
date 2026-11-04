import Foundation
import UIKit

/// Knob's sound engine inside the iPhone app. It answers the same commands with the same reply
/// shapes as the Mac's knob-engine (engine/command-dispatcher.mm), so the shared panel model
/// works unchanged; the sound itself runs in PhoneEffectUnit after KnobShift's mix.
final class PhoneEngine: SoundEngine, @unchecked Sendable {
    /// The one output: whatever the iPhone plays through (speaker, headphones, AirPods).
    static let outputUID = "iphone"

    let dsp: OpaquePointer
    /// Control calls wait for the audio thread to step aside, so they never run on the main thread.
    private let queue = DispatchQueue(label: "knob.phone.engine")

    init() { dsp = knob_phone_dsp_create() }

    deinit { knob_phone_dsp_destroy(dsp) }

    func send(_ command: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let arguments = Arguments(values: arguments)
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: Reply(value: try self.run(command, arguments.values))) }
                catch { continuation.resume(throwing: error) }
            }
        }
        return reply.value
    }

    /// JSON values cross from the control queue as they are; nothing else holds them.
    private struct Arguments: @unchecked Sendable { let values: [String: Any] }
    private struct Reply: @unchecked Sendable { let value: Any? }

    private func run(_ command: String, _ arguments: [String: Any]) throws -> Any? {
        switch command {
        case "getDevices":
            return [["uid": Self.outputUID, "name": "iPhone", "outputs": 2, "virtual": false]]
        case "getState", "getMeters":
            var left: Float = 0, right: Float = 0
            knob_phone_dsp_peaks(dsp, &left, &right)
            return ["controls": try controls(), "outputUID": Self.outputUID, "routingActive": true,
                    "metrics": ["peakLeft": Double(left), "peakRight": Double(right)]]
        case "setBypass":
            knob_phone_dsp_bypass(dsp, (arguments["value"] as? Bool ?? true) ? 1 : 0)
        case "setParam":
            guard let name = arguments["name"] as? String, let value = (arguments["value"] as? NSNumber)?.doubleValue else {
                throw EngineError(message: "setParam needs a name and a value")
            }
            try check { knob_phone_dsp_parameter(dsp, name, value, $0, $1) }
        case "setParams":
            for (name, value) in arguments["params"] as? [String: NSNumber] ?? [:] {
                try check { knob_phone_dsp_parameter(dsp, name, value.doubleValue, $0, $1) }
            }
        case "setPreset":
            guard let path = arguments["path"] as? String else { throw EngineError(message: "setPreset needs a path") }
            try check { knob_phone_dsp_preset(dsp, path, $0, $1) }
        case "savePreset":
            guard let path = arguments["path"] as? String else { throw EngineError(message: "savePreset needs a path") }
            try check { knob_phone_dsp_save_preset(dsp, path, $0, $1) }
        case "setNumEqBands":
            let count = (arguments["count"] as? NSNumber)?.int32Value ?? 10
            try check { knob_phone_dsp_bands(dsp, count, $0, $1) }
        case "setOutputUID", "activateRouting", "shutdown":
            // One output, always Knob's: nothing to switch or hand back.
            break
        default:
            throw EngineError(message: "unknown command")
        }
        return nil
    }

    /// The controls as the Mac engine reports them.
    private func controls() throws -> Any {
        var buffer = [CChar](repeating: 0, count: 4096)
        let needed = knob_phone_dsp_state(dsp, &buffer, buffer.count)
        if needed > buffer.count {
            buffer = [CChar](repeating: 0, count: needed)
            _ = knob_phone_dsp_state(dsp, &buffer, buffer.count)
        }
        return try JSONSerialization.jsonObject(with: Data(String(cString: buffer).utf8))
    }

    private func check(_ call: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 256)
        let failed = error.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) } != 0
        if failed { throw EngineError(message: String(cString: error)) }
    }
}
