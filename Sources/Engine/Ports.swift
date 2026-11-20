import Foundation
import VaultModel

// The engine reaches the outside world only through these protocols.
// Implementations throw `EngineError`. The engine never reads another error's content.

public struct EnginePorts: Sendable {
    public var server: any ServerPort
    public var crypto: any CryptoPort
    public var store: any AccountStorePort
    public var systemEvents: any SystemEventsPort
    public var clipboard: any ClipboardPort
    public var leaks: any PasswordLeaksPort
    public var activeField: any ActiveFieldPort
    public var identities: any CredentialIdentitiesPort
    public var sshAgent: any SSHAgentPort
    public var appSignatures: any AppSignaturesPort
    public var biometrics: any BiometricKeysPort
    public var avatars: any AccountAvatarPort

    public init(server: any ServerPort, crypto: any CryptoPort, store: any AccountStorePort,
                systemEvents: any SystemEventsPort, clipboard: any ClipboardPort, leaks: any PasswordLeaksPort,
                activeField: any ActiveFieldPort = NoActiveField(),
                identities: any CredentialIdentitiesPort = NoCredentialIdentities(),
                sshAgent: any SSHAgentPort = NoSSHAgent(),
                appSignatures: any AppSignaturesPort = NoAppSignatures(),
                biometrics: any BiometricKeysPort = NoBiometricKeys(),
                avatars: any AccountAvatarPort = NoAccountAvatars()) {
        self.avatars = avatars
        self.sshAgent = sshAgent
        self.appSignatures = appSignatures
        self.biometrics = biometrics
        self.server = server
        self.crypto = crypto
        self.store = store
        self.systemEvents = systemEvents
        self.clipboard = clipboard
        self.leaks = leaks
        self.activeField = activeField
        self.identities = identities
    }
}

/// Optional public account pictures. No vault credentials cross this port.
public protocol AccountAvatarPort: Sendable {
    func image(email: String) async -> Data?
}

public struct NoAccountAvatars: AccountAvatarPort {
    public init() {}
    public func image(email: String) async -> Data? { nil }
}

// MARK: AutoFill of the system

/// The store of the system that holds what AutoFill may offer: for which website whose
/// login there is. It holds no secret, and the system shows its entries while the vault is
/// locked too.
public protocol CredentialIdentitiesPort: Sendable {
    /// Whether the user has turned PassVault on as a source of AutoFill. Nothing is stored
    /// before that.
    func isEnabled() async -> Bool
    /// Makes these the entries of the store, in place of all it had.
    func replace(with identities: [AutoFillIdentity]) async
    func removeAll() async
}

/// No AutoFill: for runs that must leave no entry in the store of the system.
public struct NoCredentialIdentities: CredentialIdentitiesPort {
    public init() {}
    public func isEnabled() async -> Bool { false }
    public func replace(with identities: [AutoFillIdentity]) async {}
    public func removeAll() async {}
}

// MARK: Fill

/// Rechecks the unlocked session immediately before a credential leaves the adapter.
public typealias FillAuthorization = @Sendable () async throws -> Void

/// The field that has the cursor in the app the user works in. Quick access fills it with one
/// value of an item. Only the port touches another app; the engine tells it the value.
public protocol ActiveFieldPort: Sendable {
    /// Whether the system lets PassVault use the fields of other apps.
    func isAllowed() async -> Bool
    /// Has the system ask the user for that permission, or shows where it is given. Called only
    /// after the user chose to fill.
    func askToBeAllowed() async
    /// The field that has the cursor now. nil when the app in front has no field that takes a
    /// text, is PassVault itself or a part of the system, or when PassVault is not allowed.
    func capture() async -> FillTarget?
    /// Puts the text into that field, if it still has the cursor in the same app. It tries once:
    /// a second try after an unclear failure could write the value twice.
    func write(_ text: String, to target: FillTarget, authorize: FillAuthorization) async throws
    /// Puts a user name and a password into the two fields of the login form of a target that
    /// `takesLogin`, under the same rules. Throws `EngineError.fill(.noField)` for another target.
    func writeLogin(username: String, password: String, verificationCode: String?, to target: FillTarget, authorize: FillAuthorization) async throws
}

/// A field that was captured for a fill. It names the app, and the web page of a browser, so
/// that the user can see where the value goes; the field itself stays with the port.
public struct FillTarget: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    /// The name of the app as the system shows it.
    public let appName: String
    public let bundleID: String?
    /// The app as its running code is signed: its bundle identifier and its developer. A login
    /// that has this address belongs to the app. nil for a browser, where the page decides, and
    /// for an app without a valid signature of a developer, which could be any app.
    public let app: AppAddress?
    /// The address of the web page the field is on, when the app is a browser that tells it.
    public let website: String?
    /// The field hides what is typed: a password field.
    public let isSecure: Bool
    /// The focused field explicitly identifies itself as a one-time verification code.
    public let isVerificationCode: Bool
    /// Code-like metadata is present, but it does not identify an authenticator field.
    public let isUnclassifiedCode: Bool
    /// A single, identified verification-code field belongs to the captured login form.
    public let takesVerificationCode: Bool
    /// The field is one of the two fields of a login form: a user name and a password can be
    /// filled together (`LoginFormFields`).
    public let takesLogin: Bool
    /// The cursor is in a field that takes one value. false for a page or a window in which
    /// no field has the cursor and a login form was found: it takes a login and nothing else.
    public let takesValue: Bool

    public init(id: UUID = UUID(), appName: String, bundleID: String? = nil, app: AppAddress? = nil, website: String? = nil,
                isSecure: Bool = false, takesLogin: Bool = false, takesValue: Bool = true,
                isVerificationCode: Bool = false, takesVerificationCode: Bool = false,
                isUnclassifiedCode: Bool = false) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.app = app
        self.website = website
        self.isSecure = isSecure
        self.isVerificationCode = isVerificationCode
        self.isUnclassifiedCode = isUnclassifiedCode
        self.takesVerificationCode = takesVerificationCode
        self.takesLogin = takesLogin
        self.takesValue = takesValue
    }

    public var suggestedLoginField: ItemField? {
        guard !isUnclassifiedCode else { return nil }
        return isVerificationCode ? .verificationCode : (isSecure ? .password : .username)
    }
}

/// No fill at all: for the tests of the adapters, which fill nothing.
public struct NoActiveField: ActiveFieldPort {
    public init() {}
    public func isAllowed() async -> Bool { false }
    public func askToBeAllowed() async {}
    public func capture() async -> FillTarget? { nil }
    public func write(_ text: String, to target: FillTarget, authorize: FillAuthorization) async throws { throw EngineError.fill(.notAllowed) }
    public func writeLogin(username: String, password: String, verificationCode: String?, to target: FillTarget, authorize: FillAuthorization) async throws {
        throw EngineError.fill(.notAllowed)
    }
}

// MARK: Apps

/// Who signed an app of the disk. The system checks the signature; the port reads what it says.
public protocol AppSignaturesPort: Sendable {
    /// The app in this folder as its code is signed. nil for what is no app, and for an app
    /// without a valid signature of a developer or of Apple.
    func app(at location: URL) async -> SignedApp?
    func runningApps() async -> [RunningApp]
    /// Resolve an opaque selection against the running process again, not a client-supplied path.
    func app(runningID: UUID) async -> SignedApp?
}

public extension AppSignaturesPort {
    func runningApps() async -> [RunningApp] { [] }
    func app(runningID: UUID) async -> SignedApp? { nil }
}

/// Display metadata for a verified running app. Only the opaque ID selects its process.
public struct RunningApp: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let location: URL
    public let address: AppAddress

    public init(id: UUID, name: String, location: URL, address: AppAddress) {
        self.id = id
        self.name = name
        self.location = location
        self.address = address
    }
}

/// An app of the disk as its code signature names it.
public struct SignedApp: Sendable, Equatable {
    public let address: AppAddress
    /// The app opens web pages: a browser. A login belongs to its pages, never to the browser.
    public let isBrowser: Bool

    public init(address: AppAddress, isBrowser: Bool = false) {
        self.address = address
        self.isBrowser = isBrowser
    }
}

/// No app is read: for the tests of the adapters.
public struct NoAppSignatures: AppSignaturesPort {
    public init() {}
    public func app(at location: URL) async -> SignedApp? { nil }
}

// MARK: Leaked passwords

/// The service that knows passwords from data leaks. It is not the server of the account.
public protocol PasswordLeaksPort: Sendable {
    /// How often the password is in known leaks; 0 when it is in none. An implementation must
    /// not send the password or its whole hash anywhere.
    func timesLeaked(_ password: String) async throws -> Int
}

// MARK: Server

public protocol ServerPort: Sendable {
    /// The key derivation settings of an account. Servers answer for unknown accounts too.
    func prelogin(server: URL, email: String) async throws -> Prelogin
    /// Throws `EngineError.invalidCredentials` for a wrong email or master password and
    /// `EngineError.invalidTwoStepCode` for a second step the server does not accept.
    func logIn(_ request: LoginRequest) async throws -> LoginOutcome
    /// Asks the server to send a code for the second step to the address of the account.
    /// The request names the account; its second step is not used.
    func sendTwoStepEmail(_ request: LoginRequest) async throws
    /// Asks the server to send the hint of the master password to the address of an account.
    /// The server answers the same for an address it does not know.
    func requestPasswordHint(server: URL, email: String) async throws
    /// Whether the server has seen this installation log in to the account. It needs no session.
    func isKnownDevice(server: URL, email: String, deviceIdentifier: String) async throws -> Bool
    /// The encrypted sync response. The engine stores it and gives it to the crypto port unread.
    /// Throws `EngineError.sessionExpired` when the server no longer accepts the access token.
    func sync(server: URL, accessToken: String) async throws -> Data
    /// New tokens for a refresh token. Throws `EngineError.sessionExpired` when the server refuses it.
    func refresh(server: URL, refreshToken: String) async throws -> TokenRefresh
    /// The picture of a website as the server's icon service gives it (an image file).
    func websiteIcon(server: URL, host: String) async throws -> Data
    /// Changes one item on the server. Throws `EngineError.sessionExpired` when the server no
    /// longer accepts the access token, and `EngineError.server` when it refuses the change.
    func write(_ write: ItemWrite, itemID: String, server: URL, accessToken: String) async throws
    /// The same change of several items in one request. Throws like `write(_:itemID:)`.
    func write(_ write: ItemBulkWrite, itemIDs: [String], server: URL, accessToken: String) async throws
    /// Creates an item (`itemID` nil) or replaces one, from the encrypted request the crypto port
    /// has made. Returns the identifier of the item. Throws `EngineError.itemChanged` when the
    /// server has a newer copy of the item than the request was made from.
    func save(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String
    /// Creates an item of an organization in its collections (`itemID` nil), or gives an item
    /// of the user to an organization and puts it into collections, from the encrypted request
    /// the crypto port has made. Returns the identifier of the item.
    func share(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String
    /// Sets the collections an item of an organization is in.
    func setCollections(_ collectionIDs: [String], itemID: String, server: URL, accessToken: String) async throws
    /// Adds a folder (`id` nil) or renames one; the name is encrypted by the crypto port.
    /// Returns the identifier of the folder.
    func saveFolder(id: String?, encryptedName: String, server: URL, accessToken: String) async throws -> String
    /// Creates the folders and the items of an import in one call, from the encrypted request
    /// the crypto port has made.
    func importVault(request: Data, server: URL, accessToken: String) async throws
    /// Deletes a folder. The server leaves its items in the vault without a folder.
    func deleteFolder(id: String, server: URL, accessToken: String) async throws
    /// Adds an encrypted file to an item. When the file cannot be stored, nothing of it stays on the server.
    /// `progress` hears the part of the file that has gone, from 0 to 1, while it is sent.
    /// Returns the identifier the server gave the new attachment.
    @discardableResult
    func addAttachment(_ attachment: EncryptedAttachment, itemID: String, server: URL, accessToken: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// The encrypted content of one file of an item, fetched from this server only.
    func attachmentContents(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws -> Data
    func deleteAttachment(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws
    /// Creates a Send (`sendID` nil) or replaces one, from the encrypted request the crypto port
    /// has made. Returns the identifier of the Send.
    func saveSend(request: Data, sendID: String?, server: URL, accessToken: String) async throws -> String
    /// Creates a file Send: the request opens a place for the file, then the encrypted file is
    /// brought. When the file cannot be stored, nothing of the Send stays on the server.
    func saveFileSend(request: Data, file: EncryptedSendFile, server: URL, accessToken: String) async throws -> String
    func deleteSend(id: String, server: URL, accessToken: String) async throws
    /// Takes the password from a Send: its link then opens without one.
    func removeSendPassword(id: String, server: URL, accessToken: String) async throws
}

/// A Send as the crypto port has encrypted it for the server.
public struct EncryptedSend: Sendable, Equatable {
    public var request: Data
    /// The file of a new file Send.
    public var file: EncryptedSendFile?

    public init(request: Data, file: EncryptedSendFile? = nil) {
        self.request = request
        self.file = file
    }
}

public struct EncryptedSendFile: Sendable, Equatable {
    public var fileName: String
    public var contents: Data

    public init(fileName: String, contents: Data) {
        self.fileName = fileName
        self.contents = contents
    }
}

/// A file as the crypto port has encrypted it for an item.
public struct EncryptedAttachment: Sendable, Equatable {
    /// The key of the file, wrapped by the key of the item.
    public var key: String
    public var fileName: String
    public var contents: Data

    public init(key: String, fileName: String, contents: Data) {
        self.key = key
        self.fileName = fileName
        self.contents = contents
    }
}

/// A change the server makes to several items at once.
public enum ItemBulkWrite: Sendable, Equatable {
    /// nil takes the items out of their folders. The favourite marks stay.
    case moveToFolder(String?)
    case archive, unarchive
    case moveToTrash, restore
    case deletePermanently
}

/// A change of an item in the form the server takes it.
public enum ItemWrite: Sendable, Equatable {
    /// The server sets the favourite mark and the folder of an item together.
    case placement(isFavorite: Bool, folderID: String?)
    case archive, unarchive
    case moveToTrash, restore
    /// Removes the item for ever.
    case deletePermanently
}

public struct TokenRefresh: Sendable {
    public var accessToken: String
    /// nil when the server keeps the old refresh token.
    public var refreshToken: String?
    public var expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public enum KeyDerivation: Sendable, Codable, Equatable {
    case pbkdf2(iterations: UInt32)
    case argon2id(iterations: UInt32, memory: UInt32, parallelism: UInt32)

    /// New network authentication uses current work factors. Existing offline accounts
    /// retain support for older costs, with the same upper bounds on CPU and memory.
    public func isSupported(forNetworkLogin: Bool) -> Bool {
        switch self {
        case .pbkdf2(let iterations):
            let minimum: UInt32 = forNetworkLogin ? 600_000 : 5_000
            return (minimum...2_000_000).contains(iterations)
        case .argon2id(let iterations, let memory, let parallelism):
            return (2...10).contains(iterations) && (16...1_024).contains(memory)
                && (1...16).contains(parallelism)
                && (!forNetworkLogin || (memory >= 32 && memory * iterations >= 192))
        }
    }
}

public struct Prelogin: Sendable, Codable, Equatable {
    public var kdf: KeyDerivation
    public var salt: String

    public init(kdf: KeyDerivation, salt: String) {
        self.kdf = kdf
        self.salt = salt
    }
}

public struct LoginRequest: Sendable {
    public var server: URL
    public var email: String
    /// The master password hash for server authorization, never the master password.
    public var passwordHash: String
    public var prelogin: Prelogin
    public var deviceIdentifier: String
    public var twoStep: TwoStepProof?

    public init(server: URL, email: String, passwordHash: String, prelogin: Prelogin, deviceIdentifier: String,
                twoStep: TwoStepProof? = nil) {
        self.server = server
        self.email = email
        self.passwordHash = passwordHash
        self.prelogin = prelogin
        self.deviceIdentifier = deviceIdentifier
        self.twoStep = twoStep
    }
}

public struct LoginGrant: Sendable {
    public var userID: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval
    public var crypto: AccountCryptoMaterial
    /// The token that replaces the second step on this installation, when the request asked for one.
    public var twoStepRememberToken: String?

    public init(userID: String, accessToken: String, refreshToken: String?, expiresIn: TimeInterval,
                crypto: AccountCryptoMaterial, twoStepRememberToken: String? = nil) {
        self.userID = userID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.crypto = crypto
        self.twoStepRememberToken = twoStepRememberToken
    }
}

/// The wrapped keys of an account as the server stores them. Useless without the master password.
public struct AccountCryptoMaterial: Sendable, Codable, Equatable {
    public var kdf: KeyDerivation
    public var salt: String
    public var masterKeyWrappedUserKey: String
    /// The identifier of the wrapped user key, when the server names it.
    public var userKeyID: String?
    public var keys: AccountKeys

    public init(kdf: KeyDerivation, salt: String, masterKeyWrappedUserKey: String, userKeyID: String? = nil,
                keys: AccountKeys) {
        self.kdf = kdf
        self.salt = salt
        self.masterKeyWrappedUserKey = masterKeyWrappedUserKey
        self.userKeyID = userKeyID
        self.keys = keys
    }
}

public enum AccountKeys: Sendable, Codable, Equatable {
    case v1(privateKey: String)
    case v2(privateKey: String, signedPublicKey: String, signingKey: String, securityState: String)
}

// MARK: Cryptography

public protocol CryptoPort: Sendable {
    func serverPasswordHash(password: String, prelogin: Prelogin) async throws -> String
    /// Throws `EngineError.wrongMasterPassword` when the password does not open the user key.
    func unlock(_ request: UnlockRequest) async throws -> any UnlockedCrypto
    /// Throws `EngineError.wrongPin` when the PIN does not open the envelope.
    func unlock(_ request: PinUnlockRequest) async throws -> any UnlockedCrypto
    /// Opens the keys with the user key itself, which the Keychain kept behind Touch ID.
    /// Throws `EngineError.biometrics(.keyRejected)` when the key does not open the account.
    func unlock(_ request: KeyUnlockRequest) async throws -> any UnlockedCrypto
    /// A new password, passphrase or user name. The options are normalized already.
    func generate(_ request: GeneratorRequest) async throws -> String
    /// A new SSH key pair (Ed25519) with its fingerprint.
    func newSSHKey() async throws -> SSHKeyContent
    /// The SSH key of a private key text, with the password of an encrypted one.
    /// Throws `EngineError.sshKeyImport`.
    func importSSHKey(_ text: String, password: String?) async throws -> SSHKeyContent
}

/// The keys of one unlocked vault. Dropping the last reference removes them from memory.
public protocol UnlockedCrypto: Sendable {
    func decryptVault(syncPayload: Data) async throws -> VaultContents
    /// One item of the vault that was decrypted last. Throws `EngineError.notFound` for an unknown item.
    func item(id: String) async throws -> VaultItem
    /// The current code of a login with a verification code. Throws `EngineError.notFound` without one.
    func verificationCode(itemID: String, at time: Date) async throws -> VerificationCode
    /// Whether this is the master password of the account.
    func isMasterPassword(_ password: String, material: AccountCryptoMaterial) async -> Bool
    /// The vault of the user as an export file of Bitwarden: the items that are not in the trash
    /// and not of an organization, and the folders. The SDK writes the file.
    func exportVault(format: VaultExportFormat) async throws -> Data
    /// The encrypted request that creates the folders and the items of an import.
    func encryptImport(_ file: VaultImport) async throws -> Data
    /// One Send of the vault that was decrypted last, with what it carries and the path of its
    /// link. Throws `EngineError.notFound` for an unknown Send.
    func send(id: String) async throws -> VaultSend
    /// The encrypted request that creates the Send of a draft, or replaces the Send it was made
    /// from; with the encrypted file of a new file Send. The SDK makes the key of a new Send.
    func encryptSend(_ draft: SendDraft) async throws -> EncryptedSend
    /// The fingerprint phrase of the account: five words made from its public key, by which two
    /// people can see that they look at the same account.
    func fingerprintPhrase(userID: String) async throws -> [String]
    /// What the form of one item of the vault holds. Throws `EngineError.itemNotWritable` for an
    /// item that could not be written back whole.
    func draft(id: String) async throws -> ItemDraft
    /// The encrypted request that creates the item of a draft, or replaces the item it was made
    /// from and keeps every part of that item the draft does not hold. Throws
    /// `EngineError.itemNotWritable`, and `EngineError.itemChanged` for a draft of an older revision.
    func encrypt(_ draft: ItemDraft) async throws -> Data
    /// The encrypted request that gives an item of the user to an organization, in these
    /// collections: the SDK encrypts the item again under the key of the organization. Throws
    /// `EngineError.itemNotWritable` for an item that could not be written back whole.
    func encryptShare(itemID: String, organizationID: String, collectionIDs: [String]) async throws -> Data
    /// The name of a folder as the server stores it.
    func encryptFolderName(_ name: String) async throws -> String
    /// The earlier passwords of an item, the newest first. Empty for an item without a history.
    func passwordHistory(id: String) async throws -> [PasswordHistoryEntry]
    /// A value of the generator, encrypted under the keys of the account for its history.
    func encryptGenerated(_ value: GeneratedValue) async throws -> Data
    /// The values of stored history entries, in their order; nil for an entry that does not decrypt.
    func decryptGenerated(_ entries: [Data]) async throws -> [GeneratedValue?]
    /// A file encrypted for an item of the vault. Throws `EngineError.itemNotWritable` for an item
    /// that could not be written back whole.
    func encryptAttachment(itemID: String, fileName: String, data: Data) async throws -> EncryptedAttachment
    /// The content of a file of an item. Throws `EngineError.notFound` for an unknown file.
    func decryptAttachment(itemID: String, attachmentID: String, contents: Data) async throws -> Data
    /// Signs with the passkey of a login for a website. The SDK holds the key and makes the
    /// signature. Throws `EngineError.notFound` for a login without a passkey of that website.
    func passkeyAssertion(_ request: PasskeyAssertionRequest) async throws -> PasskeySigned
    /// Makes a passkey and puts it into the login the request names, or into a new login with
    /// this name. Nothing is stored yet: the answer holds the encrypted item for the server.
    /// Throws `EngineError.passkeyExists` when the vault has a passkey the request excludes.
    func makePasskey(_ request: PasskeyRegistrationRequest, newLoginName: String) async throws -> PasskeyMade
    /// The SSH keys of the vault that the agent can sign with: of items that are not in the
    /// trash and not archived, each by its public part.
    func sshIdentities() async -> [SSHAgentIdentity]
    /// The signature of the SSH key of an item over the data, as SSH writes it on the wire. The
    /// private key stays with the port. Throws `EngineError.notFound` for an item without the
    /// key the request names.
    func sshSignature(itemID: String, publicKeyBlob: Data, data: Data, flags: UInt32) async throws -> Data
    /// The user key of the unlocked account, as `KeyUnlockRequest` takes it back. It is for
    /// the Keychain of the system only, which keeps it behind Touch ID.
    func userKey() async throws -> String
    /// Wraps the user key with a key made from a new PIN.
    func enrollPin(_ pin: String) async throws -> PinEnrollment
    /// The same for the PIN that was enrolled before, from its encrypted form.
    func enrollPin(encryptedPin: String) async throws -> PinEnrollment
}

/// An item the SDK changed while it worked with a passkey, encrypted for the server.
public struct PasskeySave: Sendable {
    /// The item that is replaced. nil for a new item.
    public var itemID: String?
    public var request: Data

    public init(itemID: String?, request: Data) {
        self.itemID = itemID
        self.request = request
    }
}

public struct PasskeySigned: Sendable {
    public var assertion: PasskeyAssertion
    /// The login, when signing changed it: a passkey that counts its uses.
    public var save: PasskeySave?

    public init(assertion: PasskeyAssertion, save: PasskeySave? = nil) {
        self.assertion = assertion
        self.save = save
    }
}

public struct PasskeyMade: Sendable {
    public var registration: PasskeyRegistration
    public var save: PasskeySave

    public init(registration: PasskeyRegistration, save: PasskeySave) {
        self.registration = registration
        self.save = save
    }
}

public struct UnlockRequest: Sendable {
    public var userID: String
    public var email: String
    public var material: AccountCryptoMaterial
    public var masterPassword: String

    public init(userID: String, email: String, material: AccountCryptoMaterial, masterPassword: String) {
        self.userID = userID
        self.email = email
        self.material = material
        self.masterPassword = masterPassword
    }
}

// MARK: Storage

public protocol AccountStorePort: Sendable {
    /// A stable identifier of this installation. It survives logout.
    func deviceIdentifier() async throws -> String
    func load() async throws -> StoredAccount?
    func save(_ account: StoredAccount) async throws
    /// Removes the account. Its settings stay for the next login.
    func clear() async throws
    func pendingLogout() async throws -> String?
    func setPendingLogout(_ accountID: String?) async throws
    /// The other accounts that are logged in on this Mac beside the stored one. Each is kept as
    /// it was stored, and can take the place of the stored one. The one that was put aside last
    /// comes first: the order of the account menu of the reference, "most recently active first".
    func parkedAccounts() async throws -> [Account]
    /// Puts the stored account aside, with everything `clear()` would remove. No account is
    /// the stored one after it.
    func park() async throws
    /// Makes a parked account the stored one. There must be no stored account.
    func unpark(accountID: String) async throws
    /// Removes a parked account, as `clear()` removes the stored one.
    func removeParked(accountID: String) async throws
    /// The settings saved for an account on this Mac; nil when there are none.
    func loadSettings(accountID: String) async throws -> EngineSettings?
    func saveSettings(_ settings: EngineSettings, accountID: String) async throws
    /// The PIN of an account on this Mac; nil when it has none.
    func loadPin(accountID: String) async throws -> StoredPin?
    /// nil removes the PIN.
    func savePin(_ pin: StoredPin?, accountID: String) async throws
    /// The token a server gave this installation in place of the second step of a log-in.
    /// It is a secret of the account and survives a logout.
    func twoStepRememberToken(server: URL, email: String) async throws -> String?
    /// nil removes the token.
    func saveTwoStepRememberToken(_ token: String?, server: URL, email: String) async throws
    /// The history of the generator of the stored account, the newest entry first, each one
    /// encrypted by the crypto port. `clear()` removes it with the account.
    func loadGeneratorHistory() async throws -> [Data]
    func saveGeneratorHistory(_ entries: [Data]) async throws
}

/// What stays on this Mac while an account is logged in. Nothing in it is decrypted vault data.
public struct StoredAccount: Sendable, Codable, Equatable {
    public var account: Account
    public var crypto: AccountCryptoMaterial
    public var accessToken: String
    public var refreshToken: String?
    public var accessTokenExpiry: Date
    var hasSessionCredentials: Bool { !accessToken.isEmpty || refreshToken?.isEmpty == false }
    /// The last encrypted sync response.
    public var vaultPayload: Data?
    public var lastSync: Date?

    public init(account: Account, crypto: AccountCryptoMaterial, accessToken: String, refreshToken: String?,
                accessTokenExpiry: Date, vaultPayload: Data?, lastSync: Date?) {
        self.account = account
        self.crypto = crypto
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
        self.vaultPayload = vaultPayload
        self.lastSync = lastSync
    }
}

// MARK: Clipboard

public protocol ClipboardPort: Sendable {
    /// `isSensitive` asks clipboard managers not to keep the text.
    func copy(_ text: String, isSensitive: Bool) async
    /// Empties the clipboard when it still holds this text.
    func clear(ifStill text: String) async
    /// The text on the clipboard. The engine reads it only when the user asks for an import.
    func read() async -> String?
}

// MARK: System events

public enum SystemEvent: Sendable, Equatable {
    case screenLocked, willSleep, systemIdle
}

public protocol SystemEventsPort: Sendable {
    func events() -> AsyncStream<SystemEvent>
}
