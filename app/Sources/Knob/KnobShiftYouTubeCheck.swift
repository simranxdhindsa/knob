import AppKit
import Foundation

/// `--knobshift-youtube-check selftest` checks KnobShift's YouTube import without the network
/// (KnobShiftYouTubeTests).
@MainActor
enum KnobShiftYouTubeCheck {
    static func run(_ arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            if arguments.first == "selftest" {
                KnobShiftYouTubeTests.run()
                exit(KnobShiftYouTubeTests.failures == 0 ? 0 : 1)
            }
            exit(0)
        }
        app.run()
    }
}
