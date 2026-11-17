#if os(macOS)
import AppKit
import SwiftUI

/// Tells a view whether its window can be seen: false when the window is minimised, hidden or
/// fully covered. SwiftUI keeps a minimised window's views alive and their timers running, so a
/// view with live work (the panel's meters) uses this to pause it.
struct WindowVisibility: NSViewRepresentable {
    /// Only minimising counts, not being covered by other windows: content dropped while hidden
    /// must never be lost just because another window went in front.
    var minimizedOnly = false
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.minimizedOnly = minimizedOnly
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.onChange = onChange
    }

    final class Reader: NSView {
        var onChange: ((Bool) -> Void)?
        var minimizedOnly = false
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = minimizedOnly
                ? [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
                : [NSWindow.didChangeOcclusionStateNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = minimizedOnly ? !window.isMiniaturized : window.occlusionState.contains(.visible)
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// A window's content that is dropped while the window is minimised and built again when it
/// comes back: SwiftUI keeps a minimised window's views alive, and the player's redrew and laid
/// the whole window out ten times a second with nobody to see it. A clear stand in of the same
/// size keeps the window from changing size.
struct WhileNotMinimized<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var shown = true
    @State private var size: CGSize = .zero

    var body: some View {
        ZStack {
            if shown {
                content()
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { size = geometry.size }
                            .onChange(of: geometry.size) { size = geometry.size }
                    })
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
        .background(WindowVisibility(minimizedOnly: true) { shown = $0 })
    }
}
#endif
