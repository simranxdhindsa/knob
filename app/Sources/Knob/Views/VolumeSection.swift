import SwiftUI

/// The big volume knob, plus output choice and the live level meter.
struct VolumeSection: View {
    @ObservedObject var model: KnobModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 4) {
                EngravedLabel(text: "VOLUME", size: 12)
                RealisticKnob(value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                              size: 150,
                              accessibilityLabel: "Volume",
                              accessibilityValue: "\(Int((model.volume * 100).rounded())) percent")
                    .disabled(!model.volumeControllable)
                volumeReadout(p)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                EngravedLabel(text: "OUTPUT")
                PillMenu(items: model.outputs, selection: model.outputs.first { $0.uid == model.outputUID },
                         title: { $0.name }, placeholder: "No output") { model.selectOutput($0) }
                    .disabled(model.connection != .online)
                EngravedLabel(text: "LEVEL").padding(.top, 6)
                LevelMeter(left: model.peakLeft, right: model.peakRight, height: 74)
            }
            .frame(width: 128)
            .padding(.top, 2)
        }
    }

    private func volumeReadout(_ p: Palette) -> some View {
        HStack(spacing: 6) {
            Button(action: model.toggleMute) {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(model.muted ? Palette.accent : p.muted)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.muted ? "Unmute" : "Mute")
            if model.volumeControllable {
                NumericValueField(value: Binding(get: { model.volume * 100 }, set: { model.setVolume($0 / 100) }),
                                  range: 0...100, label: "Volume", unit: "percent", fontSize: 12,
                                  fractionDigits: 0)
                    .frame(width: 42)
                Text("%").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.label)
            } else {
                Text("Fixed").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.label)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RecessedPill())
        .help(model.volumeControllable ? "Volume" : "This output has no volume control. Turn Knob on to control it.")
    }
}
