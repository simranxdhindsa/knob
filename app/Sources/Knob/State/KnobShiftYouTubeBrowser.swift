import AppKit

/// The browser whose YouTube sign in downloads may borrow, chosen by the person and off until
/// then. Knob never reads it for an ordinary download: only after YouTube has blocked one does it
/// turn on, for the rest of that session (`KnobShiftModel.useBrowserAfterBlock`). yt-dlp reads the
/// sign in itself and only for YouTube; Knob never sees or keeps it.
enum KnobShiftYouTubeBrowser: String, CaseIterable, Identifiable {
    // Every browser yt-dlp can read. Arc is not one of them.
    case off, chrome, safari, firefox, edge, brave, opera, vivaldi, chromium, whale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .chromium: return "Chromium"
        case .whale: return "Whale"
        }
    }

    private var bundleId: String? {
        switch self {
        case .off: return nil
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .chromium: return "org.chromium.Chromium"
        case .whale: return "com.naver.Whale"
        }
    }

    /// What the picker offers: Off, the browsers this Mac has, and the current choice even if
    /// that browser has since been removed.
    static func choices(current: KnobShiftYouTubeBrowser,
                        installed: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> [KnobShiftYouTubeBrowser] {
        allCases.filter { $0 == .off || $0 == current || $0.bundleId.map(installed) == true }
    }

    static var chosen: KnobShiftYouTubeBrowser {
        UserDefaults.standard.string(forKey: PersistKey.knobShiftYouTubeBrowser.rawValue).flatMap(Self.init) ?? .off
    }

    /// Browsers keep their sign in under the person's real home, not the helpers' own one.
    static var realHome: String { NSHomeDirectory() }
}
