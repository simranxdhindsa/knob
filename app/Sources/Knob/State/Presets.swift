import Foundation

/// A `.fac` preset file. Its display name is line 3 of the file, as the preset format defines.
struct Preset: Hashable, Identifiable {
    let name: String
    let url: URL
    var id: URL { url }

    /// This preset's menu icon. A factory preset has its own. A saved one gets a random looking
    /// pick from `customIcons`, worked out from its name so it never changes between launches.
    var icon: String {
        Preset.factoryIcons[name] ?? Preset.customIcons[name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF } % Preset.customIcons.count]
    }

    private static let factoryIcons = [
        "Default": "dial.medium", "General": "slider.horizontal.3", "Music": "music.note", "Voice": "mic",
        "Volume Boost": "speaker.wave.3", "Gaming": "gamecontroller", "Classic Processing": "waveform",
        "Light Processing": "waveform.path", "Bass Boost": "hifispeaker", "Streaming Video": "play.rectangle",
        "Movies": "film", "TV": "tv", "Transcription": "text.bubble"
    ]

    static let customIcons = [
        "star", "heart", "bolt", "flame", "leaf", "moon", "sun.max", "cloud", "drop", "snowflake",
        "sparkles", "crown", "guitars", "headphones", "pianokeys", "music.mic", "radio", "wand.and.stars",
        "paperplane", "car", "bicycle", "pawprint", "hare", "globe"
    ]

    /// Factory presets, then the user's own (alphabetical).
    static func all() -> [Preset] { factory() + user() }

    /// Presets the user saved: ~/Library/Application Support/<bundle id>/Presets/*.fac.
    static var userFolder: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
            .appendingPathComponent("Presets")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func user() -> [Preset] {
        guard let folder = userFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "fac" }
            .compactMap(load)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A file for a new user preset called `name`. Never overwrites: a taken name gets " 2", " 3"...
    /// Returns nil if the name has nothing usable in it.
    static func newUserFile(named name: String) -> URL? {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty, let folder = userFolder else { return nil }
        let taken = Set(all().map { $0.name.lowercased() })
        var candidate = cleaned
        var number = 2
        while taken.contains(candidate.lowercased())
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + ".fac").path) {
            candidate = "\(cleaned) \(number)"
            number += 1
        }
        return folder.appendingPathComponent(candidate + ".fac")
    }

    var isUser: Bool { Preset.userFolder.map { url.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL } ?? false }

    /// Factory presets shipped in the app bundle, in their numbered order (Default first).
    static func factory() -> [Preset] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("presets"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "fac" }
            .sorted { order($0) < order($1) }
            .compactMap(load)
    }

    private static func order(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "Default" ? 0 : Int(stem) ?? 1000
    }

    private static func load(_ url: URL) -> Preset? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1 << 20,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2, lines[0].hasPrefix("CLASS1") else { return nil }
        let name = lines[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : Preset(name: name, url: url)
    }
}
