import AppKit
import Foundation

/// Runs one of KnobShift's bundled helper programs (spotDL for Spotify, yt-dlp for YouTube) as
/// its own process, off the main thread. Output arrives line by line, a job can be cancelled with
/// everything it started, a job that prints nothing for too long is stopped, and Knob quitting
/// stops every job. Each helper owns one runner, and its jobs are known by id.
final class KnobShiftHelperProcess: @unchecked Sendable {
    struct Result: Sendable {
        let status: Int32
        /// The helper's last lines, for working out what went wrong.
        let lines: [String]
        /// Stopped by `cancel` or Knob quitting.
        let cancelled: Bool
        /// Stopped because the helper printed nothing for too long.
        let stalled: Bool
    }

    /// The helper's name, for the log.
    let name: String
    private let lock = NSLock()
    private var running: [UUID: Process] = [:]
    /// Jobs stopped on purpose, so their result says so.
    private var cancelled: Set<UUID> = []

    init(name: String) {
        self.name = name
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cancelAll()
        }
    }

    // MARK: Stopping

    func isCancelled(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(id)
    }

    /// Stops a job and everything it started (the helpers run Python, which runs FFmpeg), so no
    /// helper keeps writing a half finished file after Knob stopped caring.
    func cancel(_ id: UUID) {
        lock.lock()
        let process = running[id]
        // Remembered even before the job starts, so a Cancel pressed that early still holds.
        cancelled.insert(id)
        lock.unlock()
        guard let process, process.isRunning else { return }
        Self.stopTree(process.processIdentifier, grace: 3)
    }

    func cancelAll() {
        lock.lock()
        let all = Array(running.values)
        cancelled.formUnion(running.keys)
        lock.unlock()
        // Knob is quitting: no time to wait politely.
        for process in all where process.isRunning { Self.stopTree(process.processIdentifier, grace: 0.3, wait: true) }
    }

    /// SIGTERM to a process and all its descendants (found before any of them exits, since
    /// orphans are handed to launchd), then SIGKILL to whatever is still alive after `grace`.
    static func stopTree(_ root: pid_t, grace: TimeInterval, wait: Bool = false) {
        let tree = descendants(of: root) + [root]
        for pid in tree { kill(pid, SIGTERM) }
        let finish = { for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        if wait {
            Thread.sleep(forTimeInterval: grace)
            finish()
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: finish)
        }
    }

    /// Children first, deepest last, so the list can be signalled in order.
    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var stack = [root]
        while let parent = stack.popLast() {
            var buffer = [pid_t](repeating: 0, count: 512)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            let children = buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && $0 != parent }
            found.append(contentsOf: children)
            stack.append(contentsOf: children)
        }
        return found
    }

    // MARK: Running

    /// Runs the helper and waits for it. Never blocks a thread on its output: the result comes
    /// once the process has exited and its output has ended, or 2 seconds after it exited when a
    /// stray child still holds the output open. `idleLimit` stops a job that prints nothing for
    /// that long (a stuck network call).
    func run(_ executable: URL, arguments: [String], environment: [String: String], id: UUID,
             idleLimit: TimeInterval?, onLine: @escaping @Sendable (String) -> Void) async -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collected = LineCollector(onLine: onLine)
        let ending = Ending()
        let stalled = Flag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let finish: @Sendable () -> Void = { [weak self] in
                guard let status = ending.takeResult() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.flush()
                var wasCancelled = false
                if let self {
                    self.lock.lock()
                    self.running[id] = nil
                    wasCancelled = self.cancelled.remove(id) != nil
                    self.lock.unlock()
                }
                continuation.resume(returning: Result(status: status, lines: collected.lines,
                                                      cancelled: wasCancelled, stalled: stalled.isSet))
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    ending.outputEnded()
                    finish()
                } else {
                    collected.append(data)
                }
            }
            process.terminationHandler = { finished in
                ending.exited(finished.terminationStatus)
                finish()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    ending.outputEnded()
                    finish()
                }
            }
            lock.lock()
            if cancelled.contains(id) {
                lock.unlock()
                ending.exited(-1)
                ending.outputEnded()
                finish()
                return
            }
            running[id] = process
            lock.unlock()
            do {
                try process.run()
            } catch {
                lock.lock()
                running[id] = nil
                lock.unlock()
                ending.exited(-1)
                ending.outputEnded()
                collected.append(Data("Could not start \(name): \(error.localizedDescription)\n".utf8))
                finish()
                return
            }
            if let idleLimit {
                let pid = process.processIdentifier
                Task.detached(priority: .utility) {
                    while process.isRunning {
                        try? await Task.sleep(for: .seconds(5))
                        if process.isRunning, Date().timeIntervalSince(collected.lastOutput) > idleLimit {
                            stalled.set()
                            Self.stopTree(pid, grace: 3)
                            return
                        }
                    }
                }
            }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Waits for both the exit and the end of output, and lets the result through once.
    private final class Ending: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var ended = false
        private var delivered = false

        func exited(_ value: Int32) { lock.lock(); status = value; lock.unlock() }
        func outputEnded() { lock.lock(); ended = true; lock.unlock() }

        func takeResult() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard let status, ended, !delivered else { return nil }
            delivered = true
            return status
        }
    }

    /// Splits a helper's output into lines without the colour codes of its terminal display. Only
    /// the last lines are kept: a download of thousands of songs prints thousands of them.
    final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var kept: [String] = []
        private var lastOutputAt = Date()
        private let onLine: @Sendable (String) -> Void
        private var sawBotCheck = false
        private var inDebugRecord = false
        static let keep = 300
        /// Kept in place of YouTube's own message, which spotDL prints in a DEBUG line.
        static let botCheckMarker = "Knob: YouTube asks to confirm this is not a bot (youtube_bot_check)."

        /// spotDL's DEBUG lines, "[17:39:20] DEBUG ...": read, never shown or kept.
        static func isDebug(_ line: String) -> Bool { level(line) == "DEBUG" || line.hasPrefix("DEBUG") }

        /// The level of a log record's first line ("[12:57:05] INFO MainThread - ..."), or nil
        /// for any other line.
        static func level(_ line: String) -> String? {
            guard let match = line.range(of: #"^\[\d{1,2}:\d{2}:\d{2}\] [A-Z]+"#, options: .regularExpression) else { return nil }
            return line[match].split(separator: " ").last.map(String.init)
        }

        /// A wrapped continuation of the record above it: spotDL indents those.
        static func isIndented(_ raw: String) -> Bool {
            let visible = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            return visible.hasPrefix("    ")
        }

        /// A record without its time, level, thread and source file, so the log reads as plain
        /// messages: "[12:57:05] INFO MainThread - Processing query: X   cli.py:73" becomes
        /// "Processing query: X".
        static func plain(_ line: String) -> String {
            guard level(line) != nil else { return line }
            let text = line.replacingOccurrences(of: #"^\[\d{1,2}:\d{2}:\d{2}\] [A-Z]+\s+\S+ - "#, with: "", options: .regularExpression)
            return text.replacingOccurrences(of: #"\s+[\w./-]+\.py:\d+$"#, with: "", options: .regularExpression)
        }

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        /// The bot check is said once, so it stays even after a long run pushes it out of `kept`.
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return sawBotCheck && !kept.contains(Self.botCheckMarker) ? kept + [Self.botCheckMarker] : kept
        }
        var lastOutput: Date { lock.lock(); defer { lock.unlock() }; return lastOutputAt }

        func append(_ data: Data) {
            lock.lock()
            lastOutputAt = Date()
            buffer.append(data)
            var ready: [String] = []
            while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                let clean = Self.clean(line)
                // YouTube's bot check: it refuses downloads until the Mac's connection cools down.
                if !sawBotCheck, clean.contains("not a bot") {
                    sawBotCheck = true
                    ready.append(Self.botCheckMarker)
                }
                // A log record starts "[12:57:05] LEVEL"; its wrapped lines start with spaces and
                // belong to it, so a DEBUG record is dropped whole, wrapped lines included.
                if let level = Self.level(clean) {
                    inDebugRecord = level == "DEBUG"
                } else if !Self.isIndented(line) {
                    inDebugRecord = false
                }
                if !clean.isEmpty, !inDebugRecord { ready.append(Self.plain(clean)) }
            }
            keep(ready)
            lock.unlock()
            ready.forEach(onLine)
        }

        func flush() {
            lock.lock()
            let rest = Self.clean(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
            if !rest.isEmpty { keep([rest]) }
            lock.unlock()
            if !rest.isEmpty { onLine(rest) }
        }

        private func keep(_ new: [String]) {
            kept.append(contentsOf: new)
            if kept.count > Self.keep { kept.removeFirst(kept.count - Self.keep) }
        }

        static func clean(_ line: String) -> String {
            line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
