import AppKit
import SwiftUI

/// Wordmark, the power switch and the app menu.
struct HeaderBar: View {
    @ObservedObject var model: KnobModel
    @AppStorage(PersistKey.showInDock.rawValue) private var showInDock = true
    @ObservedObject private var updater = Updater.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("knob")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(p.muted)
                    .shadow(color: scheme == .dark ? .black.opacity(0.6) : .white, radius: 0, y: 1)
                    .accessibilityAddTraits(.isHeader)
                Text("v\(Self.version)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p.faint)
                    .accessibilityLabel("Version \(Self.version)")
                UpdateStatusLabel(status: updater.status)
                    .animation(Motion.gentle, value: updater.status)
            }
            Spacer(minLength: 6)
            PowerSwitch(isOn: Binding(get: { model.powerOn }, set: { model.userSetPower($0) }), label: "Sound effects")
                .disabled(model.starting)
            Menu {
                Button("About Knob") { AboutWindow.show() }
                if Updater.shared.isAvailable {
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                }
                Toggle("Show in Dock", isOn: $showInDock)
                Divider()
                Button("Quit Knob") { model.quit() }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(p.label)
                    .frame(width: 24, height: 24)
                    .background(RecessedPill())
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Knob menu")
            .onChange(of: showInDock) { _, shown in DockPresence.apply(shown) }
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// Preset picker with previous/next buttons, like the preset strip on studio gear, plus a save
/// button that turns the strip into a name field, and (for the user's own presets) a delete
/// button that turns it into an inline confirmation. Confirmations stay inside the strip: a
/// dialog can take focus from the menu bar panel and close it.
struct PresetBar: View {
    @ObservedObject var model: KnobModel
    @State private var naming = false
    @State private var confirmingDelete: Preset?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            if let preset = confirmingDelete {
                Text("Delete \u{201C}\(preset.name)\u{201D}?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.of(scheme).label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                    .background(RecessedPill())
                Button {
                    model.deletePreset(preset)
                    confirmingDelete = nil
                } label: {
                    Text("DELETE")
                        .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete preset \(preset.name)")
                HardwareIconButton(systemImage: "xmark", label: "Keep preset") { confirmingDelete = nil }
            } else if naming {
                TextField("Name your preset", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.of(scheme).label)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RecessedPill())
                    .focused($nameFocused)
                    .onSubmit(save)
                    .onExitCommand { naming = false }
                HardwareIconButton(systemImage: "checkmark", label: "Save preset", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                HardwareIconButton(systemImage: "xmark", label: "Cancel") { naming = false }
            } else {
                PillMenu(items: model.presets, selection: model.currentPreset, title: { $0.name },
                         placeholder: "Choose a preset") { model.select($0) }
                HardwareIconButton(systemImage: "chevron.left", label: "Previous preset") { model.stepPreset(-1) }
                HardwareIconButton(systemImage: "chevron.right", label: "Next preset") { model.stepPreset(1) }
                HardwareIconButton(systemImage: "square.and.arrow.down", label: "Save as a new preset") {
                    name = ""
                    naming = true
                    nameFocused = true
                }
                if let preset = model.currentPreset, preset.isUser {
                    HardwareIconButton(systemImage: "trash", label: "Delete this preset") { confirmingDelete = preset }
                }
            }
        }
        .disabled(model.connection != .online)
    }

    private func save() {
        let chosen = name
        Task {
            if await model.savePreset(named: chosen) { naming = false }
        }
    }
}
