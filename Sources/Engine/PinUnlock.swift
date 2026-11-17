import Foundation

/// What clients need to know about unlocking with a PIN.
public struct PinState: Sendable, Codable, Equatable {
    public var isSet: Bool
    /// After a restart of PassVault the PIN works only once the master password was given.
    public var asksForMasterPasswordAfterRestart: Bool
    /// The PIN can open the locked vault now.
    public var canUnlock: Bool

    public static let none = PinState(isSet: false, asksForMasterPasswordAfterRestart: false, canUnlock: false)

    public init(isSet: Bool, asksForMasterPasswordAfterRestart: Bool, canUnlock: Bool) {
        self.isSet = isSet
        self.asksForMasterPasswordAfterRestart = asksForMasterPasswordAfterRestart
        self.canUnlock = canUnlock
    }
}

/// The user key wrapped by a key made from the PIN, and the PIN encrypted by the user key.
/// The SDK makes both.
public struct PinEnrollment: Sendable, Codable, Equatable {
    public var envelope: String
    public var encryptedPin: String

    public init(envelope: String, encryptedPin: String) {
        self.envelope = envelope
        self.encryptedPin = encryptedPin
    }
}

/// What stays on this Mac for a PIN. All of it is secret: a PIN is short, so whoever has the
/// envelope can try every PIN.
public struct StoredPin: Sendable, Codable, Equatable {
    /// nil when the PIN asks for the master password after a restart: the envelope then lives in memory only.
    public var envelope: String?
    /// With it the envelope is made again after an unlock with the master password.
    public var encryptedPin: String
    /// Wrong PINs since the last successful unlock.
    public var failedAttempts: Int

    public init(envelope: String?, encryptedPin: String, failedAttempts: Int = 0) {
        self.envelope = envelope
        self.encryptedPin = encryptedPin
        self.failedAttempts = failedAttempts
    }
}

public struct PinUnlockRequest: Sendable {
    public var userID: String
    public var email: String
    public var material: AccountCryptoMaterial
    public var pin: String
    public var envelope: String

    public init(userID: String, email: String, material: AccountCryptoMaterial, pin: String, envelope: String) {
        self.userID = userID
        self.email = email
        self.material = material
        self.pin = pin
        self.envelope = envelope
    }
}
