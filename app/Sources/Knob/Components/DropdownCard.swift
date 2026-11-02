import SwiftUI

/// Knob's dropdown card, opened by a plain button in a popover: the ••• menu in the panel and
/// ADD MUSIC in KnobShift. Native menus there did not open on a mouse click in the installed app,
/// so these cards stand in for them. The look follows the 21st.dev Dropdown Menu by originui
/// (menu with icons): a rounded card, an icon and a label on each row, a soft highlight under
/// the pointer. The popover closes on a click outside or Escape.
struct DropdownCard<Content: View>: View {
    var width: CGFloat = 220
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 2) { content() }
            .padding(6)
            .frame(width: width)
            .background(LinearGradient(colors: [p.panelTop, p.panelBottom], startPoint: .top, endPoint: .bottom))
    }
}

/// One row: an icon, a name, an optional short line under it and an optional mark at the end
/// (a tick, a shortcut).
struct DropdownRow<Icon: View>: View {
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        Button(action: action) {
            HStack(spacing: 10) {
                icon().frame(width: 20, height: 20).foregroundStyle(p.label)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.label)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(p.faint)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, detail == nil ? 6 : 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? p.label.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}

/// A thin line between groups of rows.
struct DropdownDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(Palette.of(scheme).label.opacity(0.1)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }
}
