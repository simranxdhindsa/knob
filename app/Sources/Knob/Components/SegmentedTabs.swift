import SwiftUI

/// Port of the 21st.dev "Segmented Control" (halaska-studio, MIT): a sliding thumb animates
/// between options, arrow keys move the selection, and options read as a radio group.
/// Restyled as hardware screen buttons: the selected thumb carries a bright outline.
struct SegmentedTabs<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Namespace private var thumb
    @FocusState private var focused: Bool
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Text(title(option))
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .tracking(1.1)
                    .foregroundStyle(selected ? surface.text : surface.tertiary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(surface.thumb)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(surface.thumbStroke, lineWidth: 1))
                                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(option) }
                    .accessibilityElement()
                    .accessibilityLabel(title(option))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface.fill))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
    }

    private func select(_ option: Option) {
        withAnimation(Motion.segment) { selection = option }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(of: selection), !options.isEmpty else { return .ignored }
        select(options[(index + offset + options.count) % options.count])
        return .handled
    }
}
