import SwiftUI

/// Times as the players show them: minutes and seconds.
enum KnobShiftNowPlaying {
    static func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

/// Where the player's Play button is on screen, so the iPhone opening can land its knob on it.
struct PlayButtonFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct HidesPlayButtonKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Hides the player's Play button while the iPhone opening's knob is becoming it.
    var hidesPlayButton: Bool {
        get { self[HidesPlayButtonKey.self] }
        set { self[HidesPlayButtonKey.self] = newValue }
    }
}
