import Foundation

/// The browser whose YouTube sign in downloads may borrow, chosen by the person and off until
/// then. Knob never reads it for an ordinary download: only after YouTube has blocked one does it
/// turn on, for the rest of that session (`KnobShiftModel.useBrowserAfterBlock`). yt-dlp reads the
/// sign in itself and only for YouTube; Knob never sees or keeps it.
enum KnobShiftYouTubeBrowser: String, CaseIterable, Identifiable {
    case off, chrome, brave, edge, firefox, safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    static var chosen: KnobShiftYouTubeBrowser {
        UserDefaults.standard.string(forKey: PersistKey.knobShiftYouTubeBrowser.rawValue).flatMap(Self.init) ?? .off
    }

    /// Browsers keep their sign in under the person's real home, not the helpers' own one.
    static var realHome: String { NSHomeDirectory() }
}
