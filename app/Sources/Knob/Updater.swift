import AppKit
import Combine
import Sparkle

/// What the updater is doing right now, for the panel to show.
enum UpdateStatus: Equatable {
    case idle
    case checking
    /// `progress` is 0...1 when known. Sparkle's delegate doesn't report it, so it's nil for now.
    case downloading(progress: Double?)
    case installing
    /// Shown for a few seconds after a check that found nothing new, then back to idle.
    case upToDate
    case failed(message: String)

    /// Plain-language text for the panel; nil when there's nothing to say.
    var label: String? {
        switch self {
        case .idle: nil
        case .checking: "Checking for updates"
        case .downloading(let progress?): "Downloading update, \(Int((progress * 100).rounded()))%"
        case .downloading: "Downloading update"
        case .installing: "Installing update"
        case .upToDate: "Knob is up to date"
        case .failed(let message): message
        }
    }
}

/// Keeps Knob up to date from GitHub Releases (Sparkle). It checks at launch and every few hours,
/// downloads new versions quietly, checks their signature, then installs and relaunches straight
/// away: Knob lives in the menu bar and rarely quits, so waiting for a quit would mean never.
/// Off in dev builds (`npm run dev`) and in builds without a feed URL.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private var clearTask: Task<Void, Never>?

    @Published private(set) var status: UpdateStatus = .idle

    var isAvailable: Bool { controller != nil }

    func start() {
        let bundle = Bundle.main
        guard controller == nil,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              bundle.bundleIdentifier?.hasSuffix(".dev") == false else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// The quiet check, not Sparkle's window: a dialog takes focus from the menu bar panel and
    /// closes it. The panel's header shows the result, and an update downloads and installs as
    /// it does on the regular checks.
    func checkForUpdates() {
        controller?.updater.checkForUpdatesInBackground()
    }

    private func set(_ new: UpdateStatus) {
        clearTask?.cancel()
        status = new
        guard new == .upToDate else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }

    /// Sparkle calls its delegate on the main thread; hop explicitly so Swift agrees.
    private nonisolated func report(_ new: UpdateStatus) {
        Task { @MainActor in Updater.shared.set(new) }
    }

    /// A finished check with no update, or one the user cancelled, isn't a failure.
    private nonisolated func status(after error: Error) -> UpdateStatus {
        let error = error as NSError
        guard error.domain == SUSparkleErrorDomain else {
            return .failed(message: "Couldn't update Knob. It will try again later.")
        }
        switch error.code {
        case Int(SUError.noUpdateError.rawValue): return .upToDate
        case Int(SUError.installationCanceledError.rawValue): return .idle
        default: return .failed(message: "Couldn't update Knob. It will try again later.")
        }
    }

    /// Any message Sparkle does need to show (a password for a driver update, an error) appears
    /// without jumping in front of what the user is doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        report(.checking)
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        report(.upToDate)
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                             with request: NSMutableURLRequest) {
        report(.downloading(progress: nil))
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        report(.installing)
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        report(.installing)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        report(status(after: error))
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        if let error {
            report(status(after: error))
        } else {
            Task { @MainActor in
                if Updater.shared.status == .checking { Updater.shared.set(.idle) }
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        report(.installing)
        immediateInstallHandler()
        return true
    }
}
