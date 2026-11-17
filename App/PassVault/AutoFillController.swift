import AuthenticationServices
import AutoFillBridge
import Engine
import Foundation
import os
import Security
import ServiceManagement
import VaultModel

/// The app's side of the system's AutoFill: it lets the Credential Provider extension reach
/// the engine, and knows the launch agent through which the extension finds the app. Like a
/// window it is a client of the engine: it holds no login and no key.
@MainActor
final class AutoFillController {
    /// The parts of AutoFill as the signature of this app names them. nil when no team signed
    /// the app: then nothing is offered and nothing is asked.
    let peers: AutoFillPeers?
    private let host: AutoFillHost?
    private let log = Logger(subsystem: "PassVault", category: "autofill")
    private static let identityKey = "autoFillRegisteredServiceIdentity"
    private lazy var lifecycle: AutoFillServiceLifecycle? = {
        guard let agent, let host, let peers, let identity = Self.serviceIdentity(peers) else { return nil }
        return AutoFillServiceLifecycle(identity: identity, actions: .init(
            state: {
                switch agent.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notRegistered: .notRegistered
                default: .notFound
                }
            },
            savedIdentity: { UserDefaults.standard.data(forKey: Self.identityKey) },
            saveIdentity: { UserDefaults.standard.set($0, forKey: Self.identityKey) },
            register: { try agent.register() },
            unregister: { try await agent.unregister() },
            startHost: { await host.start() },
            stopHost: { host.stop() }
        ))
    }()

    init(engine: Engine) {
        peers = try? AutoFillPeers.current(as: .app)
        host = peers.map { AutoFillHost(answering: EngineAnswers(engine: engine), peers: $0) }
    }

    /// Whether the extension can find the app now.
    var status: AutoFillHost.Status {
        host?.status ?? .notSigned
    }

    /// Starts listening for the extension and hands the end of the connection to the agent.
    /// Without a registered agent this ends at once and nothing else happens.
    func start() async {
        guard let host else { return }
        do {
            if let lifecycle { try await lifecycle.start() } else { await host.start() }
        } catch {
            log.error("The AutoFill helper registration could not be refreshed")
        }
        log.info("The extension can find the app: \(String(describing: host.status), privacy: .public)")
    }

    /// Starts again where the extension cannot find the app: the agent may be registered or
    /// allowed by now. The app asks when it comes to the front, as after the user has been in
    /// the settings of the system.
    func startIfNeeded() {
        guard host != nil, status != .ready else { return }
        Task { await start() }
    }

    // MARK: The launch agent

    private var agent: SMAppService? {
        peers.map { SMAppService.agent(plistName: $0.agentPropertyList) }
    }

    /// What the system says of the agent: registered or not, and whether the user allows it
    /// among the background items. nil for an app that no team signed.
    var agentStatus: SMAppService.Status? {
        agent?.status
    }

    /// The launch agent is registered and the user allows it among the background items.
    var isOn: Bool {
        agentStatus == .enabled
    }

    /// Turns the system's AutoFill on or off, on the word of the user in the settings. On:
    /// the agent is registered, which lists PassVault among the background items of the
    /// system, the app starts to listen, and the system asks the user to turn the extension
    /// on. Off: the agent is removed, and the extension finds no app any more; the system's
    /// own switch of the extension stays the user's.
    func setOn(_ isOn: Bool) async {
        guard let lifecycle else {
            log.error("The signed AutoFill helper identity could not be read")
            return
        }
        do {
            try await lifecycle.setEnabled(isOn)
            if isOn {
                let accepted = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
                log.info("The system asked the user to turn the extension on; turned on: \(accepted, privacy: .public)")
            }
        } catch {
            log.error("The launch agent could not be \(isOn ? "registered" : "removed", privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the settings of the system where the extension is turned on and off.
    func openSystemSettings() {
        ASSettingsHelper.openCredentialProviderAppSettings()
    }

    /// Public code-signature data and the launch plist identify this installation.
    /// A build number alone misses local rebuilds and a change of signing identity.
    private static func serviceIdentity(_ peers: AutoFillPeers) -> Data? {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let helper = bundle.appendingPathComponent("Contents/MacOS/PassVaultRendezvous")
        func codeHash(at url: URL) -> Data? {
            var code: SecStaticCode?
            var information: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let facts = information as? [String: Any],
                  let hash = facts[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
            return hash
        }
        guard let hash = codeHash(at: helper), let appHash = codeHash(at: bundle),
              let plist = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Library/LaunchAgents/\(peers.agentPropertyList)"))
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "bundle": bundle.path, "app": appHash.base64EncodedString(),
            "helper": hash.base64EncodedString(), "plist": plist.base64EncodedString(),
        ], options: .sortedKeys)
    }
}

/// The engine answers the questions of the extension: over the bridge, or asked at once by a
/// picture run that draws the windows of the extension in the app.
struct EngineAnswers: AutoFillAnswering, AutoFillAsking {
    let engine: Engine

    func answer(_ request: AutoFillRequest) async -> AutoFillResponse {
        await engine.autoFill(request)
    }

    func ask(_ request: AutoFillRequest) async -> AutoFillResponse {
        await engine.autoFill(request)
    }
}
