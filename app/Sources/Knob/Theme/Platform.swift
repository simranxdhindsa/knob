import SwiftUI
#if os(macOS)
import AppKit
/// A picture as each platform draws it: NSImage on the Mac, UIImage on the iPhone.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// The few things the Mac and iPhone apps do differently, in one place, so shared views and
/// state stay the same on both.
enum Platform {
    /// Opens a link, or on the Mac a file or settings page, in the app that handles it.
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// A saved file path made usable again. An iPhone app's folders move to a new place on every
    /// install or update (/var/mobile/Containers/Data/Application/<id>/, and the app itself under
    /// .../Bundle/Application/<id>/), so a path saved before then points at the old place; the
    /// same file is looked up under the app's current folders. On the Mac paths never move.
    static func relocated(_ path: String) -> String {
        #if os(macOS)
        path
        #else
        if FileManager.default.fileExists(atPath: path) { return path }
        if let app = path.range(of: ".app/") {
            return Bundle.main.bundlePath + "/" + path[app.upperBound...]
        }
        for folder in ["/Documents/", "/Library/", "/tmp/"] {
            if let found = path.range(of: folder) { return NSHomeDirectory() + path[found.lowerBound...] }
        }
        return path
        #endif
    }

    /// What people call this device, for sentences like "the files stay on your Mac".
    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    /// Fine adjustment for knobs and faders: Shift held on the Mac. A touch screen has no Shift,
    /// so the iPhone always turns at full speed.
    static var fineAdjust: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension View {
    /// The Delete key on the Mac. The iPhone has none: rows there are removed with their own
    /// buttons or the long press menu.
    func onDeleteKey(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onDeleteCommand(perform: action)
        #else
        self
        #endif
    }

    /// The Escape key on the Mac; the iPhone has none, so its views offer a Cancel button.
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
