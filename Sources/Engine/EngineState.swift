import Foundation
import VaultModel

/// Everything a client needs to draw itself. Every client gets the same values.
public struct EngineState: Sendable, Codable, Equatable {
    public var session: SessionState
    /// Empty unless the session is unlocked. Locking removes the data from every client at once.
    public var vault: VaultContents
    /// The command in progress, if any.
    public var activity: EngineActivity?
    /// Installation holds the session locked until the updater finishes or the process exits.
    public var isPreparingAppUpdate = false
    /// The actual authentication stage. No estimated percentages or vault data.
    public var authenticationPhase: AuthenticationPhase?
    /// The settings of the logged-in account; the defaults while nobody is logged in.
    public var settings: EngineSettings
    /// A log-in with the right master password waits for its second step. Clients show the
    /// two-step screen while this is set and send the code, or cancel.
    public var twoStep: TwoStepChallenge?
    /// Unlock with a PIN for the logged-in account.
    public var pin: PinState
    /// Unlock with Touch ID for the logged-in account.
    public var biometrics: BiometricState
    /// What the engine did or found by itself and the user has to be told. A client that has
    /// shown a notice dismisses it.
    public var notices: [EngineNotice]
    /// The other accounts that are logged in on this Mac. Only the account of `session` can
    /// be unlocked; these wait, locked, until the user switches to one of them. The one that
    /// was in use last comes first.
    public var otherAccounts: [Account]
    /// An SSH client waits for the user to allow the use of a key. Clients show the question
    /// while this is set and send the answer.
    public var sshApproval: SSHApproval?
    public var sshUnlockRequest: SSHUnlockRequest?
    public var sshPendingRequestCount: Int?
    /// A file that is being added to an item: from the start of the command until its end,
    /// also while the file is encrypted and the vault is fetched again after it.
    public var upload: AttachmentUpload?
    /// The name of the account of `session`, as its access token says it. nil when the token
    /// names none: clients show the address in its place, as the reference does.
    public var accountName: String?

    public var lockPolicy: LockPolicy { settings.lockPolicy }

    public static let initial = EngineState(session: .loggedOut, vault: .empty, activity: .starting, settings: .default)

    public init(session: SessionState, vault: VaultContents, activity: EngineActivity?, settings: EngineSettings,
                twoStep: TwoStepChallenge? = nil, pin: PinState = .none, notices: [EngineNotice] = [],
                sshApproval: SSHApproval? = nil, otherAccounts: [Account] = [], biometrics: BiometricState = .none) {
        self.otherAccounts = otherAccounts
        self.biometrics = biometrics
        self.sshApproval = sshApproval
        self.session = session
        self.vault = vault
        self.activity = activity
        self.settings = settings
        self.twoStep = twoStep
        self.pin = pin
        self.notices = notices
    }
}

/// A file on its way to the server: the item it is added to, and the per cent of the request
/// that has gone, rounded as the reference rounds it (`Math.round(loaded / total * 100)`).
public struct AttachmentUpload: Sendable, Codable, Equatable {
    public var itemID: String
    public var percent: Int

    public init(itemID: String, percent: Int) {
        self.itemID = itemID
        self.percent = percent
    }
}

/// Something that happened without a command of the user.
public enum EngineNotice: String, Sendable, Codable, Equatable {
    /// The server ended the session; the account was logged out.
    case sessionExpired
    /// The stored account could not be read. The engine starts logged out and leaves the files alone.
    case storedAccountUnreadable
    /// The stored settings or the stored PIN could not be read. The defaults are in force and
    /// the PIN is off until it is set again.
    case storedSettingsUnreadable
    /// The place for the account on this Mac could not be opened. The account is kept in memory
    /// only and a restart forgets the log-in.
    case storeUnavailable
    /// An SSH client asked for a signature while the vault is locked. It waits for the unlock.
    case sshAgentUnlockRequired
    /// The vault stayed locked too long; the SSH client was refused.
    case sshAgentUnlockTimedOut
    /// The socket of the SSH agent could not be made. The agent does not run.
    case sshAgentUnavailable
}

public enum SessionState: Sendable, Codable, Equatable {
    case loggedOut
    /// An account is logged in, but its keys and decrypted data are not in memory.
    case locked(Account)
    case unlocked(Account)

    public var account: Account? {
        switch self {
        case .loggedOut: nil
        case .locked(let account), .unlocked(let account): account
        }
    }

    public var isUnlocked: Bool {
        if case .unlocked = self { true } else { false }
    }
}

public enum EngineActivity: String, Sendable, Codable {
    case starting, loggingIn, loadingVault, unlocking, syncing
    /// A change is being sent to the server.
    case saving
}

public enum AuthenticationPhase: String, Sendable, Codable {
    case authenticating, syncing, loadingVault, preparingPin, saving
}

/// Why a text could not be taken as an SSH key.
public enum SSHKeyImportFailure: String, Sendable, Codable, Equatable {
    /// The text is no private key.
    case notAKey
    /// A key of a kind that is not taken.
    case unsupportedKind
    /// The key is encrypted and needs its password.
    case passwordRequired
    case wrongPassword
}

/// Why a fill did not happen. In every case nothing was written.
public enum FillFailure: Sendable, Codable, Equatable {
    /// The system does not let PassVault use the fields of other apps.
    case notAllowed
    /// The app in front has no field with the cursor that takes a text.
    case noField
    /// The cursor is no longer in the field that was captured: another field, window or app.
    case targetChanged
    /// The app did not take the value.
    case refused
}

/// The only error type engine commands throw.
public enum EngineError: Error, Sendable, Codable, Equatable {
    /// The vault has a passkey that the website excludes: no second one is made.
    case passkeyExists
    /// Another command is in progress.
    case busy
    /// A lock or logout interrupted the command.
    case cancelled
    /// The command does not apply to the current session state.
    case invalidState
    /// The item, or the field of the item, does not exist.
    case notFound
    /// The item, or a part of it, did not decrypt. Nothing of it is shown, so that no client
    /// takes a part for the whole.
    case itemNotReadable
    /// The item cannot be written back whole: a part of it did not decrypt, it is not the
    /// user's to change, or the SDK could not be seen to decrypt strictly. Nothing was sent.
    case itemNotWritable
    /// The item has changed since the form was opened, here or on another device. Nothing was
    /// changed; the vault shows the newer item.
    case itemChanged
    /// The file is empty or larger than an attachment may be. Nothing was sent.
    case attachmentTooLarge
    /// The text is not an SSH key that can be taken as it is.
    case sshKeyImport(SSHKeyImportFailure)
    /// A value could not be put into the field of the app in front.
    case fill(FillFailure)
    /// The app cannot be tied to a login: it is no app, no developer signed it, or it is a
    /// browser, whose pages decide where a login belongs.
    case appNotAccepted
    case invalidCredentials
    case wrongMasterPassword
    case wrongPin
    /// The PIN was wrong too often. The engine has logged the account out.
    case tooManyPinAttempts
    /// Touch ID did not open the vault, or could not be turned on.
    case biometrics(BiometricFailure)
    /// The log-in waits for its second step: `EngineState.twoStep` says how it can be given.
    case twoStepLoginRequired
    /// The account has two-step login, but only with methods PassVault cannot use.
    case twoStepMethodsUnsupported
    /// The server did not accept the code of the second step.
    case invalidTwoStepCode
    /// The server ended the session. The engine has logged the account out.
    case sessionExpired
    case serverUnreachable
    /// The server refused the request or answered in an unexpected way. The text holds no secret.
    case server(String)
    case storage(String)
    case unexpected(String)

    /// Ports throw `EngineError`. Anything else is reported by its type only, never by its content.
    init(_ error: any Error) {
        self = (error as? EngineError) ?? .unexpected(String(reflecting: type(of: error)))
    }
}
