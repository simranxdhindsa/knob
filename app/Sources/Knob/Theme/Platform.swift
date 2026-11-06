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

    /// A file path that stays the same across installs, for keys saved with a file. On the iPhone
    /// the app's own folders move on every install or update, so the part before them is left
    /// out ("~/Documents/KnobShift/..."); `relocated` finds the file again from either form. On
    /// the Mac paths never move and stay as they are.
    static func portable(_ path: String) -> String {
        #if os(macOS)
        path
        #else
        let inApp = ["/Documents/", "/Library/", "/tmp/"].compactMap { path.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        guard let inApp else { return path }
        return "~" + path[inApp.lowerBound...]
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
    /// Turns off the Mac list's own selection highlight, which is always the system's colour
    /// whatever the tint, so rows can draw theirs. The iPhone's lists select nothing here.
    func hidesListHighlight(selected: Int) -> some View {
        #if os(macOS)
        background(ListHighlightOff(selected: selected))
        #else
        self
        #endif
    }

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

#if os(macOS)
/// Reaches the table behind the SwiftUI list beside it. `selected` changes with the selection,
/// which puts the setting back should the list ever restore its own.
private struct ListHighlightOff: NSViewRepresentable {
    let selected: Int

    final class Coordinator {
        weak var table: NSTableView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let found = context.coordinator
        DispatchQueue.main.async { [weak view] in
            // The search only runs until the table is found, not on every update.
            if let table = found.table, table.window != nil {
                table.selectionHighlightStyle = .none
                return
            }
            var ancestor = view?.superview
            while let current = ancestor {
                if let table = Self.table(in: current) {
                    table.selectionHighlightStyle = .none
                    found.table = table
                    return
                }
                ancestor = current.superview
            }
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = table(in: child) { return table }
        }
        return nil
    }
}
#endif
