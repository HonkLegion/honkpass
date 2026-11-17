import Foundation

/// What clients need to know about unlocking with Touch ID.
public struct BiometricState: Sendable, Codable, Equatable {
    /// The Mac can ask for Touch ID now: it has a sensor in reach and a finger is set. A sensor
    /// comes and goes with a keyboard and with the lid of the Mac.
    public var isAvailable: Bool
    /// The unlock with Touch ID is on for the account: the key that opens its vault is kept
    /// in the Keychain of the system.
    public var isEnabled: Bool

    /// Touch ID can open the locked vault now.
    public var canUnlock: Bool { isAvailable && isEnabled }

    public static let none = BiometricState(isAvailable: false, isEnabled: false)

    public init(isAvailable: Bool, isEnabled: Bool) {
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
    }
}

/// Why Touch ID did not open the vault, or could not be turned on. Nothing was unlocked.
public enum BiometricFailure: Sendable, Codable, Equatable {
    /// The Mac cannot ask for Touch ID now.
    case unavailable
    /// The unlock with Touch ID is not on for the account: no key is kept.
    case notEnabled
    /// The user closed the question of the system.
    case cancelled
    /// The system did not give the key, or did not keep it.
    case failed
    /// The key that was kept no longer opens the account, as after a change of its keys on
    /// another device. The engine has removed it.
    case keyRejected
}

/// The key that opens the vault of an account, kept by the system behind Touch ID. The engine
/// hands the key over and gets it back; it never shows it to a client. An implementation
/// stores it where only the system releases it, and only to this app.
public protocol BiometricKeysPort: Sendable {
    /// Whether the system can ask for Touch ID now.
    func isAvailable() async -> Bool
    /// Whether a key of the account is kept. It asks the user nothing.
    func hasKey(accountID: String) async -> Bool
    /// Keeps the key of an account, in place of one that is kept already.
    func keep(_ userKey: String, accountID: String) async throws
    /// Has the system ask the user, and gives the key. `reason` is what the question of the
    /// system says the app wants to do. Throws `EngineError.biometrics`.
    func key(accountID: String, reason: String) async throws -> String
    /// Removes the key of an account. No key to remove is no error.
    func remove(accountID: String) async throws
}

/// A Mac without Touch ID: for the tests of the adapters.
public struct NoBiometricKeys: BiometricKeysPort {
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func hasKey(accountID: String) async -> Bool { false }
    public func keep(_ userKey: String, accountID: String) async throws { throw EngineError.biometrics(.unavailable) }
    public func key(accountID: String, reason: String) async throws -> String { throw EngineError.biometrics(.notEnabled) }
    public func remove(accountID: String) async throws {}
}

/// An unlock with the user key itself, as the Keychain gave it back.
public struct KeyUnlockRequest: Sendable {
    public var userID: String
    public var email: String
    public var material: AccountCryptoMaterial
    public var userKey: String

    public init(userID: String, email: String, material: AccountCryptoMaterial, userKey: String) {
        self.userID = userID
        self.email = email
        self.material = material
        self.userKey = userKey
    }
}
