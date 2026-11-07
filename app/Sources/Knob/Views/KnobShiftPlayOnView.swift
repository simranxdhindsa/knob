import SwiftUI

/// Choosing where the music plays: this device or another Knob on the Wi-Fi, one at a time.
/// Apple offers no way to add devices to its own output list, so that list is a row in here.
struct KnobShiftPlayOnView: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var playOn = KnobShiftPlayOnSession.shared
    @ObservedObject private var together = KnobShiftTogetherSession.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Play On").font(.system(size: 20, weight: .bold)).foregroundStyle(Glass.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Glass.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            row("This \(Platform.deviceName)", icon: Platform.deviceName == "Mac" ? "laptopcomputer" : "iphone", status: here, selected: !together.isRemote) {
                if together.isRemote { playOn.bringBack() }
            }
            ForEach(playOn.devices) { device in
                row(device.name, icon: "hifispeaker", status: status(of: device), selected: playingOn == device.name) {
                    playOn.clearFailure()
                    playOn.move(to: device)
                }
                .disabled(together.isRemote && playingOn != device.name)
            }
            if playOn.devices.isEmpty {
                Text("No other devices yet. Open Knob on your other device, on the same Wi-Fi.")
                    .font(.system(size: 13)).foregroundStyle(Glass.secondary).fixedSize(horizontal: false, vertical: true)
            }
            #if os(iOS)
            HStack {
                Text("AirPlay and Bluetooth").font(.system(size: 14)).foregroundStyle(Glass.text)
                Spacer()
                PhoneRoutePicker(tint: Glass.secondary).frame(width: 44, height: 44).accessibilityLabel("Choose AirPlay or Bluetooth")
            }
            .padding(.horizontal, 12)
            .background(Glass.fill, in: RoundedRectangle(cornerRadius: 10))
            #endif
            if let receiving = playOn.receiving {
                Text(receiving).font(.system(size: 13)).foregroundStyle(Palette.accent)
            }
            if together.isRemote { KnobShiftTogetherView(model: model, embedded: true) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 420)
        .background(Glass.scrim)
        .environment(\.surface, .glass)
        .onAppear { playOn.startLooking() }
        .onDisappear { playOn.stopLooking() }
    }

    private var playingOn: String? {
        if case .remote(let name) = together.role { return name }
        return nil
    }

    private var here: String? {
        if let name = playingOn { return "Music is on \(name)" }
        return model.isPlaying ? "Playing here" : nil
    }

    private func status(of device: KnobShiftPlayOnSession.Device) -> String? {
        guard let handoff = playOn.handoff, handoff.device == device.name, handoff.stage != .idle else { return nil }
        return handoff.stage.text
    }

    private func row(_ name: String, icon: String, status: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(selected ? Palette.accent : Glass.text).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Glass.text).lineLimit(1)
                    if let status { Text(status).font(.system(size: 12)).foregroundStyle(Glass.secondary).lineLimit(2) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Glass.fill, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.map { "\(name), \($0)" } ?? name)
    }
}

/// The question a device asks the first time another wants to send music to it.
struct PlayOnAllowPrompt: ViewModifier {
    @ObservedObject private var playOn = KnobShiftPlayOnSession.shared

    func body(content: Content) -> some View {
        content.confirmationDialog("Allow \(playOn.asking ?? "this device") to play here?",
                                   isPresented: Binding(get: { playOn.asking != nil }, set: { if !$0, playOn.asking != nil { playOn.answerAsking(allow: false) } }),
                                   titleVisibility: .visible) {
            Button("Allow") { playOn.answerAsking(allow: true) }
            Button("Don't Allow", role: .cancel) { playOn.answerAsking(allow: false) }
        } message: {
            Text("It can play music here and copy songs to this device.")
        }
    }
}
