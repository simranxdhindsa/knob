import SwiftUI

/// Knob's one dropdown: a native `Menu` dressed as a recessed hardware pill.
/// Use it for every choice list (presets, outputs). Never build another dropdown.
struct PillMenu<Item: Hashable>: View {
    let items: [Item]
    let selection: Item?
    let title: (Item) -> String
    let placeholder: String
    /// An SF Symbol beside each choice in the open menu.
    var icon: ((Item) -> String)? = nil
    let onSelect: (Item) -> Void

    @Environment(\.colorScheme) private var scheme

    /// The menu's label is a single piece of text that fills the whole pill, so a click anywhere
    /// on the pill opens the menu. (A label built from several views, an icon plus text, made
    /// SwiftUI split it into separate menu buttons, and clicking the name opened an empty menu.)
    /// The chevron and the pill are drawn around it and never take clicks.
    var body: some View {
        let p = Palette.of(scheme)
        Menu {
            ForEach(items, id: \.self) { item in
                if let icon {
                    // A toggle, so the chosen one keeps its tick beside its own icon.
                    Toggle(isOn: Binding(get: { item == selection }, set: { _ in onSelect(item) })) {
                        Label(title(item), systemImage: icon(item))
                    }
                } else {
                    Button { onSelect(item) } label: {
                        if item == selection { Label(title(item), systemImage: "checkmark") } else { Text(title(item)) }
                    }
                }
            }
        } label: {
            Text(selection.map(title) ?? placeholder)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(p.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 24)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(RecessedPill())
        .overlay(alignment: .leading) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(p.label)
                .padding(.leading, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The recessed rounded-rectangle used behind pills and small hardware buttons.
struct RecessedPill: View {
    var cornerRadius: CGFloat = 7
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(p.pillFill)
            .overlay(shape.stroke(p.pillStroke, lineWidth: 1))
            .overlay(shape.stroke(LinearGradient(colors: [Color.black.opacity(scheme == .dark ? 0.35 : 0.08), .clear],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1))
    }
}

/// A small square hardware button with an SF Symbol, matching the pills.
struct HardwareIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.of(scheme).label)
                .frame(width: 24, height: 24)
                .background(RecessedPill())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
