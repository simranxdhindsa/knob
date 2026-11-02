import SwiftUI

/// The whole menu bar panel: a hardware faceplate holding every section.
struct PanelView: View {
    @ObservedObject var model: KnobModel
    @Environment(\.colorScheme) private var scheme
    /// About Knob opens inside the panel, with a back button, instead of in its own window.
    @State private var showingAbout = false

    static let width: CGFloat = 384

    var body: some View {
        Group {
            if showingAbout {
                AboutView(width: Self.width, onBack: { withAnimation(Motion.gentle) { showingAbout = false } })
                    .transition(.opacity)
            } else {
                controls.transition(.opacity)
            }
        }
        // The panel always opens on its controls.
        .onDisappear { showingAbout = false }
    }

    private var controls: some View {
        let p = Palette.of(scheme)
        return VStack(spacing: 14) {
            HeaderBar(model: model, onAbout: { withAnimation(Motion.gentle) { showingAbout = true } })
            PresetBar(model: model)
            VolumeSection(model: model)
            ScreenSection(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: Self.width)
        .background {
            ZStack {
                LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)
                Grain(opacity: p.grain)
                VStack {
                    Rectangle().fill(p.panelHighlight).frame(height: 1)
                    Spacer()
                }
            }
        }
        .redacted(reason: model.connection == .connecting ? .placeholder : [])
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }
}

/// Small uppercase engraved label used above every control.
struct EngravedLabel: View {
    let text: String
    var size: CGFloat = 11
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.of(scheme).label)
            .shadow(color: scheme == .dark ? .black.opacity(0.5) : .white.opacity(0.9), radius: 0, y: 1)
    }
}
