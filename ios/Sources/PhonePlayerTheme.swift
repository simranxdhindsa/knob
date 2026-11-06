import SwiftUI

/// The player is dark in both themes, like KnobShift on the Mac: only white text can sit on the
/// cover's real colours spread over the whole screen, and light text colours would need a pale
/// wash over them. This is the one place on iPhone that fixes the theme (ios/check-theme.sh).
extension View {
    func darkPlayer() -> some View {
        environment(\.colorScheme, .dark)
    }

    /// The status bar and sheets go dark with the player, once the opening has finished, so the
    /// opening still matches the phone's launch screen.
    func darkWindow(after opening: Bool) -> some View {
        preferredColorScheme(opening ? nil : .dark)
    }
}
