import BitwardenSdk
import Engine
import Foundation
import Synchronization
import VaultModel

/// All vault cryptography, done by the Bitwarden SDK. PassVault implements none of it.
public struct BitwardenCrypto: CryptoPort {
    public init() {}

    public func serverPasswordHash(password: String, prelogin: Prelogin) async throws -> String {
        do {
            return try await SDK.makeClient().auth().hashPassword(
                email: prelogin.salt, password: password, kdfParams: Kdf(prelogin.kdf), purpose: .serverAuthorization)
        } catch {
            throw EngineError.unexpected("The SDK could not hash the master password.")
        }
    }

    public func unlock(_ request: UnlockRequest) async throws -> any UnlockedCrypto {
        try await SDKVault.open(request)
    }

    public func unlock(_ request: PinUnlockRequest) async throws -> any UnlockedCrypto {
        try await SDKVault.open(request)
    }

    public func unlock(_ request: KeyUnlockRequest) async throws -> any UnlockedCrypto {
        try await SDKVault.open(request)
    }

    /// The generators of the SDK. PassVault picks no random character itself. A forwarded email
    /// alias is never asked for: the SDK would call an outside service for it.
    public func generate(_ request: GeneratorRequest) async throws -> String {
        let generators = SDK.makeClient().generators()
        do {
            switch request {
            case .password(let options):
                return try generators.password(settings: PasswordGeneratorRequest(
                    lowercase: options.lowercase, uppercase: options.uppercase, numbers: options.numbers, special: options.special,
                    length: UInt8(clamping: options.length), avoidAmbiguous: options.avoidAmbiguous,
                    minLowercase: options.lowercase ? 1 : nil, minUppercase: options.uppercase ? 1 : nil,
                    minNumber: options.numbers ? UInt8(clamping: options.minNumbers) : nil,
                    minSpecial: options.special ? UInt8(clamping: options.minSpecial) : nil))
            case .passphrase(let options):
                return try generators.passphrase(settings: PassphraseGeneratorRequest(
                    numWords: UInt8(clamping: options.words), wordSeparator: options.separator, capitalize: options.capitalize,
                    includeNumber: options.includeNumber))
            case .username(let options, let website):
                switch options.kind {
                case .randomWord:
                    return try await generators.username(settings: .word(capitalize: options.capitalize, includeNumber: options.includeNumber))
                case .plusAddressedEmail:
                    return try await generators.username(settings: .subaddress(type: .random, email: options.email))
                case .catchallEmail:
                    // The engine gives a website only when the address is to start with its name.
                    return try await generators.username(settings: .catchall(
                        type: website.map { .websiteName(website: $0) } ?? .random, domain: options.domain))
                }
            }
        } catch {
            throw EngineError.unexpected("The SDK could not generate a value from these options.")
        }
    }

    public func newSSHKey() async throws -> SSHKeyContent {
        do {
            let key = try SDK.makeClient().ssh().generateSshKey(keyAlgorithm: .ed25519)
            return SSHKeyContent(privateKey: key.privateKey, publicKey: key.publicKey, fingerprint: key.fingerprint)
        } catch {
            throw EngineError.unexpected("The SDK could not generate an SSH key.")
        }
    }

    public func importSSHKey(_ text: String, password: String?) async throws -> SSHKeyContent {
        do {
            let key = try SDK.makeClient().ssh().importSshKey(importedKey: text, password: password)
            return SSHKeyContent(privateKey: key.privateKey, publicKey: key.publicKey, fingerprint: key.fingerprint)
        } catch BitwardenError.SshImport(let failure) {
            switch failure {
            case .PasswordRequired: throw EngineError.sshKeyImport(.passwordRequired)
            case .WrongPassword: throw EngineError.sshKeyImport(.wrongPassword)
            case .UnsupportedKeyType: throw EngineError.sshKeyImport(.unsupportedKind)
            case .Parsing: throw EngineError.sshKeyImport(.notAKey)
            }
        } catch {
            throw EngineError.unexpected("The SDK could not read the SSH key.")
        }
    }
}

enum SDK {
    private static let quietLogging: Void = {
        initLogger(callback: SDKDiscardLogs(), level: .error, platformLogger: false)
    }()

    /// A client without server settings: it computes, it does not connect.
    static func makeClient() -> Client {
        _ = quietLogging
        return Client(tokenProvider: SDKNoTokens(), settings: nil, managedSettings: ManagedSettingsBindingClient())
    }
}

/// One SDK client that holds the keys of one unlocked vault.
final class SDKVault: UnlockedCrypto {
    let client: Client
    let userID: String
    // The client uses these as its state. They live and die with it.
    private let state = SDKMemoryState()
    private let ciphers = SDKCipherRepository()
    private let localKeys = SDKLocalKeys()
    /// The encrypted items of the vault that was decrypted last, by identifier.
    let encryptedItems = Mutex<[String: Cipher]>([:])
    let encryptedFolders = Mutex<[Folder]>([])
    /// The encrypted Sends of the vault that was decrypted last, by identifier.
    let encryptedSends = Mutex<[String: Send]>([:])
    /// The SDK has been seen to refuse an item with a damaged part. Nothing is written without it.
    let decryptsStrictly = Mutex(false)

    private init(userID: String) {
        self.userID = userID
        client = SDK.makeClient()
        client.kmStateBridge().registerBridgeImpl(bridgeImpl: state)
        client.platform().state().registerClientManagedRepositories(repositories: Repositories(
            cipher: ciphers, folder: nil, localUserDataKeyState: localKeys, organizationSharedKey: nil,
            send: nil, policy: nil, organization: nil))
    }

    static func open(_ request: UnlockRequest) async throws -> SDKVault {
        let vault = SDKVault(userID: request.userID)
        let material = request.material
        let kdf = Kdf(material.kdf)
        do {
            try await vault.client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
                userId: request.userID, kdfParams: kdf, email: request.email,
                accountCryptographicState: WrappedAccountCryptographicState(material.keys),
                method: .masterPasswordUnlock(
                    password: request.masterPassword,
                    masterPasswordUnlock: MasterPasswordUnlockData(
                        kdf: kdf, masterKeyWrappedUserKey: material.masterKeyWrappedUserKey,
                        salt: material.salt, containedKeyId: material.userKeyID)),
                upgradeToken: nil))
        } catch {
            throw Self.unlockFailure(error)
        }
        await vault.prepareStrictDecryption()
        return vault
    }

    /// Opens the keys with the PIN: the envelope holds the user key, wrapped by a key the SDK
    /// makes from the PIN.
    static func open(_ request: PinUnlockRequest) async throws -> SDKVault {
        let vault = SDKVault(userID: request.userID)
        // The SDK says whether the PIN opens the envelope, apart from every other failure.
        guard vault.client.auth().validatePinProtectedUserKeyEnvelope(pin: request.pin,
                                                                      pinProtectedUserKeyEnvelope: request.envelope) else {
            throw EngineError.wrongPin
        }
        do {
            try await vault.client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
                userId: request.userID, kdfParams: Kdf(request.material.kdf), email: request.email,
                accountCryptographicState: WrappedAccountCryptographicState(request.material.keys),
                method: .pinEnvelope(pin: request.pin, pinProtectedUserKeyEnvelope: request.envelope),
                upgradeToken: nil))
        } catch {
            throw EngineError.unexpected("The SDK could not open the account keys with the PIN.")
        }
        await vault.prepareStrictDecryption()
        return vault
    }

    /// Opens the keys with the user key itself, which the Keychain of the system kept behind
    /// Touch ID. A key that does not open the keys of the account is refused: it is damaged,
    /// or the keys were changed on another device since it was kept.
    static func open(_ request: KeyUnlockRequest) async throws -> SDKVault {
        let vault = SDKVault(userID: request.userID)
        do {
            try await vault.client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
                userId: request.userID, kdfParams: Kdf(request.material.kdf), email: request.email,
                accountCryptographicState: WrappedAccountCryptographicState(request.material.keys),
                method: .decryptedKey(decryptedUserKey: request.userKey),
                upgradeToken: nil))
        } catch BitwardenError.EncryptionSettings(.Crypto) {
            throw EngineError.biometrics(.keyRejected)
        } catch {
            throw EngineError.unexpected("The SDK could not open the account keys with the kept key.")
        }
        // The SDK takes any key here and goes on without the private key of the account when
        // the key does not open it. A vault must not count as unlocked with such a key.
        guard vault.opensThePrivateKey else { throw EngineError.biometrics(.keyRejected) }
        await vault.prepareStrictDecryption()
        return vault
    }

    /// Whether the user key the SDK holds has opened the private key of the account: only
    /// then can the SDK make the fingerprint of the account, which it makes of its public key.
    private var opensThePrivateKey: Bool {
        (try? client.platform().userFingerprint(fingerprintMaterial: userID)) != nil
    }

    /// The user key as the SDK gives it out, for the Keychain of the system only. It is not
    /// given for an account whose private key it does not open: such a key could not be told
    /// from a wrong one when it comes back.
    func userKey() async throws -> String {
        guard opensThePrivateKey else { throw EngineError.biometrics(.failed) }
        do {
            return try await client.crypto().getUserEncryptionKey()
        } catch {
            throw EngineError.unexpected("The SDK did not give the user key.")
        }
    }

    func enrollPin(_ pin: String) async throws -> PinEnrollment {
        do {
            let response = try client.crypto().enrollPin(pin: pin)
            return PinEnrollment(envelope: response.pinProtectedUserKeyEnvelope, encryptedPin: response.userKeyEncryptedPin)
        } catch {
            throw EngineError.unexpected("The SDK could not protect the keys with the PIN.")
        }
    }

    func enrollPin(encryptedPin: String) async throws -> PinEnrollment {
        do {
            let response = try client.crypto().enrollPinWithEncryptedPin(encryptedPin: encryptedPin)
            return PinEnrollment(envelope: response.pinProtectedUserKeyEnvelope, encryptedPin: response.userKeyEncryptedPin)
        } catch {
            throw EngineError.unexpected("The SDK could not protect the keys with the stored PIN.")
        }
    }

    /// The SDK has no error of its own for a wrong master password: the user key fails to decrypt.
    private static func unlockFailure(_ error: any Error) -> EngineError {
        if case BitwardenError.EncryptionSettings(.Crypto) = error { return .wrongMasterPassword }
        return .unexpected("The SDK could not open the account keys.")
    }

    func decryptVault(syncPayload: Data) async throws -> VaultContents {
        guard let root = (try? JSONSerialization.jsonObject(with: syncPayload)) as? [String: Any] else {
            throw EngineError.server("The sync answer is not readable.")
        }
        await loadOrganizationKeys(root)

        var encrypted: [Cipher] = []
        var omitted = 0
        for row in (JSON.field(root, "Ciphers") as? [[String: Any]]) ?? [] {
            guard let data = try? JSONSerialization.data(withJSONObject: row),
                  let json = String(data: data, encoding: .utf8),
                  let cipher = client.vault().ciphers().cipherFromServerJson(json: json) else {
                omitted += 1
                continue
            }
            encrypted.append(cipher)
        }

        encryptedItems.withLock { items in
            items = Dictionary(encrypted.compactMap { cipher in cipher.id.map { ($0, cipher) } }, uniquingKeysWith: { first, _ in first })
        }
        let result: DecryptCipherListResult
        do {
            result = try await client.vault().ciphers().decryptListWithFailures(ciphers: encrypted)
        } catch {
            throw EngineError.unexpected("The SDK could not decrypt the vault.")
        }
        // An item that failed to decrypt is listed without a name, so that the user learns of it
        // and can delete it. What the server keeps of it in clear says where it belongs.
        var items: [VaultItemSummary] = []
        for cipher in result.failures {
            guard let id = cipher.id, let type = ItemType(cipher.type) else {
                omitted += 1
                continue
            }
            items.append(VaultItemSummary(id: id, type: type, name: "", isFavorite: cipher.favorite, folderID: cipher.folderId,
                                          isInTrash: cipher.deletedDate != nil, isArchived: cipher.archivedDate != nil,
                                          isUndecryptable: true, organizationID: cipher.organizationId,
                                          collectionIDs: cipher.collectionIds, isReadOnly: !cipher.edit,
                                          canDelete: cipher.permissions?.delete ?? cipher.edit))
        }
        for view in result.successes {
            guard let id = view.id, let type = ItemType(view.type) else {
                omitted += 1
                continue
            }
            var fields = Set(view.copyableFields.compactMap(ItemField.init))
            var cardBrand: String?
            var websiteHost: String?
            var matched: [ItemDraft.Website] = []
            var passkeys: [VaultPasskey] = []
            switch view.type {
            case .login(let login):
                // The list knows that a login has a passkey; where and whose it is, is in the whole item.
                if login.hasFido2, view.deletedDate == nil, let whole = try? await decrypted(id) { passkeys = self.passkeys(of: whole) }
                matched = (login.uris ?? []).compactMap { uri in
                    guard let address = uri.uri, !address.isEmpty else { return nil }
                    return ItemDraft.Website(address: address, match: uri.match.flatMap { WebsiteMatch(rawValue: Int($0.rawValue)) })
                }
                // The address of an app is kept among the websites and is none: it is not what
                // "copy website" copies, and it has no picture.
                let websites = matched.filter { $0.app == nil }.map(\.address)
                if websites.isEmpty { fields.remove(.website) } else { fields.insert(.website) }
                websiteHost = websites.first.flatMap(VaultItemSummary.websiteHost(of:))
            case .card(let card):
                cardBrand = card.brand
            default:
                break
            }
            items.append(VaultItemSummary(id: id, type: type, name: view.name, subtitle: view.subtitle,
                                          isFavorite: view.favorite, folderID: view.folderId,
                                          isInTrash: view.deletedDate != nil, isArchived: view.archivedDate != nil,
                                          fields: fields, cardBrand: cardBrand,
                                          websiteHost: websiteHost, asksForMasterPassword: view.reprompt == .password,
                                          attachmentCount: Int(view.attachments), websites: matched, passkeys: passkeys,
                                          organizationID: view.organizationId, collectionIDs: view.collectionIds,
                                          isReadOnly: !view.edit, canDelete: view.permissions?.delete ?? view.edit))
        }
        return VaultContents(items: items, folders: decryptFolders(root), omittedItemCount: omitted,
                             equivalentDomains: Self.equivalentDomains(root), sends: decryptSends(root),
                             organizations: Self.organizations(root), collections: decryptCollections(root))
    }

    /// The organizations of the sync profile whose key the server gave, by name. Their names
    /// are not encrypted.
    private static func organizations(_ root: [String: Any]) -> [VaultOrganization] {
        guard let profile = JSON.field(root, "Profile") as? [String: Any],
              let rows = JSON.field(profile, "Organizations") as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> VaultOrganization? in
            guard let id = JSON.string(row, "Id"), let name = JSON.string(row, "Name"), JSON.string(row, "Key") != nil,
                  (JSON.field(row, "Enabled") as? Bool) != false else { return nil }
            return VaultOrganization(id: id.lowercased(), name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A collection whose name does not decrypt is left out; its items show all the same.
    private func decryptCollections(_ root: [String: Any]) -> [VaultCollection] {
        var collections: [VaultCollection] = []
        for row in (JSON.field(root, "Collections") as? [[String: Any]]) ?? [] {
            guard let id = JSON.string(row, "Id"), let organizationID = JSON.string(row, "OrganizationId"),
                  let name = JSON.string(row, "Name") else { continue }
            let isReadOnly = (JSON.field(row, "ReadOnly") as? Bool) ?? false
            let collection = Collection(id: id, organizationId: organizationID, name: name, externalId: nil,
                                        hidePasswords: (JSON.field(row, "HidePasswords") as? Bool) ?? false, readOnly: isReadOnly,
                                        manage: (JSON.field(row, "Manage") as? Bool) ?? false, defaultUserCollectionEmail: nil,
                                        type: .sharedCollection, hasEnabledAccessRule: nil)
            guard let view = try? client.collections().decrypt(collection: collection), !view.name.isEmpty else { continue }
            collections.append(VaultCollection(id: id.lowercased(), organizationID: organizationID.lowercased(), name: view.name,
                                               isReadOnly: isReadOnly))
        }
        return collections
    }

    func decrypted(_ id: String) async throws -> CipherView {
        guard let cipher = encryptedItems.withLock({ $0[id] }) else { throw EngineError.notFound }
        do {
            return try await client.vault().ciphers().decrypt(cipher: cipher)
        } catch {
            // Strict decryption: an item with one damaged part does not open at all.
            throw EngineError.itemNotReadable
        }
    }

    func item(id: String) async throws -> VaultItem {
        let view = try await decrypted(id)
        guard let item = VaultItem(view, id: id) else { throw EngineError.notFound }
        return item
    }

    func verificationCode(itemID: String, at time: Date) async throws -> VerificationCode {
        guard let key = try await decrypted(itemID).login?.totp, !key.isEmpty else { throw EngineError.notFound }
        do {
            let response = try client.vault().generateTotp(key: key, time: time)
            return VerificationCode(code: response.code, period: Int(response.period))
        } catch {
            throw EngineError.unexpected("The SDK could not compute the verification code.")
        }
    }

    func isMasterPassword(_ password: String, material: AccountCryptoMaterial) async -> Bool {
        (try? await client.auth().validatePasswordUserKey(password: password, encryptedUserKey: material.masterKeyWrappedUserKey)) != nil
    }

    func fingerprintPhrase(userID: String) async throws -> [String] {
        do {
            return try client.platform().userFingerprint(fingerprintMaterial: userID).split(separator: "-").map(String.init)
        } catch {
            throw EngineError.unexpected("The SDK could not make the fingerprint phrase.")
        }
    }

    /// Organization keys from the sync profile. Without a usable key, that organization's
    /// items fail to decrypt and are counted as not shown; the personal vault is not affected.
    private func loadOrganizationKeys(_ root: [String: Any]) async {
        guard let profile = JSON.field(root, "Profile") as? [String: Any],
              let organizations = JSON.field(profile, "Organizations") as? [[String: Any]] else { return }
        var keys: [String: String] = [:]
        for organization in organizations {
            if let id = JSON.string(organization, "Id"), let key = JSON.string(organization, "Key") { keys[id] = key }
        }
        guard !keys.isEmpty else { return }
        try? await client.crypto().initializeOrgCrypto(req: InitOrgCryptoRequest(organizationKeys: keys))
    }

    /// The groups of domains that count as one: the ones the user made, and Bitwarden's own that
    /// the user did not turn off. They are not encrypted.
    private static func equivalentDomains(_ root: [String: Any]) -> [[String]] {
        guard let domains = JSON.field(root, "Domains") as? [String: Any] else { return [] }
        let own = (JSON.field(domains, "EquivalentDomains") as? [[String]]) ?? []
        let global = ((JSON.field(domains, "GlobalEquivalentDomains") as? [[String: Any]]) ?? []).compactMap { group -> [String]? in
            guard (JSON.field(group, "Excluded") as? Bool) != true else { return nil }
            return JSON.field(group, "Domains") as? [String]
        }
        return (own + global).map { $0.map { $0.lowercased() } }.filter { $0.count > 1 }
    }

    /// A folder whose name does not decrypt is left out; its items then show without a folder.
    private func decryptFolders(_ root: [String: Any]) -> [VaultFolder] {
        var folders: [VaultFolder] = []
        var encrypted: [Folder] = []
        for row in (JSON.field(root, "Folders") as? [[String: Any]]) ?? [] {
            guard let id = JSON.string(row, "Id"), let name = JSON.string(row, "Name") else { continue }
            let folder = Folder(id: id, name: name, revisionDate: Date(timeIntervalSince1970: 0))
            guard let view = try? client.vault().folders().decrypt(folder: folder), !view.name.isEmpty else { continue }
            folders.append(VaultFolder(id: id, name: view.name))
            encrypted.append(folder)
        }
        // An export names the folders of its items.
        encryptedFolders.withLock { $0 = encrypted }
        return folders
    }
}

// MARK: Conversions between engine values and SDK values

extension Kdf {
    init(_ kdf: KeyDerivation) {
        switch kdf {
        case .pbkdf2(let iterations):
            self = .pbkdf2(iterations: iterations)
        case .argon2id(let iterations, let memory, let parallelism):
            self = .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
        }
    }
}

extension WrappedAccountCryptographicState {
    init(_ keys: AccountKeys) {
        switch keys {
        case .v1(let privateKey):
            self = .v1(privateKey: privateKey)
        case .v2(let privateKey, let signedPublicKey, let signingKey, let securityState):
            self = .v2(privateKey: privateKey, signedPublicKey: signedPublicKey, signingKey: signingKey, securityState: securityState)
        }
    }
}

extension VaultItem {
    /// nil for the item types PassVault does not show.
    init?(_ view: CipherView, id: String) {
        let content: ItemContent
        switch view.type {
        case .login:
            let login = view.login
            content = .login(LoginContent(
                username: login?.username, password: login?.password,
                hasVerificationCode: login?.totp?.isEmpty == false,
                websites: (login?.uris ?? []).compactMap { $0.uri?.isEmpty == false ? $0.uri : nil },
                passkeyCreated: login?.fido2Credentials?.first?.creationDate))
        case .card:
            let card = view.card
            content = .card(CardContent(cardholderName: card?.cardholderName, brand: card?.brand, number: card?.number,
                                        expirationMonth: card?.expMonth, expirationYear: card?.expYear, securityCode: card?.code))
        case .identity:
            var identity = IdentityContent()
            if let source = view.identity {
                identity.title = source.title
                identity.firstName = source.firstName
                identity.middleName = source.middleName
                identity.lastName = source.lastName
                identity.username = source.username
                identity.company = source.company
                identity.socialSecurityNumber = source.ssn
                identity.passportNumber = source.passportNumber
                identity.licenseNumber = source.licenseNumber
                identity.email = source.email
                identity.phone = source.phone
                identity.address1 = source.address1
                identity.address2 = source.address2
                identity.address3 = source.address3
                identity.city = source.city
                identity.state = source.state
                identity.postalCode = source.postalCode
                identity.country = source.country
            }
            content = .identity(identity)
        case .secureNote:
            content = .secureNote
        case .sshKey:
            guard let key = view.sshKey else { return nil }
            content = .sshKey(SSHKeyContent(privateKey: key.privateKey, publicKey: key.publicKey, fingerprint: key.fingerprint))
        default:
            return nil
        }
        let fields = (view.fields ?? []).map { field in
            let value: CustomField.Value = switch field.type {
            case .text: .text(field.value ?? "")
            case .hidden: .hidden(field.value ?? "")
            case .boolean: .boolean(field.value == "true")
            case .linked: .linked(Int(field.linkedId ?? 0))
            }
            return CustomField(name: field.name ?? "", value: value)
        }
        self.init(id: id, name: view.name, notes: view.notes, isFavorite: view.favorite, folderID: view.folderId,
                  isInTrash: view.deletedDate != nil, isArchived: view.archivedDate != nil,
                  asksForMasterPassword: view.reprompt == .password, content: content,
                  customFields: fields, created: view.creationDate, revised: view.revisionDate,
                  passwordRevised: view.login?.passwordRevisionDate, passwordHistoryCount: view.passwordHistory?.count ?? 0,
                  attachments: (view.attachments ?? []).compactMap { attachment in
                      attachment.id.map {
                          ItemAttachment(id: $0, fileName: attachment.fileName ?? "", sizeName: attachment.sizeName ?? "",
                                         hasOwnKey: attachment.key != nil)
                      }
                  })
    }
}

extension ItemField {
    /// nil for the fields of item types PassVault does not show.
    init?(_ field: CopyableCipherFields) {
        switch field {
        case .loginUsername: self = .username
        case .loginPassword: self = .password
        case .loginTotp: self = .verificationCode
        case .cardNumber: self = .cardNumber
        case .cardSecurityCode: self = .cardSecurityCode
        case .identityUsername: self = .identityUsername
        case .identityEmail: self = .identityEmail
        case .identityPhone: self = .identityPhone
        case .identityAddress: self = .identityAddress
        case .sshKey: self = .sshKey
        case .secureNotes: self = .notes
        default: return nil
        }
    }
}

extension ItemType {
    /// nil for the item types PassVault does not show.
    init?(_ type: CipherType) {
        switch type {
        case .login: self = .login
        case .secureNote: self = .secureNote
        case .card: self = .card
        case .identity: self = .identity
        case .sshKey: self = .sshKey
        default: return nil
        }
    }

    /// nil for the item types PassVault does not show.
    init?(_ type: CipherListViewType) {
        switch type {
        case .login: self = .login
        case .secureNote: self = .secureNote
        case .card: self = .card
        case .identity: self = .identity
        case .sshKey: self = .sshKey
        default: return nil
        }
    }
}
