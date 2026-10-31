import SwiftUI

/// A deliberately quiet entry point in Knob's sound-control panel. KnobShift itself lives in a
/// dedicated player window so transport and queue controls never crowd the effects screen.
struct KnobShiftScreen: View {
    @ObservedObject var model: KnobShiftModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 2)
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Palette.accent)
                .shadow(color: Palette.accentGlow.opacity(0.5), radius: 8)
            VStack(spacing: 4) {
                Text("KNOBSHIFT")
                    .font(.system(size: 12, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Screen.text)
                Text("Your local-music transition player opens separately.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Screen.textSecondary)
            }
            Button {
                KnobShiftWindow.show(model: model)
            } label: {
                Label("OPEN KNOBSHIFT", systemImage: "music.note.list")
                    .font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Capsule().fill(Palette.accent))
                    .shadow(color: Palette.accentGlow.opacity(0.55), radius: 6)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
