import AppKit
import Sparkle

/// Public release identity only. This adapter never receives vault data or authentication.
public enum AppUpdateConfiguration {
    public static let feedURL = "https://update.honklegion.cz/apps/honkpass/appcast.xml"

    public static func isReady(_ info: [String: Any]) -> Bool {
        guard info["CFBundleIdentifier"] as? String == "cz.honklegion.honkpass",
              info["SUFeedURL"] as? String == feedURL,
              let key = info["SUPublicEDKey"] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.contains(where: { $0 != 0 }),
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUAllowsAutomaticUpdates"] as? Bool == true,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false else { return false }
        return true
    }
}

@MainActor
final class AppUpdateInstallationGate {
    private let prepare: () async -> Bool
    private let recover: () async -> Void
    private(set) var prepared = false
    private var preparing = false
    private var recovering = false
    private var generation = 0
    var isBusy: Bool { prepared || preparing || recovering }

    init(prepare: @escaping () async -> Bool, recover: @escaping () async -> Void) {
        self.prepare = prepare
        self.recover = recover
    }

    func begin() async -> Bool {
        if prepared { return true }
        guard !preparing, !recovering else { return false }
        preparing = true
        generation += 1
        let attempt = generation
        let accepted = await prepare()
        guard generation == attempt else {
            // Cancellation can arrive while the engine answers the preparation request.
            if accepted { await recover() }
            preparing = false
            return false
        }
        preparing = false
        prepared = accepted
        return accepted
    }

    func finish() async {
        generation += 1
        guard prepared else { return }
        prepared = false
        recovering = true
        await recover()
        recovering = false
    }
}

/// Sparkle owns HTTPS, archive validation, installation and relaunch.
@MainActor
public final class MacAppUpdater: NSObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private let driver: AppUpdateUserDriver

    public init(prepare: @escaping () async -> Bool, recover: @escaping () async -> Void) {
        driver = AppUpdateUserDriver(prepare: prepare, recover: recover)
        super.init()
        guard AppUpdateConfiguration.isReady(Bundle.main.infoDictionary ?? [:]) else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            // Sparkle presents its own setup error. Never log arbitrary framework errors.
        }
    }

    public enum Mode: Hashable {
        case manual, notify, install
    }

    public var mode: Mode? {
        guard let updater else { return nil }
        guard updater.automaticallyChecksForUpdates else { return .manual }
        return updater.automaticallyDownloadsUpdates ? .install : .notify
    }

    public func setMode(_ mode: Mode) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = mode != .manual
        updater.automaticallyDownloadsUpdates = mode == .install
    }

    private var installsOnQuit = false

    public func prepareForTermination() async -> Bool {
        guard installsOnQuit else { return true }
        return await driver.gate.begin()
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                        immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installsOnQuit = true
        return false
    }

    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates == true && !driver.gate.isBusy
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdateConfiguration.feedURL
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { await driver.gate.finish() }
    }
}

/// Mirrors HonkVPN's native driver. A postponed staged install must not survive recovery.
@MainActor
private final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    let gate: AppUpdateInstallationGate

    init(prepare: @escaping () async -> Bool, recover: @escaping () async -> Void) {
        gate = AppUpdateInstallationGate(prepare: prepare, recover: recover)
    }

    private func choose(_ choice: SPUUserUpdateChoice, staged: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let choice = staged && choice == .dismiss ? SPUUserUpdateChoice.skip : choice
        guard choice == .install else { reply(choice); return }
        Task { @MainActor in
            reply(await gate.begin() ? .install : (staged ? .skip : .dismiss))
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.showUpdateFound(with: appcastItem, state: state) { [self] choice in
            choose(choice, staged: state.stage == .installing, reply: reply)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.showReady(toInstallAndRelaunch: { [self] choice in
            choose(choice, staged: true, reply: reply)
        })
    }

    func dismissUpdateInstallation() {
        standard.dismissUpdateInstallation()
        // Successful handoff also dismisses the UI. Recover only when the cycle finishes.
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { standard.show(request, reply: reply) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { standard.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication) }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
}
