import SwiftUI

/// On the iPhone the full KnobShift player is the main screen, where the Mac opens a window
/// (KnobShiftWindow.swift). The panel's mini player calls show(model:) the same way, which here
/// closes the sound sheet to reveal the player.
@MainActor
enum KnobShiftWindow {
    static func show(model: KnobShiftModel) { PhoneSheets.shared.sound = false }
}

/// Which sheet is open over the player.
@MainActor
final class PhoneSheets: ObservableObject {
    static let shared = PhoneSheets()
    @Published var sound = false
}
