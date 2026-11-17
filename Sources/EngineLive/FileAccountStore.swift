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
/// - `settings.json`: the settings of each account that was logged in here. They survive logout.
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
        guard let file: AccountFile = try read("account.json") else { return nil }
        // Without tokens the vault still opens from the stored copy; only the server needs them.
        let tokens = try secrets.read(Self.tokensKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        let payload = try? Data(contentsOf: directory.appending(path: "vault.json"))
        return StoredAccount(account: file.account, crypto: file.crypto, accessToken: tokens?.accessToken ?? "",
                             refreshToken: tokens?.refreshToken, accessTokenExpiry: file.accessTokenExpiry,
                             vaultPayload: payload, lastSync: file.lastSync)
    }

    public func save(_ account: StoredAccount) async throws {
        do {
            try secrets.write(JSONEncoder().encode(Tokens(accessToken: account.accessToken, refreshToken: account.refreshToken)),
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

    public func clear() async throws {
        for name in ["account.json", "vault.json", "generator-history.json"] {
            let file = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) } catch {
                    throw EngineError.storage("The stored account could not be removed.")
                }
            }
        }
        do { try secrets.delete(Self.tokensKey) } catch {
            throw EngineError.storage("The session could not be removed from the Keychain.")
        }
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
            let parked = (try? place.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            accounts.append((account, parked))
        }
        // The sort keeps the order of the names where two dates are the same.
        return accounts.sorted { $0.parked > $1.parked }.map(\.account)
    }

    public func park() async throws {
        guard let file: AccountFile = try read("account.json") else { return }
        let folder = try parkedFolder(file.account.id)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The tokens first: an account without its files is found by nobody.
            if let tokens = try secrets.read(Self.tokensKey) {
                try secrets.write(tokens, key: Self.tokensKey(of: file.account.id))
                try secrets.delete(Self.tokensKey)
            }
            // The file that names the account goes last, so that a move that breaks off leaves the account stored.
            for name in Self.accountFiles.reversed() {
                let source = directory.appending(path: name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: folder.appending(path: name))
                }
            }
        } catch {
            throw EngineError.storage("The account could not be put aside.")
        }
    }

    public func unpark(accountID: String) async throws {
        let folder = try parkedFolder(accountID)
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "account.json").path),
              FileManager.default.fileExists(atPath: folder.appending(path: "account.json").path) else {
            throw EngineError.storage("The account that was put aside is not there.")
        }
        do {
            if let tokens = try secrets.read(Self.tokensKey(of: accountID)) {
                try secrets.write(tokens, key: Self.tokensKey)
                try secrets.delete(Self.tokensKey(of: accountID))
            }
            for name in Self.accountFiles.reversed() {
                let source = folder.appending(path: name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: directory.appending(path: name))
                }
            }
            try? FileManager.default.removeItem(at: folder)
        } catch {
            throw EngineError.storage("The account that was put aside could not be taken back.")
        }
    }

    public func removeParked(accountID: String) async throws {
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
        let all: [String: EngineSettings]? = try read("settings.json")
        return all?[accountID]
    }

    public func saveSettings(_ settings: EngineSettings, accountID: String) async throws {
        // An unreadable file is replaced; the settings of this account are what the user just chose.
        var all: [String: EngineSettings] = (try? read("settings.json")) ?? [:]
        all[accountID] = settings
        try write(all, to: "settings.json")
    }

    public func loadPin(accountID: String) async throws -> StoredPin? {
        try pins()[accountID]
    }

    public func savePin(_ pin: StoredPin?, accountID: String) async throws {
        // Unreadable PINs are replaced: the user then unlocks with the master password.
        var all = (try? pins()) ?? [:]
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
        try delete(key)
        var query = query(key)
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
