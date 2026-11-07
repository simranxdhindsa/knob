import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI

/// The iPhone's own volume, between its speaker marks. Apple's volume slider is the one way an app
/// may set it, so it moves with the volume buttons and shows no volume banner. The simulator has
/// no such slider, so there it shows the same look on Knob's own level.
struct PhoneVolumeRow: View {
    let knob: KnobModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            slider
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(Glass.secondary)
    }

    @ViewBuilder private var slider: some View {
        #if targetEnvironment(simulator)
        PhoneSimulatorVolume(knob: knob)
        #else
        PhoneDeviceVolume()
        #endif
    }
}

#if targetEnvironment(simulator)
struct PhoneSimulatorVolume: View {
    @ObservedObject var knob: KnobModel

    var body: some View {
        KnobGroove(value: knob.volume, showsCap: true, accessibilityLabel: "Volume", accessibilityValue: "\(Int(knob.volume * 100))",
                   onChange: { knob.setVolume($0) })
    }
}
#endif

/// The iPhone's volume: Knob draws the line and its handle as one piece from the real level, and
/// Apple's slider lies invisibly on top to take the finger. Apple's own drawing leaves a gap
/// between its line and a custom handle.
struct PhoneDeviceVolume: View {
    @ObservedObject private var level = PhoneOutputLevel.shared

    var body: some View {
        ZStack {
            KnobGroove(value: level.volume, showsCap: true, accessibilityLabel: "", accessibilityValue: "", onChange: { _ in })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(Motion.snappy, value: level.volume)
            PhoneSystemVolume()
        }
        .onAppear { level.read() }
    }
}

/// Apple's volume slider with nothing of its own showing, the handle kept the size of GrooveCap
/// so a finger on the cap is on the slider's handle.
struct PhoneSystemVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        let track = Self.clear(CGSize(width: 13, height: 5)).resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        view.setMinimumVolumeSliderImage(track, for: .normal)
        view.setMaximumVolumeSliderImage(track, for: .normal)
        view.setVolumeThumbImage(Self.clear(CGSize(width: GrooveCap.size, height: 30)), for: .normal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    private static func clear(_ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in }
    }
}

/// The iPhone's volume as it changes, by the buttons, the slider or Control Center.
@MainActor
final class PhoneOutputLevel: ObservableObject {
    static let shared = PhoneOutputLevel()
    @Published private(set) var volume = 0.0
    private var watching: NSKeyValueObservation?

    private init() {
        read()
        watching = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            DispatchQueue.main.async { self?.read() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    func read() { volume = Double(AVAudioSession.sharedInstance().outputVolume) }
}

/// Where the music plays. Apple's list can't show Knob's devices, so this opens Knob's own list,
/// with Apple's picker (AirPlay, headphones, speakers) as a row inside it.
struct PhoneOutputButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "airplayaudio").font(.system(size: 20)).foregroundStyle(Glass.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose where the music plays")
    }
}

struct PhoneRoutePicker: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = UIColor(Palette.accent)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) { view.tintColor = UIColor(tint) }
}

/// Where the sound is going, when that isn't the iPhone's own speaker.
@MainActor
final class PhoneOutputName: ObservableObject {
    static let shared = PhoneOutputName()
    @Published private(set) var name: String?

    private init() {
        read()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func read() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        name = output?.portType == .builtInSpeaker ? nil : output?.portName
    }
}
