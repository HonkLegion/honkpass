import AppKit
import Engine
import Foundation
import Security
import VaultModel

/// Who signed an app, as the code signing of the system says it: the identifier of the code
/// and the team of its developer, or Apple itself. PassVault checks no signature by itself;
/// it asks the system whether the code meets a requirement. Nothing is started and no list of
/// apps is read: only the app that is named is looked at.
enum AppSignature {
    /// The app in a folder of the disk. The whole bundle is checked against its signature,
    /// which takes a while for a large app. nil for what is no app, for an app that is not
    /// signed or was changed after it was signed, and for one that only its maker's own
    /// machine would trust (an "ad hoc" signature).
    static func ofApp(at location: URL) -> AppAddress? {
        guard location.isFileURL, location.pathExtension.lowercased() == "app" else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard let address = address(of: code, meets: { SecStaticCodeCheckValidity(code, flags, $0) == errSecSuccess }),
              // The name the system shows the app under must be the one that is signed.
              Bundle(url: location)?.bundleIdentifier == address.bundleID else { return nil }
        return address
    }

    /// The app of a running process: its code as it runs, not the file its path names now.
    static func ofProcess(_ processID: pid_t) -> AppAddress? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: processID] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return address(of: staticCode) { requirement in
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        }
    }

    /// What the signature says, once the system has confirmed it: the code has this
    /// identifier, and the developer with this team signed it for Apple's platforms, or Apple
    /// signed it itself. An app of the App Store is signed by Apple for its developer.
    private static func address(of code: SecStaticCode, meets: (SecRequirement) -> Bool) -> AppAddress? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        // An address takes only letters, digits, dots and hyphens: the identifier and the team
        // can stand in the text of a requirement as they are.
        guard let address = AppAddress(bundleID: identifier, developer: team ?? AppAddress.apple) else { return nil }
        guard let requirement = requirement(for: address), meets(requirement) else { return nil }
        return address
    }

    static func requirementText(for app: AppAddress) -> String {
        if app.isOfApple { return "anchor apple and identifier \"\(app.bundleID)\"" }
        return "anchor apple generic and identifier \"\(app.bundleID)\" and "
            + "(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[subject.OU] = \"\(app.developer)\")"
    }

    private static func requirement(for app: AppAddress) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText(for: app) as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The app opens web pages: the system would hand it a link. It counts as a browser, and a
    /// login belongs to the pages a browser shows, never to the browser. The system names some
    /// apps at another place than it shows them (Safari), so the identifier is compared too.
    static func isBrowser(at bundle: URL) -> Bool {
        guard let page = URL(string: "https://example.com") else { return false }
        let place = bundle.resolvingSymlinksInPath()
        let identifier = Bundle(url: bundle)?.bundleIdentifier
        return NSWorkspace.shared.urlsForApplications(toOpen: page).contains { opener in
            opener.resolvingSymlinksInPath() == place || (identifier != nil && Bundle(url: opener)?.bundleIdentifier == identifier)
        }
    }
}

/// The origin authority of an Accessibility capture. AXURL is an app's own claim: only
/// these browser publishers may turn it into a website match. HTTP-handler registration
/// excludes a native association, but never grants website authority.
struct FillOrigin: Equatable {
    let app: AppAddress?
    let website: String?

    init(bundleID: String?, signature: AppAddress?, isRegisteredBrowser: Bool, reportedWebsite: String?) {
        if Self.isTrustedBrowser(bundleID: bundleID, signature: signature) {
            app = nil
            website = reportedWebsite
        } else {
            app = !isRegisteredBrowser && signature?.bundleID == bundleID ? signature : nil
            website = nil
        }
    }

    static func isTrustedBrowser(bundleID: String?, signature: AppAddress?) -> Bool {
        guard let bundleID, let signature else { return false }
        // Publisher pairs: Apple's password-manager-resources browser distribution list.
        // Safari and Firefox were also checked against the installed signed bundles.
        let known: [(codeID: String, developer: String, bundleIDs: Set<String>)] = [
            ("com.apple.Safari", AppAddress.apple, ["com.apple.Safari"]),
            ("org.mozilla.firefox", "43AQ936H96", ["org.mozilla.firefox"]),
            ("com.google.Chrome", "EQHXZ8M8AV", ["com.google.Chrome"]),
            ("io.ungoogled-software.ungoogled-chromium", "B9A88FL5XJ",
             ["io.ungoogled-software.ungoogled-chromium", "org.chromium.Chromium"]),
        ]
        return known.contains { $0.codeID == signature.bundleID && $0.developer == signature.developer && $0.bundleIDs.contains(bundleID) }
    }
}

/// The signatures of the apps of this Mac.
public actor MacAppSignatures: AppSignaturesPort {
    private struct Process: Sendable, Equatable {
        let pid: pid_t
        let launched: Date
        let bundleID: String
        let location: URL
        let name: String
    }

    private struct Selection: Sendable {
        let process: Process
        let address: AppAddress
    }

    private var selections: [UUID: Selection] = [:]

    public init() {}

    public func app(at location: URL) async -> SignedApp? {
        // The check reads the whole bundle: not on the thread of the caller.
        await Task.detached(priority: .userInitiated) {
            guard let address = AppSignature.ofApp(at: location) else { return nil }
            return SignedApp(address: address, isBrowser: AppSignature.isBrowser(at: location))
        }.value
    }

    public func runningApps() async -> [RunningApp] {
        let processes = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> Process? in
                guard app.activationPolicy == .regular, !app.isTerminated,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let launched = app.launchDate, let location = app.bundleURL,
                      let bundleID = app.bundleIdentifier else { return nil }
                return Process(pid: app.processIdentifier, launched: launched, bundleID: bundleID,
                               location: location, name: app.localizedName ?? bundleID)
            }
        }
        let verified = await Self.verify(processes)
        guard !Task.isCancelled else { return [] }
        var fresh: [UUID: Selection] = [:]
        let apps = verified.map { selection in
            let id = selections.first { $0.value.process == selection.process && $0.value.address == selection.address }?.key ?? UUID()
            fresh[id] = selection
            return RunningApp(id: id, name: selection.process.name, location: selection.process.location, address: selection.address)
        }
        selections = fresh
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func app(runningID: UUID) async -> SignedApp? {
        guard let selection = selections[runningID] else { return nil }
        let stillRunning = await Self.isRunning(selection.process)
        guard stillRunning, let verified = await Self.verify([selection.process]).first,
              !Task.isCancelled, verified.address == selection.address,
              await Self.isRunning(selection.process) else { return nil }
        return SignedApp(address: verified.address)
    }

    @MainActor private static func isRunning(_ process: Process) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: process.pid) else { return false }
        return !app.isTerminated && app.activationPolicy == .regular && app.launchDate == process.launched
            && app.bundleIdentifier == process.bundleID && app.bundleURL == process.location
    }

    @concurrent private static func verify(_ processes: [Process]) async -> [Selection] {
        var verified: [Selection] = []
        for process in processes {
            guard !Task.isCancelled else { return [] }
            guard let address = AppSignature.ofProcess(process.pid), address.bundleID == process.bundleID,
                  !FillOrigin.isTrustedBrowser(bundleID: process.bundleID, signature: address),
                  !AppSignature.isBrowser(at: process.location) else { continue }
            verified.append(Selection(process: process, address: address))
        }
        return verified
    }
}

/// The apps of this Mac by their address, for a client that shows one: its place on the disk,
/// from which the system gives its name and its picture. No app is started.
public enum InstalledApps {
    /// Where the app of an address is installed. nil when the system knows no app with that
    /// identifier, or when the one it knows names another developer in its signature: the name
    /// and the picture of an app are not shown for an address that is not its own. The
    /// signature is only read here, not checked; a fill checks the code that runs.
    public static func location(of app: AppAddress) -> URL? {
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return nil }
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let developer = values[kSecCodeInfoTeamIdentifier as String] as? String ?? AppAddress.apple
        return AppAddress(bundleID: identifier, developer: developer) == app ? location : nil
    }
}
