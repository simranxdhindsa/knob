import SwiftUI

/// Listen Together inside the player, not in a window of its own: one glass bar over the player
/// says who is sharing or listening, holds the line up for Bluetooth and who is listening, and
/// leaves. The player beneath shows the shared music with all its usual effects.
struct TogetherBar: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var session = KnobShiftTogetherSession.shared
    /// Milliseconds this device's sound can wait for the others, for Bluetooth that sounds late.
    private static let lineUps = [0, 50, 100, 150, 200, 250, 300, 400]

    var body: some View {
        Group {
            if isOn {
                bar
            } else if let status = session.status {
                note(status)
            }
        }
        .animation(Motion.gentle, value: isOn)
        .animation(Motion.gentle, value: session.status)
    }

    private var isOn: Bool {
        switch session.role {
        case .hosting, .listening: true
        default: false
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.pulse, isActive: session.role == .hosting && session.people.isEmpty)
                .accessibilityHidden(true)
            Text(session.status ?? heading)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text).lineLimit(1)
                .contentTransition(.opacity)
            options
            Button(session.role == .hosting ? "End" : "Leave") { session.leave() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.accent)
                .padding(.horizontal, 10)
                .frame(minHeight: QueueRowStyle.tap)
                .contentShape(Rectangle())
                .accessibilityLabel(session.role == .hosting ? "End Listen Together for everyone" : "Leave Listen Together")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 40)
        .playerGlassCapsule()
        .transition(.opacity.combined(with: .offset(y: -8)))
    }

    private var options: some View {
        Menu {
            if session.role == .hosting { TogetherDeviceItems(model: model) }
            if session.role == .hosting, !session.people.isEmpty {
                Section("Listening") {
                    ForEach(session.people, id: \.self) { name in
                        Button { session.remove(name) } label: { Label("Remove \(name)", systemImage: "person.crop.circle.badge.minus") }
                    }
                }
            }
            Section("If this device sounds late, as Bluetooth does, wait here") {
                Picker(selection: lineUp) {
                    ForEach(Self.lineUps, id: \.self) { ms in
                        Label(ms == 0 ? "No wait" : "\(ms) ms", systemImage: ms == 0 ? "speaker.wave.2" : "timer").tag(ms)
                    }
                } label: {
                    Label("Line Up", systemImage: "timer")
                }
                .pickerStyle(.menu)
            }
            if let preset = session.presetName {
                Section("Shared sound") {
                    Label(preset, systemImage: "slider.vertical.3")
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel("Listen Together options")
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Glass.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button { session.clearStatus() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Glass.secondary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(maxWidth: 360, minHeight: 40)
        .playerGlassCapsule()
        .transition(.opacity.combined(with: .offset(y: -8)))
    }

    private var heading: String {
        if case .listening(let name) = session.role { return "Listening to \(name)" }
        let count = session.people.count
        return count == 0 ? (session.invited.isEmpty ? "Listen Together is on" : "Asked \(session.invited.sorted().joined(separator: ", "))") : (count == 1 ? "\(session.people[0]) is listening" : "\(count) listening")
    }

    private var lineUp: Binding<Int> {
        Binding(get: { Int((session.lineUp * 1000).rounded()) }, set: { session.lineUp = Double($0) / 1000 })
    }
}

/// Listen Together in the dots menu: choose a device to listen with. A device already sharing
/// is joined; any other is asked to join while this one starts sharing.
struct TogetherMenuItems: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var session = KnobShiftTogetherSession.shared

    var body: some View {
        switch session.role {
        case .off:
            Menu {
                TogetherDeviceItems(model: model)
                Section {
                    Button { session.startHosting(model) } label: { Label("Start Without Asking", systemImage: "dot.radiowaves.left.and.right") }
                }
            } label: {
                Label("Listen Together", systemImage: "hifispeaker.2")
            }
        case .hosting:
            Menu {
                TogetherDeviceItems(model: model)
            } label: {
                Label("Ask Another Device", systemImage: "person.badge.plus")
            }
            Button { session.leave() } label: { Label("End Listen Together", systemImage: "xmark.circle") }
        case .listening:
            Button { session.leave() } label: { Label("Leave Listen Together", systemImage: "xmark.circle") }
        default:
            EmptyView()
        }
    }
}

/// Every other Knob open nearby, to listen with: in the dots menu and on the Listen Together bar.
struct TogetherDeviceItems: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var session = KnobShiftTogetherSession.shared
    @ObservedObject private var playOn = KnobShiftPlayOnSession.shared

    var body: some View {
        let devices = session.devices.filter { !session.people.contains($0) }
        Section(devices.isEmpty ? "Open Knob on another device nearby" : "Listen with") {
            ForEach(devices, id: \.self) { name in
                Button { session.listen(with: name, model: model) } label: {
                    Label(title(name), systemImage: session.invited.contains(name) ? "checkmark.circle" : Self.icon(name))
                }
            }
        }
    }

    private func title(_ name: String) -> String {
        if session.role == .off, session.isSharing(name) { return "Join \(name)" }
        if session.invited.contains(name) { return "Ask \(name) Again" }
        return name
    }

    static func icon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("mac") { return "laptopcomputer" }
        return "hifispeaker"
    }
}
