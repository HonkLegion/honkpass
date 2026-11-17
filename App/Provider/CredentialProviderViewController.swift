import AuthenticationServices
import AutoFillBridge
import DesignKit
import LocalAuthentication
import os
import ProviderUI
import SwiftUI
import VaultModel

/// The Credential Provider extension of the system's AutoFill. The system starts it in a
/// process and a sandbox of its own when a form asks for a login. It holds nothing: it asks
/// the app through the bridge, and what it gets goes to the system at once.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private static let log = Logger(subsystem: "PassVault", category: "provider")
    /// The parts of AutoFill by the signature of this extension. nil when no team signed it:
    /// then nobody is asked.
    private static let peers = try? AutoFillPeers.current(as: .provider)

    private var hosting: NSViewController?
    private var model: ProviderModel?

    // MARK: Passwords

    /// The user asked for the list of the extension.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        Self.log.notice("A list of logins is asked for; websites: \(serviceIdentifiers.count, privacy: .public)")
        show(.chooseLogin(services: serviceIdentifiers.map(\.identifier)))
    }

    /// The user took an entry of the system's own list. No window may be shown here, and the
    /// system waits only for a moment: an open vault answers, anything else asks for the window.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard let itemID = credentialRequest.credentialIdentity.recordIdentifier else { return cancel(.failed) }
        let context = extensionContext
        switch credentialRequest.type {
        case .password:
            Task {
                switch await Self.asking(patience: .seconds(2)).ask(.password(itemID: itemID)) {
                case .password(let password): Self.complete(password, context)
                case .failure(.notFound), .failure(.masterPasswordRequired): Self.cancel(.credentialIdentityNotFound, context)
                default: Self.cancel(.userInteractionRequired, context)
                }
            }
        case .oneTimeCode:
            // A verification code is given here or not at all. Safari of macOS 27 keeps its
            // sheet open when a window of the extension for a code is cancelled (found with
            // HonkPass), so this request never asks for the window: a locked vault gives no code.
            Task {
                switch await Self.asking(patience: .seconds(2)).ask(.verificationCode(itemID: itemID)) {
                case .verificationCode(let code):
                    Self.log.notice("A verification code goes to the system")
                    context.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code), completionHandler: nil)
                case .failure(.notFound), .failure(.masterPasswordRequired): Self.cancel(.credentialIdentityNotFound, context)
                default: Self.cancel(.failed, context)
                }
            }
        case .passkeyAssertion:
            // Selecting the system suggestion gives consent, without claiming verification.
            // Only a required verification needs another prompt when the vault is open.
            guard let question = Self.question(of: credentialRequest) else { return cancel(.failed) }
            guard question.userVerification != .required else { return cancel(.userInteractionRequired) }
            let request = PasskeyAssertionRequest(rpID: question.rpID, clientDataHash: question.clientDataHash,
                                                  allowedCredentialIDs: question.allowedCredentialIDs, itemID: itemID,
                                                  userVerification: question.userVerification, isUserVerified: false)
            Task {
                switch await Self.asking(patience: .seconds(2)).ask(.passkeyAssertion(request)) {
                case .passkeyAssertion(let assertion): Self.complete(assertion, question.clientDataHash, context)
                case .failure(.notFound), .failure(.masterPasswordRequired): Self.cancel(.credentialIdentityNotFound, context)
                default: Self.cancel(.userInteractionRequired, context)
                }
            }
        default:
            cancel(.failed)
        }
    }

    /// The list of the extension for a verification code: not shown, for the reason above.
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        cancel(.failed)
    }

    /// The same entry, now with a window: the vault was locked, or the app was not running.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard let itemID = credentialRequest.credentialIdentity.recordIdentifier else { return cancel(.failed) }
        switch credentialRequest.type {
        case .password:
            Self.log.notice("The login of an entry is asked for, with a window")
            show(.login(itemID: itemID))
        case .passkeyAssertion:
            guard let question = Self.question(of: credentialRequest) else { return cancel(.failed) }
            Self.log.notice("The passkey of an entry is asked for, with a window")
            show(.passkey(itemID: itemID, question), clientDataHash: question.clientDataHash)
        default:
            // A verification code has no window (see above).
            cancel(.failed)
        }
    }

    // MARK: Passkeys

    /// The user asked for the passkeys of the extension for a website.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        Self.log.notice("A list of passkeys is asked for")
        let question = ProviderModel.PasskeyQuestion(
            rpID: requestParameters.relyingPartyIdentifier, clientDataHash: requestParameters.clientDataHash,
            allowedCredentialIDs: requestParameters.allowedCredentials,
            userVerification: Self.verification(requestParameters.userVerificationPreference))
        show(.choosePasskey(question), clientDataHash: question.clientDataHash)
    }

    /// A website wants a new passkey, and the user chose PassVault to keep it.
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else { return cancel(.failed) }
        Self.log.notice("A new passkey is asked for")
        show(.newPasskey(PasskeyRegistrationRequest(
            rpID: identity.relyingPartyIdentifier, userName: identity.userName, userHandle: identity.userHandle,
            clientDataHash: request.clientDataHash, algorithms: request.supportedAlgorithms.map(\.rawValue),
            excludedCredentialIDs: request.excludedCredentials?.map(\.credentialID) ?? [],
            userVerification: Self.verification(request.userVerificationPreference), isUserVerified: false)),
            clientDataHash: request.clientDataHash)
    }

    /// What a request of the system for the passkey of one entry asks to be signed.
    private static func question(of request: any ASCredentialRequest) -> ProviderModel.PasskeyQuestion? {
        guard let request = request as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else { return nil }
        return ProviderModel.PasskeyQuestion(rpID: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash,
                                             allowedCredentialIDs: [identity.credentialID],
                                             userVerification: verification(request.userVerificationPreference))
    }

    private static func verification(_ preference: ASAuthorizationPublicKeyCredentialUserVerificationPreference) -> PasskeyUserVerification {
        switch preference {
        case .required: .required
        case .preferred: .preferred
        case .discouraged: .discouraged
        default: .required
        }
    }

    /// The question of the system that verifies the user: Touch ID, or the password of the
    /// Mac. The system puts the name of the app before the text ("… is trying to").
    private static func verifyUser(_ purpose: ProviderModel.Verification) async -> Bool? {
        let reason = switch purpose {
        case .assertion(let rpID, let username): BWText.text("confirmPasskeyAssertionMfaMacOS", [rpID, username])
        case .registration(let rpID, let username): BWText.text("confirmPasskeyRegistrationMfaMacOS", [rpID, username])
        case .overwrite(let rpID, let username): BWText.text("confirmPasskeyOverwriteMfaMacOS", [rpID, username])
        }
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return nil
        } catch {
            return false
        }
    }

    // MARK: The settings of the system

    /// The user has turned the extension on. The message of the reference stays for two
    /// seconds, and the app writes the entries of the system's store.
    override func prepareInterfaceForExtensionConfiguration() {
        Self.log.notice("The extension was turned on in the settings of the system")
        reset()
        mount(NSHostingController(rootView: ProviderConfigurationView()))
        let context = extensionContext
        Task {
            _ = await Self.asking().ask(.storeIdentities)
            try? await Task.sleep(for: .seconds(2))
            context.completeExtensionConfigurationRequest()
        }
    }

    // MARK: The window

    /// - Parameter clientDataHash: of a request for a passkey: the system wants it back with the answer.
    private func show(_ request: ProviderModel.Request, clientDataHash: Data = Data()) {
        reset()
        let context = extensionContext
        let model = ProviderModel(request: request, asking: Self.asking(), touchIDReason: BWText["touchIdConsentMessage"],
                                  actions: ProviderModel.Actions(
            openApp: { inFront in Self.openApp(inFront: inFront) },
            finish: { outcome in
                switch outcome {
                case .password(let password): Self.complete(password, context)
                case .assertion(let assertion): Self.complete(assertion, clientDataHash, context)
                case .registration(let registration):
                    Self.log.notice("A new passkey goes to the system")
                    context.completeRegistrationRequest(using: ASPasskeyRegistrationCredential(
                        relyingParty: registration.rpID, clientDataHash: clientDataHash, credentialID: registration.credentialID,
                        attestationObject: registration.attestationObject), completionHandler: nil)
                case .cancelled: Self.cancel(.userCanceled, context)
                case .notFound: Self.cancel(.credentialIdentityNotFound, context)
                case .passkeyExists: Self.cancel(.matchedExcludedCredential, context)
                case .failed: Self.cancel(.failed, context)
                }
            },
            verifyUser: { purpose in await Self.verifyUser(purpose) }))
        self.model = model
        mount(NSHostingController(rootView: ProviderView(model: model)))
    }

    /// The system keeps the process for the next request: what the last one showed goes first.
    private func reset() {
        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()
        hosting = nil
        model = nil
    }

    /// The system owns the size of its window. The content fills it and never sets it.
    private func mount<Content: View>(_ host: NSHostingController<Content>) {
        host.sizingOptions = []
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = NSSize(width: 480, height: 400)
        hosting = host
    }

    // MARK: The answers to the system

    private func cancel(_ code: ASExtensionError.Code) {
        Self.cancel(code, extensionContext)
    }

    private static func cancel(_ code: ASExtensionError.Code, _ context: ASCredentialProviderExtensionContext) {
        log.notice("The request ends without a login; code: \(code.rawValue, privacy: .public)")
        context.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }

    private static func complete(_ password: AutoFillPassword, _ context: ASCredentialProviderExtensionContext) {
        log.notice("A login goes to the system")
        context.completeRequest(withSelectedCredential: ASPasswordCredential(user: password.username, password: password.password),
                                completionHandler: nil)
    }

    private static func complete(_ assertion: PasskeyAssertion, _ clientDataHash: Data, _ context: ASCredentialProviderExtensionContext) {
        log.notice("The signature of a passkey goes to the system")
        context.completeAssertionRequest(using: ASPasskeyAssertionCredential(
            userHandle: assertion.userHandle, relyingParty: assertion.rpID, signature: assertion.signature,
            clientDataHash: clientDataHash, authenticatorData: assertion.authenticatorData, credentialID: assertion.credentialID),
            completionHandler: nil)
    }

    // MARK: The app

    private static func asking(patience: Duration = .seconds(15)) -> any AutoFillAsking {
        peers.map { AutoFillClient(peers: $0, patience: patience) } ?? NoApp()
    }

    /// Opens the app this extension lies in: .appex, PlugIns, Contents, the app.
    private static func openApp(inFront: Bool) {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let peers, Bundle(url: app)?.bundleIdentifier == peers.appIdentifier else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = inFront
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
    }
}

/// An extension that no team signed can ask nobody.
private struct NoApp: AutoFillAsking {
    func ask(_ request: AutoFillRequest) async -> AutoFillResponse {
        .failure(.unavailable)
    }
}
