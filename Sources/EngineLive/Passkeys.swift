import BitwardenSdk
import Engine
import Foundation
import Synchronization
import VaultModel

/// Passkeys. The authenticator of the SDK makes the key, keeps it encrypted in the login and
/// signs with it; PassVault writes no WebAuthn and no signature of its own. The authenticator
/// asks two things of its host: where the logins with passkeys are (`PasskeyStore`) and what
/// the user decided (`PasskeyDecisions`). The user has decided before the SDK is called: the
/// engine gets a request that names the login and says whether the user was verified.
extension SDKVault {
    /// The passkeys of a decrypted login as the lists know them: no key.
    func passkeys(of view: CipherView) -> [VaultPasskey] {
        guard let credentials = try? client.platform().fido2().getFido2AutofillCredentials(cipherView: view) else { return [] }
        return credentials.map {
            VaultPasskey(credentialID: $0.credentialId, rpID: $0.rpId, userName: $0.userNameForUi ?? "", userHandle: $0.userHandle)
        }
    }

    /// The encrypted logins that have a passkey and are not deleted; one login when it is named.
    fileprivate func passkeyCiphers(only itemID: String?) -> [Cipher] {
        encryptedItems.withLock { items in
            items.values.filter { cipher in
                cipher.type == .login && cipher.deletedDate == nil && cipher.login?.fido2Credentials?.isEmpty == false
                    && (itemID == nil || cipher.id == itemID)
            }
        }
    }

    func passkeyAssertion(_ request: PasskeyAssertionRequest) async throws -> PasskeySigned {
        let store = PasskeyStore(vault: self, itemID: request.itemID)
        let decisions = PasskeyDecisions(isUserVerified: request.isUserVerified, chosenItemID: request.itemID, target: nil)
        let authenticator = client.platform().fido2().authenticator(userInterface: decisions, credentialStore: store)
        let allowed = request.allowedCredentialIDs.map { PublicKeyCredentialDescriptor(ty: "public-key", id: $0, transports: nil) }
        let result: GetAssertionResult
        do {
            result = try await authenticator.getAssertion(request: GetAssertionRequest(
                rpId: request.rpID, clientDataHash: request.clientDataHash, allowList: allowed.isEmpty ? nil : allowed,
                options: Options(rk: false, uv: Uv(request.userVerification)), extensions: nil))
        } catch {
            // No passkey of the login fits the request, or the SDK could not sign with it.
            throw store.foundNone.withLock({ $0 }) ? EngineError.notFound : EngineError.unexpected("The SDK could not sign with the passkey.")
        }
        let assertion = PasskeyAssertion(rpID: request.rpID, credentialID: result.credentialId, userHandle: result.userHandle,
                                         authenticatorData: result.authenticatorData, signature: result.signature)
        return PasskeySigned(assertion: assertion, save: try await save(of: store, itemID: request.itemID, isOptional: true))
    }

    func makePasskey(_ request: PasskeyRegistrationRequest, newLoginName: String) async throws -> PasskeyMade {
        // The login the passkey goes into: the one the user chose, whole and writable, or a new
        // login of the website, as the reference makes it (`createCipher`).
        let target: CipherView
        if let itemID = request.itemID {
            target = try await writableView(itemID)
        } else {
            guard decryptsStrictly.withLock({ $0 }) else { throw EngineError.itemNotWritable }
            var draft = ItemDraft(new: .login)
            draft.name = newLoginName
            draft.content = .login(ItemDraft.Login(username: request.userName, websites: [.init(address: "https://" + request.rpID)]))
            target = Self.view(of: draft, replacing: nil, now: Date())
        }
        let store = PasskeyStore(vault: self, itemID: nil)
        let decisions = PasskeyDecisions(isUserVerified: request.isUserVerified, chosenItemID: nil, target: target)
        let authenticator = client.platform().fido2().authenticator(userInterface: decisions, credentialStore: store)
        let excluded = request.excludedCredentialIDs.map { PublicKeyCredentialDescriptor(ty: "public-key", id: $0, transports: nil) }
        let result: MakeCredentialResult
        do {
            result = try await authenticator.makeCredential(request: MakeCredentialRequest(
                clientDataHash: request.clientDataHash, rp: PublicKeyCredentialRpEntity(id: request.rpID, name: nil),
                user: PublicKeyCredentialUserEntity(id: request.userHandle, displayName: request.userName, name: request.userName),
                pubKeyCredParams: request.algorithms.map { PublicKeyCredentialParameters(ty: "public-key", alg: Int64($0)) },
                excludeList: excluded.isEmpty ? nil : excluded,
                options: Options(rk: true, uv: Uv(request.userVerification)), extensions: nil))
        } catch {
            if decisions.sawExcluded.withLock({ $0 }) { throw EngineError.passkeyExists }
            throw EngineError.unexpected("The SDK could not make the passkey.")
        }
        // The authenticator told that the vault has a passkey the website excludes. Whatever it
        // made after that is thrown away: nothing of it goes to the server or to the website.
        if decisions.sawExcluded.withLock({ $0 }) { throw EngineError.passkeyExists }
        guard let save = try await save(of: store, itemID: request.itemID, isOptional: false) else {
            throw EngineError.unexpected("The SDK made a passkey and saved it nowhere.")
        }
        let registration = PasskeyRegistration(rpID: request.rpID, credentialID: result.credentialId,
                                               attestationObject: result.attestationObject)
        return PasskeyMade(registration: registration, save: save)
    }

    /// The login the SDK changed, as the request for the server. As with a form, what goes to
    /// the server must decrypt again, whole.
    private func save(of store: PasskeyStore, itemID: String?, isOptional: Bool) async throws -> PasskeySave? {
        guard let context = store.saved.withLock({ $0 }) else { return nil }
        guard let readBack = try? await client.vault().ciphers().decrypt(cipher: context.cipher),
              Self.keepsEveryPart(context.cipher, readBack),
              let request = client.vault().ciphers().cipherRequestJson(context: context) else {
            // A passkey that counts its uses could not be written: the signature stands without it.
            if isOptional { return nil }
            throw EngineError.unexpected("The login with the passkey does not read back as it was written.")
        }
        return PasskeySave(itemID: itemID, request: Data(request.utf8))
    }
}

private extension Uv {
    init(_ verification: PasskeyUserVerification) {
        self = switch verification {
        case .discouraged: .discouraged
        case .preferred: .preferred
        case .required: .required
        }
    }
}

/// Where the authenticator finds the logins with passkeys, and where it puts a login it changed.
/// Nothing is written here: the engine sends the changed login to the server.
private final class PasskeyStore: Fido2CredentialStore {
    private let vault: SDKVault
    private let itemID: String?
    let saved = Mutex<EncryptionContext?>(nil)
    /// The authenticator asked for passkeys and none fitted.
    let foundNone = Mutex(false)

    init(vault: SDKVault, itemID: String?) {
        self.vault = vault
        self.itemID = itemID
    }

    func findCredentials(ids: [Data]?, ripId: String, userHandle: Data?) async throws -> [CipherView] {
        var found: [CipherView] = []
        for cipher in vault.passkeyCiphers(only: itemID) {
            guard let view = try? await vault.client.vault().ciphers().decrypt(cipher: cipher) else { continue }
            let fits = vault.passkeys(of: view).contains { passkey in
                passkey.rpID == ripId && (ids?.contains(passkey.credentialID) ?? true)
                    && (userHandle.map { $0 == passkey.userHandle } ?? true)
            }
            if fits { found.append(view) }
        }
        foundNone.withLock { $0 = found.isEmpty }
        return found
    }

    func allCredentials() async throws -> [CipherListView] {
        (try? await vault.client.vault().ciphers().decryptList(ciphers: vault.passkeyCiphers(only: itemID))) ?? []
    }

    func saveCredential(cred: EncryptionContext) async throws {
        saved.withLock { $0 = cred }
    }
}

/// What the user decided, told to the authenticator when it asks. No window opens here.
private final class PasskeyDecisions: Fido2UserInterface {
    private struct NoDecision: Error {}

    private let isUserVerified: Bool
    private let chosenItemID: String?
    private let target: CipherView?
    /// The authenticator found a passkey that the website excludes.
    let sawExcluded = Mutex(false)

    init(isUserVerified: Bool, chosenItemID: String?, target: CipherView?) {
        self.isUserVerified = isUserVerified
        self.chosenItemID = chosenItemID
        self.target = target
    }

    /// The user is present: they chose the login in the window of the extension, or in the
    /// list of the system. Whether they were verified is what the request says.
    func checkUser(options: CheckUserOptions, hint: UiHint) async throws -> CheckUserResult {
        if case .informExcludedCredentialFound = hint { sawExcluded.withLock { $0 = true } }
        return CheckUserResult(userPresent: true, userVerified: isUserVerified)
    }

    func pickCredentialForAuthentication(availableCredentials: [CipherView]) async throws -> CipherViewWrapper {
        guard let cipher = availableCredentials.first(where: { $0.id == chosenItemID }) else { throw NoDecision() }
        return CipherViewWrapper(cipher: cipher)
    }

    func checkUserAndPickCredentialForCreation(options: CheckUserOptions,
                                               newCredential: Fido2CredentialNewView) async throws -> CheckUserAndPickCredentialForCreationResult {
        guard let target else { throw NoDecision() }
        return CheckUserAndPickCredentialForCreationResult(
            cipher: CipherViewWrapper(cipher: target),
            checkUserResult: CheckUserResult(userPresent: true, userVerified: isUserVerified))
    }

    /// The extension can verify the user: with the PIN, with Touch ID or with the password of the Mac.
    func isVerificationEnabled() -> Bool {
        true
    }
}
