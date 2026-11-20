import Engine
import Foundation
import Security
import VaultModel

/// Where the session tokens live. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}

/// The logged-in account on this Mac.
///
/// - `account.json`: who is logged in and the wrapped account keys. Useless without the master password.
/// - `vault.json`: the last sync answer of the server, encrypted as the server sent it.
/// - `generator-history.json`: what the generator has made, each value encrypted by the SDK
///   under the keys of the account. It goes with the account at a logout.
/// - `device.json`: the identifier of this installation. It survives logout.
/// - `settings.json`: old preferences, consulted only for migration. New settings live in the Keychain.
/// - `parked/<account>/`: the first three files of each other account that is logged in here
///   and waits for the user to switch to it; its tokens are in the secret store under its name.
/// - The access and refresh tokens are in the secret store, never in a file. So are the tokens
///   of "remember me" for two-step login, which survive logout, and the PIN of an account:
///   its envelope opens the vault for whoever tries every short PIN.
///
/// Nothing decrypted is ever written. Files are readable by the user only.
public actor FileAccountStore: AccountStorePort {
    private let directory: URL
    private let secrets: any SecretStore
    private static let tokensKey = "session-tokens"
    private static let rememberKey = "two-step-remember"
    private static let pinKey = "pin"

    private struct AccountFile: Codable {
        var account: Account
        var crypto: AccountCryptoMaterial
        var accessTokenExpiry: Date
        var lastSync: Date?
    }

    private struct Tokens: Codable {
        var account: Account?
        var accessToken: String
        var refreshToken: String?
    }

    public init(directory: URL, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    /// The store of the app: Application Support/PassVault and the Keychain.
    public static func applicationStore() throws -> FileAccountStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return FileAccountStore(directory: support.appending(path: "PassVault", directoryHint: .isDirectory),
                                secrets: KeychainSecretStore())
    }

    public func deviceIdentifier() async throws -> String {
        struct Device: Codable { var identifier: String }
        if let device: Device = try read("device.json") { return device.identifier }
        let device = Device(identifier: UUID().uuidString.lowercased())
        try write(device, to: "device.json")
        return device.identifier
    }

    public func load() async throws -> StoredAccount? {
        try resumeMove()
        guard let file: AccountFile = try read("account.json") else { return nil }
        // Without tokens the vault still opens from the stored copy; only the server needs them.
        let tokens = try tokens(for: file.account, key: Self.tokensKey)
        let payload = try? Data(contentsOf: directory.appending(path: "vault.json"))
        return StoredAccount(account: file.account, crypto: file.crypto, accessToken: tokens?.accessToken ?? "",
                             refreshToken: tokens?.refreshToken, accessTokenExpiry: file.accessTokenExpiry,
                             vaultPayload: payload, lastSync: file.lastSync)
    }

    // A legacy token already in the Keychain can identify its issuer and subject.
    // Never infer its destination from the editable account file alone.
    private func tokens(for account: Account, key: String) throws -> Tokens? {
        if let owner = try secrets.read("account-owner." + account.id.lowercased()),
           try JSONDecoder().decode(URL.self, from: owner) != account.serverURL {
            throw EngineError.storage("The stored account does not match its server.")
        }
        guard let data = try secrets.read(key) else { return nil }
        var session = try JSONDecoder().decode(Tokens.self, from: data)
        if let bound = session.account {
            guard bound == account else { throw EngineError.storage("The stored account does not match its session.") }
            return session
        }
        guard TokenResponse.legacySession(session.accessToken, belongsTo: account) else { return nil }
        try bindOwner(account)
        session.account = account
        try secrets.write(JSONEncoder().encode(session), key: key)
        return session
    }

    // PINs, biometric keys and persistent preferences use the original account ID.
    // A verified sign-in reserves this namespace until logout cleanup completes.
    private func bindOwner(_ account: Account) throws {
        let key = "account-owner." + account.id.lowercased()
        if let existing = try secrets.read(key) {
            guard try JSONDecoder().decode(URL.self, from: existing) == account.serverURL else {
                throw EngineError.storage("This account identifier belongs to another server.")
            }
        } else {
            try secrets.write(JSONEncoder().encode(account.serverURL), key: key)
        }
    }

    public func save(_ account: StoredAccount) async throws {
        try resumeMove()
        try bindOwner(account.account)
        do {
            try secrets.write(JSONEncoder().encode(Tokens(account: account.account, accessToken: account.accessToken, refreshToken: account.refreshToken)),
                              key: Self.tokensKey)
        } catch {
            throw EngineError.storage("The session could not be saved to the Keychain.")
        }
        if let payload = account.vaultPayload {
            try writeData(payload, to: "vault.json")
        } else {
            try? FileManager.default.removeItem(at: directory.appending(path: "vault.json"))
        }
        try write(AccountFile(account: account.account, crypto: account.crypto,
                              accessTokenExpiry: account.accessTokenExpiry, lastSync: account.lastSync), to: "account.json")
    }

    public func pendingLogout() async throws -> String? {
        try secrets.read("pending-logout").map { try JSONDecoder().decode(String.self, from: $0) }
    }

    public func setPendingLogout(_ accountID: String?) async throws {
        if let accountID {
            try secrets.write(JSONEncoder().encode(accountID), key: "pending-logout")
        } else if let id = try await pendingLogout() {
            let key = "account-owner." + id.lowercased()
            // Once quick unlock was revoked, a future verified login can claim this ID again.
            // Keep preferences for this exact server without reserving the ID forever.
            if let data = try secrets.read(key) {
                let server = try JSONDecoder().decode(URL.self, from: data)
                let settingsKey = "settings." + id.lowercased()
                if let settings = try secrets.read(settingsKey) {
                    try secrets.write(settings, key: settingsKey + "|" + server.absoluteString)
                    try secrets.delete(settingsKey)
                }
                try secrets.delete(key)
            }
            try secrets.delete("pending-logout")
        }
    }

    public func clear() async throws {
        try resumeMove()
        var failure: EngineError?
        do { try secrets.delete(Self.tokensKey) } catch { failure = .storage("The session could not be removed from the Keychain.") }
        for name in ["account.json", "vault.json", "generator-history.json"] {
            let file = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) } catch {
                    failure = .storage("The stored account could not be removed.")
                }
            }
        }
        if let failure { throw failure }
    }

    // MARK: Accounts that wait beside the stored one

    /// The files of an account, which go with it when it is put aside.
    private static let accountFiles = ["account.json", "vault.json", "generator-history.json"]

    /// The folder of an account that was put aside: "parked/<identifier>". The identifier
    /// becomes a part of a path, so only one of the form the server gives is taken.
    private func parkedFolder(_ accountID: String) throws -> URL {
        guard UUID(uuidString: accountID) != nil else { throw EngineError.storage("The account has no usable identifier.") }
        return directory.appending(path: "parked", directoryHint: .isDirectory)
            .appending(path: accountID.lowercased(), directoryHint: .isDirectory)
    }

    private static func tokensKey(of accountID: String) -> String { tokensKey + "." + accountID.lowercased() }

    public func parkedAccounts() async throws -> [Account] {
        try resumeMove()
        let folder = directory.appending(path: "parked", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // The folder of an account is made anew each time the account is put aside, so its
        // date of creation says when the account was in use last.
        var accounts: [(account: Account, parked: Date)] = []
        for name in names.sorted() where UUID(uuidString: name) != nil {
            let place = folder.appending(path: name, directoryHint: .isDirectory)
            let file = place.appending(path: "account.json")
            guard let data = try? Data(contentsOf: file), let account = try? decoder.decode(AccountFile.self, from: data).account,
                  account.id.lowercased() == name else { continue }
            // A mismatched file must not impersonate or replace another parked account.
            do { _ = try tokens(for: account, key: Self.tokensKey(of: account.id)) } catch { continue }
            let parked = (try? place.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            accounts.append((account, parked))
        }
        // The sort keeps the order of the names where two dates are the same.
        return accounts.sorted { $0.parked > $1.parked }.map(\.account)
    }

    private struct AccountMove: Codable {
        let id: String
        let parking: Bool
    }

    // A Keychain journal makes moving the files and their separately stored tokens
    // resumable. A restart completes the same move before either location is read.
    private func resumeMove() throws {
        guard let data = try secrets.read("account-move") else { return }
        let move = try JSONDecoder().decode(AccountMove.self, from: data)
        let folder = try parkedFolder(move.id)
        let source = move.parking ? directory : folder
        let destination = move.parking ? folder : directory
        let fromKey = move.parking ? Self.tokensKey : Self.tokensKey(of: move.id)
        let toKey = move.parking ? Self.tokensKey(of: move.id) : Self.tokensKey
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let tokens = try secrets.read(fromKey) {
            try secrets.write(tokens, key: toKey)
            try secrets.delete(fromKey)
        }
        for name in Self.accountFiles.reversed() {
            let file = source.appending(path: name)
            if manager.fileExists(atPath: file.path) {
                try manager.moveItem(at: file, to: destination.appending(path: name))
            }
        }
        if !move.parking, manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
        try secrets.delete("account-move")
    }

    public func park() async throws {
        try resumeMove()
        guard let file: AccountFile = try read("account.json") else { return }
        _ = try tokens(for: file.account, key: Self.tokensKey)
        let folder = try parkedFolder(file.account.id)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw EngineError.storage("A parked account already uses this identifier.")
        }
        try secrets.write(JSONEncoder().encode(AccountMove(id: file.account.id, parking: true)), key: "account-move")
        try resumeMove()
    }

    public func unpark(accountID: String) async throws {
        try resumeMove()
        let folder = try parkedFolder(accountID)
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "account.json").path),
              FileManager.default.fileExists(atPath: folder.appending(path: "account.json").path) else {
            throw EngineError.storage("The account that was put aside is not there.")
        }
        let data = try Data(contentsOf: folder.appending(path: "account.json"))
        let file = try decoder.decode(AccountFile.self, from: data)
        guard file.account.id.caseInsensitiveCompare(accountID) == .orderedSame else { throw EngineError.invalidState }
        _ = try tokens(for: file.account, key: Self.tokensKey(of: accountID))
        try secrets.write(JSONEncoder().encode(AccountMove(id: accountID, parking: false)), key: "account-move")
        try resumeMove()
    }

    public func removeParked(accountID: String) async throws {
        try resumeMove()
        let folder = try parkedFolder(accountID)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try secrets.delete(Self.tokensKey(of: accountID))
        } catch {
            throw EngineError.storage("The account that was put aside could not be removed.")
        }
    }

    public func loadGeneratorHistory() async throws -> [Data] {
        try read("generator-history.json") ?? []
    }

    public func saveGeneratorHistory(_ entries: [Data]) async throws {
        try write(entries, to: "generator-history.json")
    }

    public func loadSettings(accountID: String) async throws -> EngineSettings? {
        let key = "settings." + accountID.lowercased()
        if let data = try secrets.read(key) { return try JSONDecoder().decode(EngineSettings.self, from: data) }
        if let owner = try secrets.read("account-owner." + accountID.lowercased()) {
            let server = try JSONDecoder().decode(URL.self, from: owner)
            if let data = try secrets.read(key + "|" + server.absoluteString) { return try JSONDecoder().decode(EngineSettings.self, from: data) }
        }
        let all: [String: EngineSettings]? = try read("settings.json")
        guard var legacy = all?[accountID] else { return nil }
        // These choices formerly had no trusted copy. Start SSH disabled and require
        // the user to choose the security preferences again in Settings.
        legacy.sshAgent = .default
        switch legacy.lockPolicy.timeout {
        case .onRestart, .never: legacy.lockPolicy.timeout = .onSystemLock
        case .afterInactivity(let minutes): legacy.lockPolicy.timeout = .afterInactivity(minutes: min(max(minutes, 1), 60))
        case .onSystemIdle, .onSleep, .onSystemLock: break
        }
        legacy.lockPolicy.action = .lock
        if case .after(let seconds) = legacy.clipboardClearing {
            legacy.clipboardClearing = .after(seconds: min(max(seconds, 1), 300))
        } else {
            legacy.clipboardClearing = EngineSettings.default.clipboardClearing
        }
        legacy.asksForBiometricsOnStart = false
        try secrets.write(JSONEncoder().encode(legacy), key: key)
        return legacy
    }

    public func saveSettings(_ settings: EngineSettings, accountID: String) async throws {
        try secrets.write(JSONEncoder().encode(settings), key: "settings." + accountID.lowercased())
    }

    public func loadPin(accountID: String) async throws -> StoredPin? {
        try pins()[accountID]
    }

    public func savePin(_ pin: StoredPin?, accountID: String) async throws {
        // Preserve other accounts when reading the protected map fails.
        var all = try pins()
        all[accountID] = pin
        do {
            if all.isEmpty {
                try secrets.delete(Self.pinKey)
            } else {
                try secrets.write(JSONEncoder().encode(all), key: Self.pinKey)
            }
        } catch {
            throw EngineError.storage("The PIN could not be saved to the Keychain.")
        }
    }

    private func pins() throws -> [String: StoredPin] {
        do {
            guard let data = try secrets.read(Self.pinKey) else { return [:] }
            return try JSONDecoder().decode([String: StoredPin].self, from: data)
        } catch {
            throw EngineError.storage("The PIN could not be read from the Keychain.")
        }
    }

    public func twoStepRememberToken(server: URL, email: String) async throws -> String? {
        try rememberTokens()[Self.rememberName(server, email)]
    }

    public func saveTwoStepRememberToken(_ token: String?, server: URL, email: String) async throws {
        // Unreadable tokens are replaced: the user is then asked for the second step again.
        var tokens = (try? rememberTokens()) ?? [:]
        tokens[Self.rememberName(server, email)] = token
        do {
            if tokens.isEmpty {
                try secrets.delete(Self.rememberKey)
            } else {
                try secrets.write(JSONEncoder().encode(tokens), key: Self.rememberKey)
            }
        } catch {
            throw EngineError.storage("The remembered device could not be saved to the Keychain.")
        }
    }

    private func rememberTokens() throws -> [String: String] {
        do {
            guard let data = try secrets.read(Self.rememberKey) else { return [:] }
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw EngineError.storage("The remembered device could not be read from the Keychain.")
        }
    }

    private static func rememberName(_ server: URL, _ email: String) -> String {
        server.absoluteString + "|" + email.lowercased()
    }

    // MARK: Files

    private func read<Value: Decodable>(_ name: String) throws -> Value? {
        let file = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: file))
        } catch {
            throw EngineError.storage("The stored file \(name) is not readable.")
        }
    }

    private func write(_ value: some Encodable, to name: String) throws {
        guard let data = try? encoder.encode(value) else { throw EngineError.storage("The file \(name) could not be written.") }
        try writeData(data, to: name)
    }

    private func writeData(_ data: Data, to name: String) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appending(path: name)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw EngineError.storage("The file \(name) could not be written.")
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Generic password items in the data protection Keychain: this device only, readable after
/// the first unlock of the Mac, never synchronised.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    /// PassVault shares its bundle identifier with HonkPass, so it has its own service name.
    public init(service: String = "PassVault.session") {
        self.service = service
    }

    private struct Failure: Error {
        let status: OSStatus
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    public func write(_ data: Data, key: String) throws {
        let identity = query(key)
        let changes = [kSecValueData as String: data]
        let update = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var query = identity
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
