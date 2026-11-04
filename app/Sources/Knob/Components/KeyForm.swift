import SwiftUI

/// A numbered step in the "use your own key" cards (Spotify and Google).
struct KeyFormStep: View {
    @Environment(\.surface) private var surface
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number)").font(.system(size: 9.5, weight: .bold).monospacedDigit()).foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 10.5)).foregroundStyle(surface.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// A recessed pill field for a key's Client ID, or (secure) its secret, which is never shown.
struct KeyFormField: View {
    @Environment(\.surface) private var surface
    let label: String
    var secure = false
    @Binding var text: String

    var body: some View {
        Group {
            if secure { SecureField(label, text: $text) } else { TextField(label, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11.5).monospaced())
        .foregroundStyle(surface.text)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(surface.fill))
        .overlay(Capsule().strokeBorder(surface.stroke, lineWidth: 1))
        .accessibilityLabel(label)
    }
}
