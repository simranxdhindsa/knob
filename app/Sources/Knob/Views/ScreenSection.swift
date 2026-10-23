import SwiftUI

/// The dark analyser screen: Effects and Equalizer tabs over the live spectrum.
struct ScreenSection: View {
    @ObservedObject var model: KnobModel
    @AppStorage(PersistKey.selectedTab.rawValue) private var tab = Tab.effects

    enum Tab: String, CaseIterable { case effects, equalizer }

    var body: some View {
        InsetScreen(glow: model.powerOn ? LevelMeter.position(max(model.peakLeft, model.peakRight)) : 0) {
            VStack(spacing: 10) {
                SegmentedTabs(options: Tab.allCases, selection: $tab) { $0 == .effects ? "EFFECTS" : "EQUALIZER" }
                ZStack {
                    SpectrumView(bands: model.spectrum, showsGrid: tab == .equalizer,
                                 intensity: tab == .effects ? 0.45 : 0.8)
                        .opacity((model.powerOn ? 1 : 0.35) * (tab == .equalizer ? 0.45 : 1))
                    if tab == .effects {
                        EffectsGrid(model: model)
                    } else {
                        EqualizerBank(model: model)
                    }
                }
                .frame(height: 176)
                .disabled(model.connection != .online)
                if let notice = model.notice {
                    statusNote(notice, attention: !model.starting,
                               showsInstall: model.canInstallDevice && !model.starting)
                } else if model.connection == .offline {
                    statusNote("Sound engine is off. Turn Knob on to start it.", attention: false)
                }
                if let failure = model.startupFailure, !model.starting {
                    HStack(spacing: 12) {
                        Button("Retry") { model.retryStartup() }
                        Button(failure == .audioAccess ? "Microphone Settings" : "Sound Settings") {
                            model.openStartupSettings()
                        }
                        Button("Open Log") { model.openEngineLog() }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Shown under the controls (never instead of them): engine status, or why it couldn't start.
    private func statusNote(_ text: String, attention: Bool, showsInstall: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle().fill(attention ? Palette.accent : Screen.textTertiary).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if showsInstall {
                Button { model.installAudioDevice() } label: {
                    Text("INSTALL")
                        .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background(Capsule().fill(Palette.accent))
                        .shadow(color: Palette.accentGlow.opacity(0.6), radius: 5)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(attention ? Screen.text : Screen.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Five small knobs, one per effect.
struct EffectsGrid: View {
    @ObservedObject var model: KnobModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EffectSlot.allCases) { slot in
                VStack(spacing: 2) {
                    Text(slot.title.uppercased())
                        .font(.system(size: 8.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Screen.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 62, height: 22, alignment: .bottom)
                    RealisticKnob(value: Binding(get: { model.effects[slot.rawValue] }, set: { model.setEffect(slot, $0) }),
                                  size: 54, defaultValue: 0, showsMinMax: false, steps: 10,
                                  accessibilityLabel: slot.title,
                                  accessibilityValue: "\(Int((model.effects[slot.rawValue] * 10).rounded())) of 10",
                                  onEditingChanged: model.editingChanged)
                    NumericValueField(value: Binding(get: { model.effects[slot.rawValue] * 10 },
                                                     set: { model.setEffect(slot, $0 / 10) }),
                                      range: 0...10, label: slot.title,
                                      onEditingChanged: model.editingChanged)
                        .frame(width: 36)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One fader per EQ band, over the live spectrum.
struct EqualizerBank: View {
    @ObservedObject var model: KnobModel
    private let faderHeight: CGFloat = 106

    /// Placeholder faders shown (disabled) until the engine reports its real bands.
    private static let skeletonBands = 10

    var body: some View {
        if model.eq.isEmpty { skeleton } else { bank }
    }

    private var skeleton: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.skeletonBands, id: \.self) { _ in
                HardwareFader(value: .constant(0), height: faderHeight, accessibilityLabel: "Equalizer band",
                              accessibilityValue: "Unavailable")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 17)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .disabled(true)
    }

    /// Up to 12 bands share the screen's width; more scroll sideways inside it, never
    /// stretching the panel.
    @ViewBuilder private var bank: some View {
        if model.eq.count <= 12 {
            HStack(spacing: 0) { columns(width: nil) }
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) { columns(width: 30) }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Reads a band safely: when the engine drops from 31 bands to 10, SwiftUI can still ask a
    /// disappearing column for its value once, and a plain `eq[band]` crashed there.
    private func gain(_ band: Int) -> Double { model.eq[safe: band] ?? 0 }

    private func columns(width: CGFloat?) -> some View {
        ForEach(model.eq.indices, id: \.self) { band in
            VStack(spacing: 8) {
                NumericValueField(value: Binding(get: { gain(band) * 12 },
                                                 set: { model.setEQ(band: band, $0 / 12) }),
                                  range: -12...12, label: "\(Self.label(model.frequencies[safe: band])) hertz gain",
                                  unit: "dB", fontSize: 8,
                                  onEditingChanged: model.editingChanged)
                    .frame(width: 29)
                HardwareFader(value: Binding(get: { gain(band) }, set: { model.setEQ(band: band, $0) }),
                              height: faderHeight,
                              accessibilityLabel: "\(Self.label(model.frequencies[safe: band])) hertz",
                              accessibilityValue: String(format: "%+.1f dB", gain(band) * 12),
                              onEditingChanged: model.editingChanged)
                Text(Self.label(model.frequencies[safe: band]))
                    .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Screen.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
        }
    }

    /// Short frequency label: 32, 125, 1K, 1.3K, 6.3K, 16K.
    static func label(_ hertz: Double?) -> String {
        guard let hertz else { return "" }
        guard hertz >= 1000 else { return "\(Int(hertz.rounded()))" }
        let kilo = hertz / 1000
        if kilo >= 10 || kilo == kilo.rounded() { return "\(Int(kilo.rounded()))K" }
        return String(format: "%.1fK", kilo)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
