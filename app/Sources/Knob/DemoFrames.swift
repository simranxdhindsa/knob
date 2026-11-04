import AppKit
import SwiftUI

/// `Knob --demo-frames DIR`: records the real panel offscreen, driven by the demo engine, as a
/// numbered PNG sequence at 30 frames a second (frame-00000.png ...). A scripted story turns the
/// volume knob, switches preset, raises the bass on the EQ and starts a KnobShift mix, so the
/// README demo video is made from Knob's own rendering, springs and live meters.
@MainActor
enum DemoFrames {
    static let fps = 30.0

    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        model.start()
        let presets = Preset.factory()
        let start = presets.first(where: { $0.name == "Music" }) ?? presets.first
        if let start { model.select(start) }
        UserDefaults.standard.set(ScreenSection.Tab.effects.rawValue, forKey: PersistKey.selectedTab.rawValue)

        Task { @MainActor in
            await model.refresh()
            model.panelOpened()
            model.setVolume(0.45)
            try? await Task.sleep(for: .milliseconds(900))

            let host = NSHostingView(rootView: PanelView(model: model).environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host

            let effectsFrom = model.effects
            let effectsTo = [0.8, 0.6, 0.7, 0.4, 0.9]
            let next = presets.first { $0.name != start?.name }
            let total = Int(12.5 * fps)

            for frame in 0..<total {
                let t = Double(frame) / fps
                // The story, by time in seconds.
                model.setVolume(0.45 + 0.33 * ease(t, from: 1.5, to: 3.5))
                if frame == Int(4.0 * fps), let next { model.select(next) }
                if t >= 4.0 && t <= 5.2 {
                    let p = ease(t, from: 4.0, to: 5.0)
                    for slot in EffectSlot.allCases where effectsFrom.indices.contains(slot.rawValue) {
                        let from = effectsFrom[slot.rawValue]
                        model.setEffect(slot, from + (effectsTo[slot.rawValue] - from) * p)
                    }
                }
                if frame == Int(6.0 * fps) {
                    UserDefaults.standard.set(ScreenSection.Tab.equalizer.rawValue, forKey: PersistKey.selectedTab.rawValue)
                }
                if t >= 6.5 && t <= 8.2 {
                    let p = ease(t, from: 6.5, to: 8.0)
                    model.setEQ(band: 0, 0.5 * p)
                    model.setEQ(band: 1, 0.42 * p)
                    model.setEQ(band: 2, 0.2 * p)
                }
                if frame == Int(9.0 * fps) {
                    model.knobShift.showPreviewForSnapshot(mixing: false)
                    UserDefaults.standard.set(ScreenSection.Tab.knobShift.rawValue, forKey: PersistKey.selectedTab.rawValue)
                }
                if frame == Int(10.5 * fps) { model.knobShift.showPreviewForSnapshot(mixing: true) }

                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(1 / fps))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = folder.appendingPathComponent(String(format: "frame-%05d.png", frame))
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            print("wrote \(total) frames to \(folder.path)")
            model.knobShift.stop()
            model.panelClosed()
            exit(0)
        }
        app.run()
    }

    /// 0 before `from`, 1 after `to`, a smooth ease in and out between.
    private static func ease(_ t: Double, from: Double, to: Double) -> Double {
        let x = min(max((t - from) / (to - from), 0), 1)
        return x * x * (3 - 2 * x)
    }
}
