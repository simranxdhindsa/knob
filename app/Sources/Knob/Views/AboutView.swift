import AppKit
import SwiftUI

/// Knob's About window, built like the panel: grained faceplate, engraved labels, recessed pills.
/// Shows what the AGPL requires for an app with a user interface: free software, no warranty,
/// and where the source is.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat = AboutView.size.width
    /// Shown inside the panel: a back button at the top left (and Escape) returns to the controls.
    var onBack: (() -> Void)? = nil

    static let size = CGSize(width: 340, height: 452)

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 0) {
            AppIconView(size: 132)
                .padding(.top, 22)
            Text("knob")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(p.label)
                .shadow(color: scheme == .dark ? .black.opacity(0.6) : .white, radius: 0, y: 1)
            Text("Studio sound for every output on your Mac.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(p.muted)
                .padding(.top, 2)
            Text(version)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(p.label)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(RecessedPill())
                .padding(.top, 12)

            VStack(spacing: 4) {
                EngravedLabel(text: "DESIGNED AND BUILT BY", size: 9)
                Text("Simran Dhindsa")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .shadow(color: Palette.accentGlow.opacity(0.45), radius: 6)
            }
            .padding(.top, 20)

            Spacer(minLength: 14)

            VStack(spacing: 4) {
                Text("Free software under the GNU Affero General Public License v3.")
                Text("It comes with no warranty. The complete source code is included inside the app.")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(p.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(width: width, height: Self.size.height)
        .overlay(alignment: .topLeading) {
            if let onBack {
                Button(action: onBack) {
                    Label("BACK", systemImage: "chevron.left")
                        .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RecessedPill())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to Knob's controls")
                .padding(14)
            }
        }
        .background {
            ZStack {
                LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom)
                Grain(opacity: p.grain)
            }
            .ignoresSafeArea()
        }
    }
}

/// Opens the About window (one at a time), in front of other apps.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            let created = NSWindow(contentViewController: host)
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.setContentSize(AboutView.size)
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
