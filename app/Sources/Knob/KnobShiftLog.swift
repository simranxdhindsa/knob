#if os(macOS)
import AppKit
#endif
import Foundation

/// Developer diagnostics for KnobShift: every analysis step, plan decision, deck change and
/// envelope step. Written beside engine.log (~/Library/Logs/Knob, or "Knob (dev)" for the dev
/// copy) on a background queue, so logging never delays playback or the UI. Kept under 1 MB:
/// the previous log moves to knobshift.old.log.
enum KnobShiftLog {
    static var url: URL? {
        #if os(macOS)
        EngineLog.url?.deletingLastPathComponent().appendingPathComponent("knobshift.log")
        #else
        // The iPhone app has no engine log: its own Library/Logs.
        URL.libraryDirectory.appendingPathComponent("Logs/knobshift.log")
        #endif
    }

    private static let writer = Writer()

    /// 12-hour with AM/PM, as everywhere in Knob, plus milliseconds for envelope timing.
    /// One formatter for every line: making a new one per line was slow when spotDL prints
    /// thousands of them. DateFormatter is safe to share across threads.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, h:mm:ss.SSS a"
        return formatter
    }()

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }

    /// Sections become heading lines; every other entry lines up in time, stage, message columns.
    static func append(stage: String, message: String, at date: Date = Date()) {
        if stage == "SECTION" {
            writer.write("\n━━━ \(message) ━━━  \(stamp(date))\n")
        } else {
            let column = stage.padding(toLength: max(9, stage.count), withPad: " ", startingAt: 0)
            writer.write("\(stamp(date))  \(column)  \(message)\n")
        }
    }

    #if os(macOS)
    static func open() {
        guard let url else { return }
        writer.flush {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }
    #endif

    /// All file state lives on one serial queue.
    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "io.github.simranxdhindsa.knob.knobshift-log")
        private var handle: FileHandle?
        private var written = 0

        func write(_ line: String) {
            queue.async { self.append(Data(line.utf8)) }
        }

        func flush(then done: @escaping @Sendable () -> Void) {
            queue.async {
                self.append(Data())
                done()
            }
        }

        private func append(_ data: Data) {
            guard let url = KnobShiftLog.url else { return }
            if handle == nil || written > 1 << 20 { reopen(url) }
            guard !data.isEmpty else { return }
            try? handle?.write(contentsOf: data)
            written += data.count
        }

        private func reopen(_ url: URL) {
            let files = FileManager.default
            try? handle?.close()
            handle = nil
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20 {
                let old = url.deletingLastPathComponent().appendingPathComponent("knobshift.old.log")
                try? files.removeItem(at: old)
                try? files.moveItem(at: url, to: old)
            }
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            written = Int((try? handle?.seekToEnd()) ?? 0)
        }
    }
}
