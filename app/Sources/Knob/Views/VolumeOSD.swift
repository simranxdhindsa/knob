import AppKit
import SwiftUI

/// Knob's own volume popup for the volume keys. macOS shows its popup only for steps it makes
/// itself, so when Knob moves the volume in 2% steps it shows this instead: a small faceplate
/// with a speaker, an orange level groove and the percentage, at the top right of the screen
/// where macOS shows its own, fading out shortly after the last press.
@MainActor
enum VolumeOSD {
    private final class State: ObservableObject {
        @Published var volume = 0.0
        @Published var muted = false
        @Published var shown = false
    }

    private static let state = State()
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?
    private static let size = CGSize(width: 230, height: 48)

    static func show(volume: Double, muted: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10))
        }
        state.volume = volume
        state.muted = muted
        panel.orderFrontRegardless()
        withAnimation(Motion.snappy) { state.shown = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.gentle) { state.shown = false }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: Popup(state: state))
        return panel
    }

    private struct Popup: View {
        @ObservedObject var state: State
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let p = Palette.of(scheme)
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            HStack(spacing: 10) {
                Image(systemName: state.muted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.muted ? Palette.accent : p.label)
                    .frame(width: 20)
                groove(p)
                Text("\(Int((state.volume * 100).rounded()))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p.label)
                    .contentTransition(.numericText(value: state.volume))
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(width: size.width - 12, height: size.height - 12)
            .background(shape.fill(LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(Grain(opacity: p.grain).clipShape(shape))
            .overlay(shape.stroke(p.panelEdge, lineWidth: 1))
            .overlay(shape.inset(by: 1).stroke(p.panelHighlight, lineWidth: 0.5))
            .shadow(color: p.dropShadow, radius: 5, x: 0, y: 2)
            .opacity(state.shown ? 1 : 0)
            .scaleEffect(state.shown ? 1 : 0.96)
            .frame(width: size.width, height: size.height)
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((state.volume * 100).rounded())) percent")
        }

        /// A recessed horizontal groove with the orange fill, like the level meters.
        private func groove(_ p: Palette) -> some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.pillFill)
                        .overlay(Capsule().stroke(p.pillStroke, lineWidth: 0.5))
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.accent, Palette.accentGlow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * CGFloat(state.muted ? 0 : state.volume)))
                        .shadow(color: Palette.accentGlow.opacity(0.7), radius: 3)
                        .animation(Motion.snappy, value: state.volume)
                }
            }
            .frame(height: 6)
        }
    }
}
