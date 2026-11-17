import BitwardenSdk

// State the SDK asks its host to keep. PassVault keeps it in memory, for one client only,
// so it disappears with the client when the vault locks.

actor SDKMemoryState: StateBridgeForeignImpl {
    private var userKey: SymmetricCryptoKey?
    private var userKeyId: KeyId?
    private var persistentPinEnvelope: PasswordProtectedKeyEnvelope?
    private var ephemeralPinEnvelope: PasswordProtectedKeyEnvelope?
    private var encryptedPin: EncString?
    private var upgradeToken: V2UpgradeToken?
    private var accountState: WrappedAccountCryptographicState?
    private var masterPassword: MasterPasswordUnlockData?
    private var webauthn: WebAuthnPrfUnlockData?
    private var kdf: Kdf?
    private var gracePeriod: V2EncryptedMigrationsGracePeriodStart?

    func setUserKey(value: SymmetricCryptoKey) { userKey = value }
    func getUserKey() -> SymmetricCryptoKey? { userKey }
    func clearUserKey() { userKey = nil }
    func setUserKeyId(value: KeyId) { userKeyId = value }
    func getUserKeyId() -> KeyId? { userKeyId }
    func clearUserKeyId() { userKeyId = nil }
    func setPersistentPinEnvelope(value: PasswordProtectedKeyEnvelope) { persistentPinEnvelope = value }
    func getPersistentPinEnvelope() -> PasswordProtectedKeyEnvelope? { persistentPinEnvelope }
    func clearPersistentPinEnvelope() { persistentPinEnvelope = nil }
    func setEphemeralPinEnvelope(value: PasswordProtectedKeyEnvelope) { ephemeralPinEnvelope = value }
    func getEphemeralPinEnvelope() -> PasswordProtectedKeyEnvelope? { ephemeralPinEnvelope }
    func clearEphemeralPinEnvelope() { ephemeralPinEnvelope = nil }
    func setEncryptedPin(value: EncString) { encryptedPin = value }
    func getEncryptedPin() -> EncString? { encryptedPin }
    func clearEncryptedPin() { encryptedPin = nil }
    func setV2UpgradeToken(value: V2UpgradeToken) { upgradeToken = value }
    func getV2UpgradeToken() -> V2UpgradeToken? { upgradeToken }
    func clearV2UpgradeToken() { upgradeToken = nil }
    func setAccountCryptographicState(value: WrappedAccountCryptographicState) { accountState = value }
    func getAccountCryptographicState() -> WrappedAccountCryptographicState? { accountState }
    func clearAccountCryptographicState() { accountState = nil }
    func setMasterpasswordUnlockData(value: MasterPasswordUnlockData) { masterPassword = value }
    func getMasterpasswordUnlockData() -> MasterPasswordUnlockData? { masterPassword }
    func clearMasterpasswordUnlockData() { masterPassword = nil }
    func setWebauthnPrfUnlockData(value: WebAuthnPrfUnlockData) { webauthn = value }
    func getWebauthnPrfUnlockData() -> WebAuthnPrfUnlockData? { webauthn }
    func clearWebauthnPrfUnlockData() { webauthn = nil }
    func setKdfConfig(value: Kdf) { kdf = value }
    func getKdfConfig() -> Kdf? { kdf }
    func clearKdfConfig() { kdf = nil }
    func setV2EncryptedMigrationsGracePeriodStart(value: V2EncryptedMigrationsGracePeriodStart) { gracePeriod = value }
    func getV2EncryptedMigrationsGracePeriodStart() -> V2EncryptedMigrationsGracePeriodStart? { gracePeriod }
    func clearV2EncryptedMigrationsGracePeriodStart() { gracePeriod = nil }
    func clearAll() {
        userKey = nil; userKeyId = nil; persistentPinEnvelope = nil; ephemeralPinEnvelope = nil
        encryptedPin = nil; upgradeToken = nil; accountState = nil; masterPassword = nil
        webauthn = nil; kdf = nil; gracePeriod = nil
    }
}

actor SDKCipherRepository: CipherRepository {
    private var values: [String: Cipher] = [:]
    func get(id: String) -> Cipher? { values[id] }
    func list() -> [Cipher] { Array(values.values) }
    func set(id: String, value: Cipher) { values[id] = value }
    func setBulk(values: [String: Cipher]) { self.values.merge(values) { _, new in new } }
    func remove(id: String) { values.removeValue(forKey: id) }
    func removeBulk(keys: [String]) { keys.forEach { values.removeValue(forKey: $0) } }
    func removeAll() { values.removeAll() }
    func has(id: String) -> Bool { values[id] != nil }
}

actor SDKLocalKeys: LocalUserDataKeyStateRepository {
    private var values: [String: LocalUserDataKeyState] = [:]
    func get(id: String) -> LocalUserDataKeyState? { values[id] }
    func list() -> [LocalUserDataKeyState] { Array(values.values) }
    func set(id: String, value: LocalUserDataKeyState) { values[id] = value }
    func setBulk(values: [String: LocalUserDataKeyState]) { self.values.merge(values) { _, new in new } }
    func remove(id: String) { values.removeValue(forKey: id) }
    func removeBulk(keys: [String]) { keys.forEach { values.removeValue(forKey: $0) } }
    func removeAll() { values.removeAll() }
    func has(id: String) -> Bool { values[id] != nil }
}

/// The SDK never calls the server for PassVault, so it never gets a token.
final class SDKNoTokens: ClientManagedTokens {
    func getAccessToken() async -> String? { nil }
}

final class SDKDiscardLogs: LogCallback {
    func onLog(level: LogLevel, target: String, message: String) throws {}
}
