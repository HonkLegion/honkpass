import Engine
import EngineLive
import Foundation
import Synchronization
import Testing
import VaultModel

/// Secrets in memory, in place of the Keychain.
final class MemorySecretStore: SecretStore, Sendable {
    private let values = Mutex<[String: Data]>([:])
    func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
    func write(_ data: Data, key: String) throws { values.withLock { $0[key] = data } }
    func delete(_ key: String) throws { values.withLock { $0[key] = nil } }
    var isEmpty: Bool { values.withLock { $0.isEmpty } }
}

@Suite struct FileAccountStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "passvault-store-\(UUID().uuidString)")
    let secrets = MemorySecretStore()

    private var record: StoredAccount {
        StoredAccount(
            account: Account(id: "11111111-2222-4333-8444-555555555555", email: "test.user@passvault.test",
                             serverURL: URL(string: "http://localhost:8642")!),
            crypto: AccountCryptoMaterial(kdf: .pbkdf2(iterations: 600_000), salt: "test.user@passvault.test",
                                          masterKeyWrappedUserKey: "2.wrapped", keys: .v1(privateKey: "2.private")),
            accessToken: "synthetic-access-token", refreshToken: "synthetic-refresh-token",
            accessTokenExpiry: Date(timeIntervalSince1970: 1_800_003_600),
            vaultPayload: Data(#"{"ciphers":[]}"#.utf8), lastSync: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aSavedAccountIsLoadedByANewStore() async throws {
        try await FileAccountStore(directory: directory, secrets: secrets).save(record)
        let loaded = try await FileAccountStore(directory: directory, secrets: secrets).load()
        #expect(loaded == record)
    }

    @Test func anAccountIsPutAsideWithAllThatBelongsToItAndTakenBack() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        try await store.save(record)
        try await store.saveGeneratorHistory([Data("synthetic-entry".utf8)])
        var other = record
        other.account = Account(id: "22222222-2222-4333-8444-555555555555", email: "other.user@passvault.test",
                                serverURL: URL(string: "http://localhost:8642")!)
        other.accessToken = "other-access-token"
        other.vaultPayload = Data(#"{"ciphers":["other"]}"#.utf8)

        // Aside: no account is stored, and a new store finds the one that waits.
        try await store.park()
        #expect(try await store.load() == nil)
        #expect(try await store.loadGeneratorHistory().isEmpty)
        #expect(try await FileAccountStore(directory: directory, secrets: secrets).parkedAccounts() == [record.account])
        // Its tokens stay out of the files.
        let parked = directory.appending(path: "parked").appending(path: record.account.id)
        for name in try FileManager.default.contentsOfDirectory(atPath: parked.path) {
            #expect(!String(decoding: try Data(contentsOf: parked.appending(path: name)), as: UTF8.self).contains("synthetic-access-token"))
        }

        // Another account beside it, then the two change places.
        try await store.save(other)
        #expect(try await store.load() == other)
        await #expect(throws: EngineError.self) { try await store.unpark(accountID: record.account.id) }
        try await store.park()
        // The one that was put aside last comes first.
        #expect(try await store.parkedAccounts().map(\.email) == [other.account.email, record.account.email])
        try await store.unpark(accountID: record.account.id)
        #expect(try await store.load() == record)
        #expect(try await store.loadGeneratorHistory() == [Data("synthetic-entry".utf8)])
        #expect(try await store.parkedAccounts() == [other.account])

        // Removed for good, with its tokens; an identifier that is no identifier names no folder.
        try await store.removeParked(accountID: other.account.id)
        #expect(try await store.parkedAccounts().isEmpty)
        try await store.clear()
        #expect(secrets.isEmpty)
        await #expect(throws: EngineError.self) { try await store.unpark(accountID: "../outside") }
    }

    @Test func theHistoryOfTheGeneratorIsKeptWithTheAccountAndGoesWithIt() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        try await store.save(record)
        #expect(try await store.loadGeneratorHistory().isEmpty)
        let entries = [Data("synthetic-encrypted-entry-2".utf8), Data("synthetic-encrypted-entry-1".utf8)]
        try await store.saveGeneratorHistory(entries)

        #expect(try await FileAccountStore(directory: directory, secrets: secrets).loadGeneratorHistory() == entries)

        try await store.clear()
        #expect(try await FileAccountStore(directory: directory, secrets: secrets).loadGeneratorHistory().isEmpty)
    }

    @Test func settingsAreKeptForEachAccountAndSurviveALogOut() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        let mine = EngineSettings(lockPolicy: LockPolicy(timeout: .afterInactivity(minutes: 5), action: .logOut),
                                  clipboardClearing: .never, showsWebsiteIcons: false)
        #expect(try await store.loadSettings(accountID: record.account.id) == nil)
        try await store.save(record)
        try await store.saveSettings(mine, accountID: record.account.id)
        try await store.saveSettings(.default, accountID: "another-account")
        try await store.clear()

        let reopened = FileAccountStore(directory: directory, secrets: secrets)
        #expect(try await reopened.load() == nil)
        #expect(try await reopened.loadSettings(accountID: record.account.id) == mine)
        #expect(try await reopened.loadSettings(accountID: "another-account") == .default)
        #expect(try await reopened.loadSettings(accountID: "unknown") == nil)
    }

    @Test func aPinAndARememberedDeviceLieInTheSecretStoreOnly() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        let pin = StoredPin(envelope: "synthetic-envelope", encryptedPin: "2.synthetic-pin", failedAttempts: 3)
        try await store.save(record)
        try await store.savePin(pin, accountID: record.account.id)
        try await store.saveTwoStepRememberToken("synthetic-remember", server: record.account.serverURL, email: record.account.email)

        let reopened = FileAccountStore(directory: directory, secrets: secrets)
        #expect(try await reopened.loadPin(accountID: record.account.id) == pin)
        #expect(try await reopened.loadPin(accountID: "another-account") == nil)
        #expect(try await reopened.twoStepRememberToken(server: record.account.serverURL, email: "TEST.USER@passvault.test") == "synthetic-remember")
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let text = String(decoding: try Data(contentsOf: directory.appending(path: name)), as: UTF8.self)
            #expect(!text.contains("synthetic-envelope") && !text.contains("synthetic-pin") && !text.contains("synthetic-remember"), "\(name)")
        }

        try await reopened.savePin(nil, accountID: record.account.id)
        try await reopened.saveTwoStepRememberToken(nil, server: record.account.serverURL, email: record.account.email)
        try await reopened.clear()
        #expect(secrets.isEmpty)
    }

    @Test func damagedFilesAreReportedAndNotReadAsEmpty() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        try await store.save(record)
        try await store.saveSettings(.default, accountID: record.account.id)
        try Data("{ not json".utf8).write(to: directory.appending(path: "account.json"))
        try Data("[1, 2".utf8).write(to: directory.appending(path: "settings.json"))

        let reopened = FileAccountStore(directory: directory, secrets: secrets)
        await #expect(throws: EngineError.storage("The stored file account.json is not readable.")) {
            _ = try await reopened.load()
        }
        await #expect(throws: EngineError.storage("The stored file settings.json is not readable.")) {
            _ = try await reopened.loadSettings(accountID: record.account.id)
        }
        // The damaged files are still there.
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "account.json").path))
    }

    @Test func tokensAreNotWrittenToFiles() async throws {
        try await FileAccountStore(directory: directory, secrets: secrets).save(record)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let text = String(decoding: try Data(contentsOf: directory.appending(path: name)), as: UTF8.self)
            #expect(!text.contains("synthetic-access-token"), "\(name)")
            #expect(!text.contains("synthetic-refresh-token"), "\(name)")
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.posixPermissions] as? Int
            #expect(permissions == 0o600, "\(name)")
        }
    }

    @Test func clearRemovesTheAccountButKeepsTheDevice() async throws {
        let store = FileAccountStore(directory: directory, secrets: secrets)
        let device = try await store.deviceIdentifier()
        try await store.save(record)
        try await store.clear()

        #expect(try await store.load() == nil)
        #expect(secrets.isEmpty)
        #expect(try await FileAccountStore(directory: directory, secrets: secrets).deviceIdentifier() == device)
    }

    @Test func anEmptyStoreHasNoAccount() async throws {
        #expect(try await FileAccountStore(directory: directory, secrets: secrets).load() == nil)
    }

    @Test func anAccountWithoutTokensStillLoads() async throws {
        try await FileAccountStore(directory: directory, secrets: secrets).save(record)
        try secrets.delete("session-tokens")
        let loaded = try #require(await FileAccountStore(directory: directory, secrets: secrets).load())
        #expect(loaded.account == record.account)
        #expect(loaded.accessToken.isEmpty)
        #expect(loaded.vaultPayload == record.vaultPayload)
    }

    @Test func anUnreadableAccountFileIsAnError() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "account.json"))
        await #expect(throws: EngineError.storage("The stored file account.json is not readable.")) {
            _ = try await FileAccountStore(directory: directory, secrets: secrets).load()
        }
    }
}
