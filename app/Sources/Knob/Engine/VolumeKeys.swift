import AppKit
import ApplicationServices

/// Finer volume keys while Knob is the output. macOS always moves the volume keys in 1/16 steps
/// (about 6%) and no audio device can change that, so Knob catches volume up and down itself and
/// moves 2% instead. Everything else passes straight through: mute, keys with modifiers held
/// (Option + Shift keeps macOS's own quarter steps), and every key while Knob isn't the output.
/// Catching keys needs Accessibility permission, asked for once, the first time Knob is ON.
@MainActor
final class VolumeKeys {
    static let step = 2

    /// True while volume keys should be Knob's (Knob is ON and the Mac's output).
    var isActive: () -> Bool = { false }
    /// Called with +1 (up) or -1 (down) for each press and key repeat.
    var onStep: (Int) -> Void = { _ in }

    private var tap: CFMachPort?
    private var retry: Timer?

    /// Installs the key tap, asking for permission the first time. Safe to call repeatedly.
    func enable() {
        guard tap == nil else { return }
        let asked = UserDefaults.standard.bool(forKey: PersistKey.askedKeyAccess.rawValue)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !asked] as CFDictionary
        UserDefaults.standard.set(true, forKey: PersistKey.askedKeyAccess.rawValue)
        guard AXIsProcessTrustedWithOptions(options) else {
            // Permission can be granted in System Settings at any time: pick it up when it is.
            guard retry == nil else { return }
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.retry?.invalidate()
                    self.retry = nil
                    self.enable()
                }
            }
            return
        }
        install()
    }

    private func install() {
        let mask = CGEventMask(1) << 14   // NX_SYSDEFINED: media and volume keys
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<VolumeKeys>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { keys.handle(type, event) }
        }, userInfo: refcon) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Runs on the main thread for every media key. Returning nil swallows the key.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let key = Self.volumeKey(event), isActive() else { return Unmanaged.passUnretained(event) }
        if key.pressed { onStep(key.up ? 1 : -1) }
        return nil
    }

    /// Volume up or down, pressed with no modifiers; nil for anything else.
    private static func volumeKey(_ event: CGEvent) -> (up: Bool, pressed: Bool)? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        guard code == 0 || code == 1 else { return nil }   // NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN
        guard ns.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty else { return nil }
        return (code == 0, (ns.data1 & 0xFF00) >> 8 == 0xA)
    }
}
