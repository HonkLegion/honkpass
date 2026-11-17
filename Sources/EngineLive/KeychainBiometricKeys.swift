import Engine
import Foundation
import LocalAuthentication
import os
import Security

/// The key that opens a vault, in the data protection Keychain behind an access control of the
/// system: Touch ID with the fingers that are set now, or the password of the Mac. The system
/// asks the user when the item is read, and gives it to this app only; PassVault has no other
/// way to it. The item stays on this Mac and is never synchronised.
/// Source: `QuickUnlockStoreAdapter` of HonkPass.
public struct KeychainBiometricKeys: BiometricKeysPort {
    private let service: String

    /// The numbers of the errors of the system, never a key.
    private static let log = Logger(subsystem: "PassVault", category: "biometrics")

    /// PassVault shares its bundle identifier with HonkPass, so it has its own service name.
    public init(service: String = "PassVault.biometric-unlock") {
        self.service = service
    }

    private func query(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func isAvailable() async -> Bool {
        var failure: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &failure) { return true }
        // After too many wrong fingers the sensor is there, and the question of the system
        // takes the password of the Mac.
        return (failure as? LAError)?.code == .biometryLockout
    }

    public func hasKey(accountID: String) async -> Bool {
        // With a context that may ask nothing, an item that is there answers "would have to ask".
        let silent = LAContext()
        silent.interactionNotAllowed = true
        var query = query(accountID)
        query[kSecUseAuthenticationContext as String] = silent
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func keep(_ userKey: String, accountID: String) async throws {
        var failure: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.biometryCurrentSet, .or, .devicePasscode], &failure) else {
            _ = failure?.takeRetainedValue()
            Self.log.error("keep: the access control could not be made")
            throw EngineError.biometrics(.failed)
        }
        // A key that is kept goes first. A new one that cannot be kept is reported, and the
        // unlock with Touch ID is then off: never an old key in place of the new one.
        try await remove(accountID: accountID)
        var query = query(accountID)
        query[kSecValueData as String] = Data(userKey.utf8)
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("keep: the Keychain did not take the item, status \(status)")
            throw EngineError.biometrics(.failed)
        }
        Self.log.notice("keep: the key of an account is kept behind Touch ID")
    }

    public func key(accountID: String, reason: String) async throws -> String {
        let service = service
        return try await withCheckedThrowingContinuation { continuation in
            // The system asks the user here, and the call waits for the answer: on a thread of its own.
            Thread.detachNewThread {
                let context = LAContext()
                context.localizedReason = reason
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: accountID,
                    kSecUseDataProtectionKeychain as String: true,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context,
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    if let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
                        continuation.resume(returning: key)
                    } else {
                        Self.log.error("key: the item of the Keychain is not readable")
                        continuation.resume(throwing: EngineError.biometrics(.failed))
                    }
                case errSecUserCanceled:
                    continuation.resume(throwing: EngineError.biometrics(.cancelled))
                case errSecItemNotFound:
                    continuation.resume(throwing: EngineError.biometrics(.notEnabled))
                default:
                    Self.log.error("key: the Keychain did not give the item, status \(status)")
                    continuation.resume(throwing: EngineError.biometrics(.failed))
                }
            }
        }
    }

    public func remove(accountID: String) async throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.log.error("remove: the Keychain did not remove the item, status \(status)")
            throw EngineError.biometrics(.failed)
        }
    }
}
