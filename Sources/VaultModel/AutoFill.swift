import Foundation

/// What the AutoFill of the system knows of a login before it asks for it: where the login
/// is used and whose it is. It holds no password, code or key. The system shows such entries
/// over a form; the vault is asked only when the user takes one.
public struct AutoFillIdentity: Sendable, Codable, Hashable {
    /// What the system gets when the user takes the entry.
    public enum Kind: String, Sendable, Codable {
        case password, verificationCode, passkey
    }

    public var kind: Kind
    /// The item the identity stands for.
    public var itemID: String
    /// The website of the login as the item has it.
    public var website: String
    /// The user name. An entry for a verification code of a login without one has the name of
    /// the item here: the system shows it beside the code.
    public var username: String
    /// Of a passkey: its identifier and the handle of its user, as the website knows them.
    /// The website of a passkey is the identifier of its relying party.
    public var credentialID: Data?
    public var userHandle: Data?

    public init(kind: Kind = .password, itemID: String, website: String, username: String,
                credentialID: Data? = nil, userHandle: Data? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.website = website
        self.username = username
        self.credentialID = credentialID
        self.userHandle = userHandle
    }
}

/// A passkey of a login as the lists know it: where it is used and whose it is. The key
/// itself never leaves the SDK.
public struct VaultPasskey: Sendable, Codable, Hashable {
    public var credentialID: Data
    /// The identifier of the relying party: the domain the passkey is for.
    public var rpID: String
    public var userName: String
    public var userHandle: Data

    public init(credentialID: Data, rpID: String, userName: String, userHandle: Data) {
        self.credentialID = credentialID
        self.rpID = rpID
        self.userName = userName
        self.userHandle = userHandle
    }
}

public extension VaultContents {
    /// The logins the system may offer for a password, by the rule of the reference
    /// (`sync` of apps/desktop/src/autofill/services/desktop-autofill.service.ts): a login that is
    /// not deleted, with a user name, a password and a website that is not matched "never";
    /// one identity for each, with the first such website. The address of an app is no website. An archived login is left out too,
    /// as it is no suggestion anywhere in Bitwarden, and so is a login that asks for the master
    /// password again: the extension has no field for it, so it could never give that login.
    var passwordIdentities: [AutoFillIdentity] {
        items.compactMap { item in
            guard item.type == .login, !item.isInTrash, !item.isArchived, !item.isUndecryptable,
                  !item.asksForMasterPassword,
                  item.fields.contains(.password), item.fields.contains(.username),
                  !item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let website = item.websites.first(where: { site in
                      site.match != .never && site.app == nil
                          && !site.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { return nil }
            return AutoFillIdentity(itemID: item.id, website: website.address, username: item.subtitle)
        }
    }

    /// The logins the system may offer for a verification code: as above, but with an
    /// authenticator key in place of the password, and with or without a user name.
    var verificationCodeIdentities: [AutoFillIdentity] {
        items.compactMap { item in
            guard item.type == .login, !item.isInTrash, !item.isArchived, !item.isUndecryptable,
                  !item.asksForMasterPassword, item.fields.contains(.verificationCode),
                  let website = item.websites.first(where: { site in
                      site.match != .never && site.app == nil
                          && !site.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { return nil }
            let username = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return AutoFillIdentity(kind: .verificationCode, itemID: item.id, website: website.address,
                                    username: username.isEmpty ? item.name : item.subtitle)
        }
    }

    /// The passkeys the system may offer: those of the logins that are not deleted or
    /// archived and do not ask for the master password again.
    var passkeyIdentities: [AutoFillIdentity] {
        items.flatMap { item -> [AutoFillIdentity] in
            guard item.type == .login, !item.isInTrash, !item.isArchived, !item.isUndecryptable,
                  !item.asksForMasterPassword else { return [] }
            return item.passkeys.map { passkey in
                AutoFillIdentity(kind: .passkey, itemID: item.id, website: passkey.rpID,
                                 username: passkey.userName.isEmpty ? item.subtitle : passkey.userName,
                                 credentialID: passkey.credentialID, userHandle: passkey.userHandle)
            }
        }
    }

    /// All the entries of the system's store.
    var autoFillIdentities: [AutoFillIdentity] {
        passwordIdentities + verificationCodeIdentities + passkeyIdentities
    }
}

// MARK: What the AutoFill extension asks

/// A question of the AutoFill extension to the engine. The extension runs in a process of its
/// own, in a sandbox, and holds nothing: it asks for what one request of the system needs.
public enum AutoFillRequest: Sendable, Codable, Equatable {
    /// Whether there is a vault to ask, and how it can be unlocked.
    case status
    /// The logins of these websites, as the system names them: a domain or a URL. Without a
    /// website, every login that can be filled, for the user to choose from.
    case logins(services: [String])
    /// The user name and the password of one login.
    case password(itemID: String)
    /// The verification code of one login, as its authenticator key gives it now.
    case verificationCode(itemID: String)
    /// Unlocks the vault with the PIN the user typed into the extension.
    case unlock(pin: String)
    /// Unlocks the vault with Touch ID. The app has the system ask the user; `reason` is what
    /// its question says the app wants to do. The answer comes when the user has answered.
    case unlockWithTouchID(reason: String)
    /// The user has just turned the extension on in the settings of the system: the entries
    /// of the system's store are written again. The answer is the state of the vault.
    case storeIdentities
    /// The passkeys of a relying party; with identifiers, only those the website allows.
    case passkeys(rpID: String, allowedCredentialIDs: [Data])
    /// The signature of a passkey for one login at a website.
    case passkeyAssertion(PasskeyAssertionRequest)
    /// The logins a new passkey of this user at this relying party can be saved to.
    case passkeyTargets(rpID: String, userHandle: Data)
    /// Makes a passkey and saves it to a login, or to a new login.
    case registerPasskey(PasskeyRegistrationRequest)
}

/// How much the website wants the user to be verified for a passkey.
public enum PasskeyUserVerification: String, Sendable, Codable {
    case discouraged, preferred, required
}

public struct PasskeyAssertionRequest: Sendable, Codable, Equatable {
    public var rpID: String
    /// The hash of what the website sent to be signed. The system makes it.
    public var clientDataHash: Data
    /// The passkeys the website allows. Empty allows every passkey of the relying party.
    public var allowedCredentialIDs: [Data]
    /// The login whose passkey the user chose.
    public var itemID: String
    public var userVerification: PasskeyUserVerification
    /// The extension has verified the user for this request: with the PIN of the vault, or
    /// with Touch ID or the password of the Mac.
    public var isUserVerified: Bool

    public init(rpID: String, clientDataHash: Data, allowedCredentialIDs: [Data] = [], itemID: String,
                userVerification: PasskeyUserVerification, isUserVerified: Bool) {
        self.rpID = rpID
        self.clientDataHash = clientDataHash
        self.allowedCredentialIDs = allowedCredentialIDs
        self.itemID = itemID
        self.userVerification = userVerification
        self.isUserVerified = isUserVerified
    }
}

/// What the website gets to check a login with a passkey. No key.
public struct PasskeyAssertion: Sendable, Codable, Equatable {
    public var rpID: String
    public var credentialID: Data
    public var userHandle: Data
    public var authenticatorData: Data
    public var signature: Data

    public init(rpID: String, credentialID: Data, userHandle: Data, authenticatorData: Data, signature: Data) {
        self.rpID = rpID
        self.credentialID = credentialID
        self.userHandle = userHandle
        self.authenticatorData = authenticatorData
        self.signature = signature
    }
}

public struct PasskeyRegistrationRequest: Sendable, Codable, Equatable {
    public var rpID: String
    public var userName: String
    public var userHandle: Data
    public var clientDataHash: Data
    /// The signature algorithms the website takes, as COSE numbers, the preferred one first.
    public var algorithms: [Int]
    /// Passkeys the website says the user has already: with one of them in the vault, no new one is made.
    public var excludedCredentialIDs: [Data]
    public var userVerification: PasskeyUserVerification
    public var isUserVerified: Bool
    /// The login that gets the passkey, in place of one it has. nil makes a new login.
    public var itemID: String?

    public init(rpID: String, userName: String, userHandle: Data, clientDataHash: Data, algorithms: [Int],
                excludedCredentialIDs: [Data] = [], userVerification: PasskeyUserVerification, isUserVerified: Bool,
                itemID: String? = nil) {
        self.rpID = rpID
        self.userName = userName
        self.userHandle = userHandle
        self.clientDataHash = clientDataHash
        self.algorithms = algorithms
        self.excludedCredentialIDs = excludedCredentialIDs
        self.userVerification = userVerification
        self.isUserVerified = isUserVerified
        self.itemID = itemID
    }
}

/// What the website gets to remember a new passkey: its identifier and its public part.
public struct PasskeyRegistration: Sendable, Codable, Equatable {
    public var rpID: String
    public var credentialID: Data
    public var attestationObject: Data

    public init(rpID: String, credentialID: Data, attestationObject: Data) {
        self.rpID = rpID
        self.credentialID = credentialID
        self.attestationObject = attestationObject
    }
}

/// A passkey the extension can list. No secret.
public struct AutoFillPasskey: Sendable, Codable, Equatable, Identifiable {
    public var itemID: String
    public var credentialID: Data
    public var name: String
    public var username: String
    public var asksForMasterPassword: Bool
    public var id: String { itemID + "/" + credentialID.base64EncodedString() }

    public init(itemID: String, credentialID: Data, name: String, username: String, asksForMasterPassword: Bool = false) {
        self.itemID = itemID
        self.credentialID = credentialID
        self.name = name
        self.username = username
        self.asksForMasterPassword = asksForMasterPassword
    }
}

public enum AutoFillResponse: Sendable, Codable, Equatable {
    case status(AutoFillStatus)
    case logins([AutoFillLogin])
    case password(AutoFillPassword)
    /// A verification code. It is good for half a minute and is kept nowhere.
    case verificationCode(String)
    case passkeys([AutoFillPasskey])
    case passkeyAssertion(PasskeyAssertion)
    case passkeyRegistration(PasskeyRegistration)
    case failure(AutoFillFailure)
}

public struct AutoFillStatus: Sendable, Codable, Equatable {
    public enum Vault: String, Sendable, Codable {
        case loggedOut, locked, unlocked
    }

    public var vault: Vault
    /// The account has a PIN that opens the locked vault now.
    public var canUnlockWithPin: Bool
    /// Touch ID opens the locked vault now: it is on for the account, and the Mac can ask.
    public var canUnlockWithTouchID: Bool
    /// The account has "ask for Touch ID on app start": a window that opens on the locked
    /// vault asks at once.
    public var asksForTouchIDAtOnce: Bool
    /// The email of the account, to show whose vault is locked.
    public var account: String?

    public init(vault: Vault, canUnlockWithPin: Bool = false, canUnlockWithTouchID: Bool = false,
                asksForTouchIDAtOnce: Bool = false, account: String? = nil) {
        self.vault = vault
        self.canUnlockWithPin = canUnlockWithPin
        self.canUnlockWithTouchID = canUnlockWithTouchID
        self.asksForTouchIDAtOnce = asksForTouchIDAtOnce
        self.account = account
    }

    /// An app that still runs an older build answers without the newer fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vault = try values.decode(Vault.self, forKey: .vault)
        canUnlockWithPin = try values.decodeIfPresent(Bool.self, forKey: .canUnlockWithPin) ?? false
        canUnlockWithTouchID = try values.decodeIfPresent(Bool.self, forKey: .canUnlockWithTouchID) ?? false
        asksForTouchIDAtOnce = try values.decodeIfPresent(Bool.self, forKey: .asksForTouchIDAtOnce) ?? false
        account = try values.decodeIfPresent(String.self, forKey: .account)
    }
}

/// A login the extension can list. No secret.
public struct AutoFillLogin: Sendable, Codable, Equatable, Identifiable {
    public var itemID: String
    public var name: String
    public var username: String
    /// The item asks for the master password before it gives out its password. The extension
    /// has no master password field, so such a login is filled from the app only.
    public var asksForMasterPassword: Bool
    /// The login has a passkey already: a new one would take its place.
    public var hasPasskey: Bool
    public var id: String { itemID }

    public init(itemID: String, name: String, username: String, asksForMasterPassword: Bool = false, hasPasskey: Bool = false) {
        self.itemID = itemID
        self.name = name
        self.username = username
        self.asksForMasterPassword = asksForMasterPassword
        self.hasPasskey = hasPasskey
    }
}

/// The answer the system fills into a form. It is made for one request and kept nowhere.
public struct AutoFillPassword: Sendable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Never the password: a value like this must not reach a log by an accident of printing.
    public var description: String { "AutoFillPassword" }
    public var debugDescription: String { "AutoFillPassword" }
}

public enum AutoFillFailure: String, Sendable, Codable, Error {
    case loggedOut, locked
    /// No such login, or it has no password to fill.
    case notFound
    /// The login asks for the master password first.
    case masterPasswordRequired
    case wrongPin
    /// The PIN was wrong too often, or cannot open the vault: the app has to unlock.
    case pinUnavailable
    /// Touch ID did not open the vault, and the user did not close its question.
    case touchIDFailed
    /// The vault has one of the passkeys the website excludes: no second one is made.
    case passkeyExists
    /// The website asks for a verified user, and the request says the user was not verified.
    case userNotVerified
    /// The app could not be asked, or could not answer.
    case unavailable
}
