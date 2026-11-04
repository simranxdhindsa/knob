import SwiftUI

/// A link box on the dark screen: a link icon inside, and one button at its end that pastes the
/// copied link while the box is empty and adds it once a link is in. Follows the 21st.dev Url
/// Input by ruixen.ui (an icon inside the field, the action at its end), rebuilt in SwiftUI. Used
/// by Add from Spotify and Add from YouTube.
struct LinkField: View {
    let placeholder: String
    @Binding var text: String
    var enabled: Bool
    var pasteHelp: String
    var addHelp: String
    var onPaste: () -> Void
    var onAdd: () -> Void

    @Environment(\.surface) private var surface

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(surface.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(surface.text)
                .tint(Palette.accent)
                .autocorrectionDisabled()
                .onSubmit(onAdd)
            Button(action: isEmpty ? onPaste : onAdd) {
                Label(isEmpty ? "PASTE" : "ADD", systemImage: isEmpty ? "doc.on.clipboard" : "plus")
                    .font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(Glass.onAccent)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(enabled ? Palette.accent : surface.tertiary.opacity(0.4)))
                    .contentTransition(.opacity)
                    .animation(Motion.snappy, value: isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(isEmpty ? pasteHelp : addHelp)
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 34)
        .background(Capsule().fill(surface.fill))
        .overlay(Capsule().strokeBorder(surface.stroke, lineWidth: 1))
    }
}
