import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI

/// The iPhone's own volume, between its speaker marks. It is Apple's volume slider redrawn to
/// match the player, the one way an app may set it, so it moves with the volume buttons and shows
/// no volume banner. The simulator has no such slider, so there it shows the same look on Knob's
/// own level.
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
        PhoneSystemVolume()
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

/// Apple's volume slider with its track and handle drawn as images, the way it allows.
struct PhoneSystemVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.setMinimumVolumeSliderImage(Self.track(Palette.accent), for: .normal)
        view.setMaximumVolumeSliderImage(Self.track(Glass.fill), for: .normal)
        let cap = ImageRenderer(content: GrooveCap().padding(4))
        cap.scale = 3
        view.setVolumeThumbImage(cap.uiImage, for: .normal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    private static func track(_ color: Color) -> UIImage {
        let size = CGSize(width: 13, height: 5)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(color).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2.5).fill()
        }
        .resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
    }
}

/// Apple's own output picker (AirPlay, headphones, speakers), orange while sound goes elsewhere.
struct PhoneOutputButton: View {
    var body: some View {
        PhoneRoutePicker(tint: Glass.secondary)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Choose where the sound plays")
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
