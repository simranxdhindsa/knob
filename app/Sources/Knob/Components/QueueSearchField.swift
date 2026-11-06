import SwiftUI

/// The queue's search box: a recessed pill with a magnifier, the typed text and a clear button.
/// Reference: 21st.dev "HeroUI Search Field" (hero_ui), rebuilt in SwiftUI. Escape clears the text
/// on the Mac, and a second Escape lets go of the box so the list gets the keys again.
struct QueueSearchField: View {
    @Binding var text: String
    var prompt = "Search songs or artists"
    @Environment(\.surface) private var surface
    @FocusState private var focused: Bool

    #if os(iOS)
    private let height: CGFloat = 44
    #else
    private let height: CGFloat = 28
    #endif

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused || !text.isEmpty ? Palette.accent : surface.tertiary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(surface.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(surface.text)
                .focused($focused)
                .focusEffectDisabled()
                .onEscapeKey {
                    if text.isEmpty { focused = false } else { text = "" }
                }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .accessibilityLabel("Search the queue")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(surface.tertiary)
                        .frame(width: height, height: height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -10)
                .help("Clear the search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(Capsule().fill(surface.fill))
        .overlay(Capsule().stroke(focused ? Palette.accent.opacity(0.6) : surface.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}
