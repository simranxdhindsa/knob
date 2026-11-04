import SwiftUI

/// One of the three buttons along the bottom; orange while what it opens is on.
struct PhoneDeckButton: View {
    let systemImage: String
    let label: String
    var lit = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(lit ? Palette.accent : Glass.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPress())
        .accessibilityLabel(label)
    }
}

/// Opens Knob's sound (effects, equalizer and presets); lit while Knob's sound is on. Its own
/// view, so the sound model's changes redraw only this button.
struct PhoneSoundButton: View {
    @ObservedObject var knob: KnobModel
    let action: () -> Void

    var body: some View {
        PhoneDeckButton(systemImage: "slider.vertical.3", label: "Knob sound: effects, equalizer and presets", lit: knob.powerOn, action: action)
    }
}
