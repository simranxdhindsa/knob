import SwiftUI

/// Native inline number entry, styled with Knob's shared palette.
/// Input reference: ReUI by Sean Hello, https://21st.dev/@sean0205/components/input (MIT).
/// Enter or leaving the field commits; Escape cancels. Live updates never replace a draft.
struct NumericValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var unit = ""
    var fontSize: CGFloat = 10
    /// Decimal places shown; volume uses 0 so it reads in whole percents.
    var fractionDigits = 1
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var original = ""
    @State private var editing = false
    @State private var invalid = false

    var body: some View {
        TextField(label, text: Binding(
            get: { editing ? draft : formatted(value) },
            set: { draft = $0; invalid = false }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
        .multilineTextAlignment(.center)
        .foregroundStyle(Palette.of(scheme).label)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 3).fill(Palette.of(scheme).pillFill))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(focused || invalid ? Palette.accent : .clear, lineWidth: 1))
        .focused($focused)
        .onChange(of: focused) { _, active in
            if active {
                draft = formatted(value)
                original = draft
                editing = true
                onEditingChanged(true)
            } else { finish(commit: true) }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { finish(commit: false); focused = false }
        }
        .onSubmit { finish(commit: true); focused = false }
        .onExitCommand { finish(commit: false); focused = false }
        .onDisappear { finish(commit: false) }
        .accessibilityLabel("\(label)\(unit.isEmpty ? "" : " in " + unit)")
        .help(invalid
              ? "Enter a number from \(formatted(range.lowerBound)) to \(formatted(range.upperBound))."
              : "Type \(label.lowercased())\(unit.isEmpty ? "" : " in " + unit). Enter to apply; Escape to cancel.")
    }

    private func formatted(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))
    }

    private func finish(commit: Bool) {
        guard editing else { return }
        if commit && isEnabled && draft != original {
            if let number = NumericEntry.parse(draft, range: range) { value = number }
            else { invalid = true }
        }
        editing = false
        onEditingChanged(false)
    }
}
