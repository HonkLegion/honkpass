import Engine
import Foundation
import VaultModel

/// A synthetic account for engine tests and for running the app without a server.
/// The fakes do no cryptography: the "hash" and the "wrapped key" are readable strings.
public struct FakeAccount: Sendable {
    public var server: URL
    public var email: String
    public var masterPassword: String
    public var userID: String
    public var contents: VaultContents
    /// Two-step login of the account; nil without it.
    public var twoStep: TwoStep?

    /// The second step of a fake account. Every method takes the same code.
    public struct TwoStep: Sendable {
        public var methods: [TwoStepMethod]
        public var code: String
        public var emailHint: String?

        /// What the fake server asks a security key to sign, and the answer it takes.
        public static let webAuthnRequest = #"{"allowCredentials":[{"id":"ZmFrZS1rZXk","type":"public-key"}],"challenge":"ZmFrZS1jaGFsbGVuZ2U","rpId":"vault.example","timeout":60000,"userVerification":"preferred"}"#
        public static let webAuthnAnswer = #"{"id":"ZmFrZS1rZXk","rawId":"ZmFrZS1rZXk=","response":{"authenticatorData":"ZmFrZQ==","clientDataJson":"ZmFrZQ==","signature":"ZmFrZQ=="},"type":"public-key"}"#

        public init(methods: [TwoStepMethod], code: String = "123456", emailHint: String? = nil) {
            self.methods = methods
            self.code = code
            self.emailHint = emailHint
        }
    }

    public init(server: URL, email: String, masterPassword: String, userID: String, contents: VaultContents,
                twoStep: TwoStep? = nil) {
        self.server = server
        self.email = email
        self.masterPassword = masterPassword
        self.userID = userID
        self.contents = contents
        self.twoStep = twoStep
    }

    /// The demo account with two-step login by authenticator app and by email.
    public static var demoWithTwoStep: FakeAccount {
        var account = FakeAccount.demo
        account.twoStep = TwoStep(methods: [.authenticator, .email], emailHint: "de**@passvault.test")
        return account
    }

    public static let demo = FakeAccount(
        server: URL(string: "https://vault.example")!,
        email: "demo@passvault.test",
        masterPassword: "demo-master-password",
        userID: "00000000-0000-4000-8000-000000000001",
        contents: VaultContents(
            items: [
                VaultItemSummary(id: "item-1", type: .login, name: "Example Mail", subtitle: "demo@passvault.test", isFavorite: true,
                                 fields: [.username, .password, .verificationCode, .website],
                                 websites: [.init(address: "https://item-1.example")]),
                VaultItemSummary(id: "item-2", type: .login, name: "Example Shop", subtitle: "demo-shopper", folderID: "folder-1",
                                 fields: [.username, .password, .website], websites: [.init(address: "https://item-2.example")]),
                VaultItemSummary(id: "item-3", type: .card, name: "Example Card", subtitle: "Visa, *4242",
                                 fields: [.cardNumber, .cardSecurityCode], cardBrand: "Visa"),
                VaultItemSummary(id: "item-4", type: .identity, name: "Example Identity", subtitle: "Demo Person",
                                 fields: [.identityEmail]),
                VaultItemSummary(id: "item-5", type: .secureNote, name: "Example Note"),
                VaultItemSummary(id: "item-6", type: .sshKey, name: "Example SSH Key", fields: [.sshKey]),
                VaultItemSummary(id: "item-7", type: .login, name: "Example Old Login", subtitle: "demo-old", isInTrash: true),
            ],
            folders: [VaultFolder(id: "folder-1", name: "Shopping")],
            // An organization without items of its own: a test or a picture moves one there.
            organizations: [VaultOrganization(id: "organization-1", name: "Example Organization")],
            collections: [VaultCollection(id: "collection-1", organizationID: "organization-1", name: "Example Collection"),
                          VaultCollection(id: "collection-2", organizationID: "organization-1", name: "Example Team")]))
}

public extension EnginePorts {
    /// Ports for one fake account, plus handles that let a test drive them.
    static func fake(_ account: FakeAccount = .demo, stored: StoredAccount? = nil, settings: [String: EngineSettings] = [:],
                     pins: [String: StoredPin] = [:]) -> (ports: EnginePorts, handles: FakeHandles) {
        let handles = FakeHandles(server: FakeServer(account: account),
                                  store: InMemoryAccountStore(stored: stored, settings: settings, pins: pins),
                                  systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(), activeField: FakeActiveField(),
                                  identities: FakeCredentialIdentities(), leaks: FakePasswordLeaks(), sshAgent: FakeSSHAgent(),
                                  appSignatures: FakeAppSignatures(), biometrics: FakeBiometricKeys())
        let ports = EnginePorts(server: handles.server, crypto: FakeCrypto(), store: handles.store,
                                systemEvents: handles.systemEvents, clipboard: handles.clipboard, leaks: handles.leaks,
                                activeField: handles.activeField, identities: handles.identities, sshAgent: handles.sshAgent,
                                appSignatures: handles.appSignatures, biometrics: handles.biometrics)
        return (ports, handles)
    }
}

public struct FakeHandles: Sendable {
    public let server: FakeServer
    public let store: InMemoryAccountStore
    public let systemEvents: ManualSystemEvents
    public let clipboard: FakeClipboard
    public let activeField: FakeActiveField
    public let identities: FakeCredentialIdentities
    public let leaks: FakePasswordLeaks
    public let sshAgent: FakeSSHAgent
    public let appSignatures: FakeAppSignatures
    public let biometrics: FakeBiometricKeys
}

// MARK: Touch ID

/// A Keychain behind Touch ID without either: it keeps the keys in memory, and a test says
/// what the user answers to the question of the system. It starts as a Mac without a sensor,
/// as the Mac of the reference pictures was.
public actor FakeBiometricKeys: BiometricKeysPort {
    /// What the user does when the system asks.
    public enum Answer: Sendable {
        /// A finger the system knows.
        case accept
        /// "Cancel" in the question.
        case cancel
        /// The system gives nothing: too many wrong fingers.
        case fail
    }

    public private(set) var isSensorAvailable: Bool
    public private(set) var kept: [String: String] = [:]
    /// What the question of the system said, each time it was asked.
    public private(set) var reasons: [String] = []
    private var answer = Answer.accept
    private var failsNextKeep = false
    /// The question stays open until a test answers it.
    private var waiting: CheckedContinuation<Void, Never>?
    private var holdsNextQuestion = false

    public init(isSensorAvailable: Bool = false) {
        self.isSensorAvailable = isSensorAvailable
    }

    /// Connects a keyboard with Touch ID, or takes it away.
    public func setSensorAvailable(_ isAvailable: Bool) { isSensorAvailable = isAvailable }
    public func setAnswer(_ answer: Answer) { self.answer = answer }
    public func failNextKeep() { failsNextKeep = true }
    /// Puts a key into the Keychain as another run of the app would have left it.
    public func setKept(_ key: String?, accountID: String) { kept[accountID] = key }
    /// The next question waits for `answerQuestion()`, as a person takes a while.
    public func holdNextQuestion() { holdsNextQuestion = true }
    public func answerQuestion() {
        waiting?.resume()
        waiting = nil
    }
    public var isAsking: Bool { waiting != nil }

    public func isAvailable() async -> Bool { isSensorAvailable }
    public func hasKey(accountID: String) async -> Bool { kept[accountID] != nil }

    public func keep(_ userKey: String, accountID: String) async throws {
        guard isSensorAvailable else { throw EngineError.biometrics(.unavailable) }
        if failsNextKeep {
            failsNextKeep = false
            throw EngineError.biometrics(.failed)
        }
        kept[accountID] = userKey
    }

    public func key(accountID: String, reason: String) async throws -> String {
        guard let key = kept[accountID] else { throw EngineError.biometrics(.notEnabled) }
        guard isSensorAvailable else { throw EngineError.biometrics(.unavailable) }
        reasons.append(reason)
        if holdsNextQuestion {
            holdsNextQuestion = false
            await withCheckedContinuation { waiting = $0 }
        }
        switch answer {
        case .accept: return key
        case .cancel: throw EngineError.biometrics(.cancelled)
        case .fail: throw EngineError.biometrics(.failed)
        }
    }

    public func remove(accountID: String) async throws { kept[accountID] = nil }
}

// MARK: SSH agent

/// The socket of the SSH agent, without a socket: a test asks through `requests` what an SSH
/// client would ask.
public actor FakeSSHAgent: SSHAgentPort {
    public private(set) var requests: (any SSHAgentRequests)?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    private var failsNextStart = false

    public init() {}

    public var isRunning: Bool { requests != nil }
    public func failNextStart() { failsNextStart = true }

    public func start(_ requests: any SSHAgentRequests) async throws {
        if failsNextStart {
            failsNextStart = false
            throw EngineError.unexpected("The fake socket cannot be made.")
        }
        startCount += 1
        self.requests = requests
    }

    public func stop() async {
        stopCount += 1
        requests = nil
    }
}

// MARK: AutoFill of the system

/// The store of the system's AutoFill, in memory: it remembers what it was given.
public actor FakeCredentialIdentities: CredentialIdentitiesPort {
    /// The user has turned PassVault on as a source of AutoFill.
    public private(set) var isOn = true
    public private(set) var identities: [AutoFillIdentity] = []
    /// How often the entries were replaced or removed.
    public private(set) var writes = 0

    public init() {}

    public func setOn(_ isOn: Bool) { self.isOn = isOn }

    public func isEnabled() async -> Bool { isOn }

    public func replace(with identities: [AutoFillIdentity]) async {
        self.identities = identities
        writes += 1
    }

    public func removeAll() async {
        identities = []
        writes += 1
    }
}

// MARK: Apps

/// A disk with apps that are none: what the signature of each folder would say.
public actor FakeAppSignatures: AppSignaturesPort {
    /// An app that a developer signed: the one the fake field is in.
    public static let editor = URL(fileURLWithPath: "/Applications/Fake Editor.app")
    public static let editorAddress = AppAddress(bundleID: "test.fake.editor", developer: "FAKETEAM01")
    public static let editorID = UUID(uuidString: "00000000-0000-4000-8000-000000000031")!
    /// A browser, signed too.
    public static let browser = URL(fileURLWithPath: "/Applications/Fake Browser.app")
    /// An app that nobody signed.
    public static let unsigned = URL(fileURLWithPath: "/Applications/Fake Unsigned.app")

    private var apps: [String: SignedApp] = [:]
    private var running: [RunningApp] = []

    public init() {
        if let editor = Self.editorAddress {
            apps[Self.editor.path] = SignedApp(address: editor)
            running = [RunningApp(id: Self.editorID, name: "Fake Editor", location: Self.editor, address: editor)]
        }
        if let browser = AppAddress(bundleID: "test.fake.browser", developer: "FAKETEAM01") {
            apps[Self.browser.path] = SignedApp(address: browser, isBrowser: true)
        }
    }

    /// Puts an app at a place of the disk, or takes it away.
    public func set(_ app: SignedApp?, at location: URL) { apps[location.path] = app }

    public func app(at location: URL) async -> SignedApp? { apps[location.path] }
    public func setRunningApps(_ apps: [RunningApp]) { running = apps }
    public func runningApps() async -> [RunningApp] { running }
    public func app(runningID: UUID) async -> SignedApp? {
        guard let selected = running.first(where: { $0.id == runningID }),
              let current = apps[selected.location.path], current.address == selected.address else { return nil }
        return current
    }
}

// MARK: Fill

/// The field of another app, which is no app at all: it remembers what was written into it.
public actor FakeActiveField: ActiveFieldPort {
    /// The permission of the system. A fake has it unless a test takes it away.
    public private(set) var isPermitted = true
    /// The field that has the cursor. nil is an app without one.
    public private(set) var field: FillTarget? = FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor")
    /// The texts that were written, with the field each went to.
    public private(set) var written: [(text: String, target: FillTarget)] = []
    /// The logins that were written into a form.
    public private(set) var writtenLogins: [(username: String, password: String, verificationCode: String?, target: FillTarget)] = []
    public private(set) var askedForPermission = 0
    private var refusesNextWrite = false
    private var beforeWrite: (@Sendable () async -> Void)?

    public init() {}

    public func setPermitted(_ isPermitted: Bool) { self.isPermitted = isPermitted }
    /// Moves the cursor to another field, or to none.
    public func setField(_ field: FillTarget?) { self.field = field }
    public func refuseNextWrite() { refusesNextWrite = true }
    public func setBeforeWrite(_ action: @escaping @Sendable () async -> Void) { beforeWrite = action }

    public func isAllowed() async -> Bool { isPermitted }
    public func askToBeAllowed() async { askedForPermission += 1 }
    public func capture() async -> FillTarget? { isPermitted ? field : nil }

    public func write(_ text: String, to target: FillTarget, authorize: FillAuthorization) async throws {
        guard isPermitted else { throw EngineError.fill(.notAllowed) }
        guard let field else { throw EngineError.fill(.noField) }
        guard field.id == target.id else { throw EngineError.fill(.targetChanged) }
        if refusesNextWrite {
            refusesNextWrite = false
            throw EngineError.fill(.refused)
        }
        await beforeWrite?()
        try await authorize()
        written.append((text, target))
    }

    public func writeLogin(username: String, password: String, verificationCode: String?, to target: FillTarget, authorize: FillAuthorization) async throws {
        guard isPermitted else { throw EngineError.fill(.notAllowed) }
        guard let field, field.takesLogin else { throw EngineError.fill(.noField) }
        guard field.id == target.id else { throw EngineError.fill(.targetChanged) }
        if refusesNextWrite {
            refusesNextWrite = false
            throw EngineError.fill(.refused)
        }
        guard verificationCode == nil || target.takesVerificationCode else { throw EngineError.fill(.noField) }
        await beforeWrite?()
        try await authorize()
        writtenLogins.append((username, password, verificationCode, target))
    }
}

// MARK: Leaked passwords

/// A leaked password service that asks nobody. It knows the passwords it was given.
public actor FakePasswordLeaks: PasswordLeaksPort {
    private var known: [String: Int]
    private var isReachable = true
    public private(set) var checkCount = 0

    public init(known: [String: Int] = ["password": 52_256_179]) {
        self.known = known
    }

    /// The service stops answering.
    public func goOffline() {
        isReachable = false
    }

    public func timesLeaked(_ password: String) async throws -> Int {
        checkCount += 1
        guard isReachable else { throw EngineError.serverUnreachable }
        return known[password] ?? 0
    }
}

// MARK: Server

public actor FakeServer: ServerPort {
    private var account: FakeAccount
    private var failure: EngineError?
    private var syncGate: CheckedContinuation<Void, Never>?
    private var syncGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsSync = false
    private var uploadGate: CheckedContinuation<Void, Never>?
    private var uploadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsUpload = false
    public private(set) var syncCount = 0
    public private(set) var refreshCount = 0
    private var accessToken = "fake-access-token"
    private var refusesRefresh = false

    public init(account: FakeAccount) {
        self.account = account
    }

    public func setContents(_ contents: VaultContents) {
        account.contents = contents
    }

    /// The next request fails with this error.
    public func failNext(_ error: EngineError) {
        failure = error
    }

    /// The next sync waits until `releaseSync()`.
    public func holdNextSync() {
        holdsSync = true
    }

    /// Returns when a held sync is waiting.
    public func syncIsHeld() async {
        if syncGate != nil { return }
        await withCheckedContinuation { syncGateWaiters.append($0) }
    }

    public func releaseSync() {
        syncGate?.resume()
        syncGate = nil
    }

    /// The next upload stops when half of it has gone, until `releaseUpload()`: for a picture
    /// and a check of the progress.
    public func holdNextUpload() {
        holdsUpload = true
    }

    /// Returns when a held upload is waiting.
    public func uploadIsHeld() async {
        if uploadGate != nil { return }
        await withCheckedContinuation { uploadGateWaiters.append($0) }
    }

    public func releaseUpload() {
        uploadGate?.resume()
        uploadGate = nil
    }

    /// The server stops accepting the current access token, as after its lifetime.
    public func expireAccessToken() {
        accessToken = "fake-access-token-\(refreshCount + 1)"
    }

    /// The server also refuses the refresh token: the session is over.
    public func endSession() {
        expireAccessToken()
        refusesRefresh = true
    }

    private func takeFailure() throws {
        if let failure {
            self.failure = nil
            throw failure
        }
    }

    public func prelogin(server: URL, email: String) async throws -> Prelogin {
        try takeFailure()
        return Prelogin(kdf: .pbkdf2(iterations: 600_000), salt: email.lowercased())
    }

    /// The log-in requests the server got, without their password hash.
    public private(set) var logInProofs: [TwoStepProof?] = []
    public private(set) var twoStepEmailCount = 0
    /// The token of "remember me" that the server accepts in place of a code.
    public private(set) var rememberToken: String?

    /// The server forgets the remembered device, as after thirty days.
    public func forgetRememberedDevice() {
        rememberToken = nil
    }

    public func logIn(_ request: LoginRequest) async throws -> LoginOutcome {
        try takeFailure()
        let expected = FakeCrypto.hash(password: account.masterPassword, salt: account.email.lowercased())
        guard request.server == account.server, request.email.lowercased() == account.email.lowercased(),
              request.passwordHash == expected else { throw EngineError.invalidCredentials }
        logInProofs.append(request.twoStep)
        var newRememberToken: String?
        if let twoStep = account.twoStep {
            let challenge = TwoStepChallenge(methods: twoStep.methods, emailHint: twoStep.emailHint,
                                             webAuthnRequest: twoStep.methods.contains(.webAuthn) ? FakeAccount.TwoStep.webAuthnRequest : nil)
            guard let proof = request.twoStep else { return .needsTwoStep(challenge) }
            switch proof.kind {
            case .rememberedDevice:
                guard rememberToken != nil, proof.token == rememberToken else { return .needsTwoStep(challenge) }
            case .method(let method):
                // A security key answers with what it signed; every other method with the code.
                let expected = method == .webAuthn ? FakeAccount.TwoStep.webAuthnAnswer : twoStep.code
                guard twoStep.methods.contains(method), proof.token == expected else { throw EngineError.invalidTwoStepCode }
                if proof.remember {
                    newRememberToken = "fake-remember-token-\(logInProofs.count)"
                    rememberToken = newRememberToken
                }
            }
        }
        knownDevices.insert(request.deviceIdentifier)
        let material = AccountCryptoMaterial(
            kdf: request.prelogin.kdf, salt: request.prelogin.salt,
            masterKeyWrappedUserKey: FakeCrypto.wrappedKeyPrefix + expected, keys: .v1(privateKey: "fake-private-key"))
        return .granted(LoginGrant(userID: account.userID, accessToken: accessToken, refreshToken: "fake-refresh-token",
                                   expiresIn: 3_600, crypto: material, twoStepRememberToken: newRememberToken))
    }

    public func sendTwoStepEmail(_ request: LoginRequest) async throws {
        try takeFailure()
        guard account.twoStep?.methods.contains(.email) == true else { throw EngineError.server("Email 2FA is disabled") }
        twoStepEmailCount += 1
    }

    /// The imports the server got, as the fake crypto wrote them.
    public private(set) var imports: [VaultImport] = []
    private var importedCredentials: [String: VaultImport.Item] = [:]

    public func importVault(request: Data, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let file = try? JSONDecoder().decode(VaultImport.self, from: request) else {
            throw EngineError.server("HTTP 400: The request is not readable")
        }
        imports.append(file)
        var folderIDs: [String] = []
        for folder in file.folders {
            if let id = folder.id, account.contents.folders.contains(where: { $0.id == id }) {
                folderIDs.append(id)
            } else {
                folderIDs.append(try await saveFolder(id: nil, encryptedName: FakeUnlockedCrypto.folderNamePrefix + folder.name,
                                                      server: server, accessToken: accessToken))
            }
        }
        for item in file.items {
            var draft = item.draft
            draft.id = nil
            draft.folderID = item.folder.flatMap { folderIDs.indices.contains($0) ? folderIDs[$0] : nil }
            if case .login(var login) = draft.content {
                login.passkeyCreated = item.passkeys?.first?.creationDate
                draft.content = .login(login)
            }
            let id = try await save(request: try JSONEncoder().encode(draft), itemID: nil, server: server, accessToken: accessToken)
            importedCredentials[id] = item
        }
    }

    /// The devices that logged in to the account: the server knows them from then on.
    public private(set) var knownDevices: Set<String> = []

    public func isKnownDevice(server: URL, email: String, deviceIdentifier: String) async throws -> Bool {
        try takeFailure()
        return server == account.server && email.lowercased() == account.email.lowercased() && knownDevices.contains(deviceIdentifier)
    }

    /// The addresses a hint of the master password was asked for.
    public private(set) var hintRequests: [String] = []

    public func requestPasswordHint(server: URL, email: String) async throws {
        try takeFailure()
        hintRequests.append(email)
    }

    public func refresh(server: URL, refreshToken: String) async throws -> TokenRefresh {
        try takeFailure()
        guard refreshToken == "fake-refresh-token", !refusesRefresh else { throw EngineError.sessionExpired }
        refreshCount += 1
        return TokenRefresh(accessToken: accessToken, refreshToken: nil, expiresIn: 3_600)
    }

    public private(set) var iconRequests: [String] = []

    public func websiteIcon(server: URL, host: String) async throws -> Data {
        iconRequests.append(host)
        guard host.hasSuffix(".example") else { throw EngineError.server("HTTP 404") }
        return Data("fake-icon-\(host)".utf8)
    }

    /// The changes of items the server got, in their order.
    public private(set) var writes: [RecordedWrite] = []

    public struct RecordedWrite: Sendable, Equatable {
        public let write: ItemWrite
        public let itemID: String

        public init(_ write: ItemWrite, itemID: String) {
            self.write = write
            self.itemID = itemID
        }
    }

    public func write(_ write: ItemWrite, itemID: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let index = account.contents.items.firstIndex(where: { $0.id == itemID }) else {
            throw EngineError.server("HTTP 400: Cipher doesn't exist")
        }
        writes.append(RecordedWrite(write, itemID: itemID))
        switch write {
        case .placement(let isFavorite, let folderID):
            account.contents.items[index].isFavorite = isFavorite
            account.contents.items[index].folderID = folderID
        case .archive: account.contents.apply(.archive, to: itemID)
        case .unarchive: account.contents.apply(.unarchive, to: itemID)
        case .moveToTrash: account.contents.apply(.moveToTrash, to: itemID)
        case .restore: account.contents.apply(.restore, to: itemID)
        case .deletePermanently: account.contents.apply(.deletePermanently, to: itemID)
        }
    }

    /// The changes of several items the server got, in their order.
    public private(set) var bulkWrites: [RecordedBulkWrite] = []

    public struct RecordedBulkWrite: Sendable, Equatable {
        public let write: ItemBulkWrite
        public let itemIDs: Set<String>

        public init(_ write: ItemBulkWrite, itemIDs: Set<String>) {
            self.write = write
            self.itemIDs = itemIDs
        }
    }

    public func write(_ write: ItemBulkWrite, itemIDs: [String], server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard itemIDs.allSatisfy({ id in account.contents.items.contains { $0.id == id } }) else {
            throw EngineError.server("HTTP 400: Cipher doesn't exist")
        }
        bulkWrites.append(RecordedBulkWrite(write, itemIDs: Set(itemIDs)))
        let change: ItemChange = switch write {
        case .moveToFolder(let folderID): .moveToFolder(folderID)
        case .archive: .archive
        case .unarchive: .unarchive
        case .moveToTrash: .moveToTrash
        case .restore: .restore
        case .deletePermanently: .deletePermanently
        }
        for id in itemIDs { account.contents.apply(change, to: id) }
    }

    /// The forms the server got, in their order, and what it keeps of each saved item.
    public private(set) var savedDrafts: [ItemDraft] = []
    private var saved: [String: ItemDraft] = [:]
    private var createdCount = 0

    /// The fake request is the draft itself; the fake server reads it.
    public func save(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard var draft = try? JSONDecoder().decode(ItemDraft.self, from: request), draft.id == itemID else {
            throw EngineError.server("HTTP 400: The request is not readable")
        }
        savedDrafts.append(draft)
        let old = itemID.flatMap { id in account.contents.items.first { $0.id == id } }
        if itemID != nil, old == nil { throw EngineError.server("HTTP 400: Cipher doesn't exist") }
        createdCount += 1
        let id = itemID ?? "created-\(createdCount)"
        draft.id = id
        saved[id] = draft
        if case .login(let login) = draft.content, login.passkeyCreated == nil {
            importedCredentials[id]?.passkeys = nil
        }
        var fields: Set<ItemField> = []
        var subtitle = "", cardBrand: String?
        var websites: [ItemDraft.Website] = []
        switch draft.content {
        case .login(let login):
            subtitle = login.username
            if !login.username.isEmpty { fields.insert(.username) }
            if !login.password.isEmpty { fields.insert(.password) }
            if !login.verificationKey.isEmpty { fields.insert(.verificationCode) }
            // The address of an app is kept among the websites and is none.
            if login.websites.contains(where: { !$0.address.isEmpty && $0.app == nil }) { fields.insert(.website) }
            websites = login.websites.filter { !$0.address.isEmpty }
        case .card(let card):
            cardBrand = card.brand
            if card.number?.isEmpty == false { fields.insert(.cardNumber) }
            if card.securityCode?.isEmpty == false { fields.insert(.cardSecurityCode) }
        case .secureNote:
            if !draft.notes.isEmpty { fields.insert(.notes) }
        case .identity(let identity):
            if identity.username?.isEmpty == false { fields.insert(.identityUsername) }
            if identity.email?.isEmpty == false { fields.insert(.identityEmail) }
            if identity.phone?.isEmpty == false { fields.insert(.identityPhone) }
            if identity.fullAddress != nil { fields.insert(.identityAddress) }
        case .sshKey(let key):
            if !key.privateKey.isEmpty { fields.insert(.sshKey) }
        }
        // A login keeps its passkey unless the form removed it; a request of the fake
        // authenticator brings a new one, which takes the place of the old.
        var passkeys = old?.passkeys ?? []
        if case .login(let login) = draft.content, login.passkeyCreated == nil { passkeys = [] }
        if let made = (try? JSONDecoder().decode(FakeUnlockedCrypto.MadePasskey.self, from: request))?.fakePasskey {
            passkeys = [made]
            importedCredentials[id]?.passkeys = nil
        }
        let summary = VaultItemSummary(id: id, type: draft.type, name: draft.name, subtitle: subtitle, isFavorite: draft.isFavorite,
                                       folderID: draft.folderID, isInTrash: false, isArchived: old?.isArchived ?? false,
                                       fields: fields, cardBrand: cardBrand, asksForMasterPassword: draft.asksForMasterPassword,
                                       websites: websites, passkeys: passkeys,
                                       organizationID: old?.organizationID ?? draft.organizationID,
                                       collectionIDs: old?.collectionIDs ?? draft.collectionIDs)
        if let index = account.contents.items.firstIndex(where: { $0.id == id }) {
            account.contents.items[index] = summary
        } else {
            account.contents.items.append(summary)
        }
        return id
    }

    /// The items that were given to an organization, and the collections that were set.
    public private(set) var shares: [FakeShare] = []
    public private(set) var collectionChanges: [(itemID: String, collectionIDs: [String])] = []

    /// A new item of an organization is the fake request of an item; a moved one names its
    /// item, its organization and its collections.
    public func share(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        guard let itemID else {
            guard let draft = try? JSONDecoder().decode(ItemDraft.self, from: request), draft.organizationID != nil,
                  !draft.collectionIDs.isEmpty else { throw EngineError.server("HTTP 400: You must select at least one collection.") }
            return try await save(request: request, itemID: nil, server: server, accessToken: accessToken)
        }
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let share = try? JSONDecoder().decode(FakeShare.self, from: request), share.itemID == itemID,
              let index = account.contents.items.firstIndex(where: { $0.id == itemID }) else {
            throw EngineError.server("HTTP 400: The request is not readable")
        }
        shares.append(share)
        account.contents.items[index].organizationID = share.organizationID
        account.contents.items[index].collectionIDs = share.collectionIDs
        return itemID
    }

    public func setCollections(_ collectionIDs: [String], itemID: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let index = account.contents.items.firstIndex(where: { $0.id == itemID && $0.organizationID != nil }) else {
            throw EngineError.server("HTTP 404: Cipher doesn't exist")
        }
        collectionChanges.append((itemID, collectionIDs))
        account.contents.items[index].collectionIDs = collectionIDs
    }

    /// The names of the folders the server got, encrypted the fake way, in their order.
    public private(set) var savedFolderNames: [String] = []
    private var folderCount = 0

    public func saveFolder(id: String?, encryptedName: String, server: URL, accessToken: String) async throws -> String {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard encryptedName.hasPrefix(FakeUnlockedCrypto.folderNamePrefix) else {
            throw EngineError.server("HTTP 400: The folder name is not encrypted")
        }
        if let id, !account.contents.folders.contains(where: { $0.id == id }) { throw EngineError.server("HTTP 404: Invalid folder") }
        savedFolderNames.append(encryptedName)
        folderCount += 1
        let folderID = id ?? "created-folder-\(folderCount)"
        account.contents.folders.removeAll { $0.id == folderID }
        account.contents.folders.append(VaultFolder(id: folderID, name: String(encryptedName.dropFirst(FakeUnlockedCrypto.folderNamePrefix.count))))
        return folderID
    }

    public func deleteFolder(id: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard account.contents.folders.contains(where: { $0.id == id }) else { throw EngineError.server("HTTP 404: Invalid folder") }
        account.contents.folders.removeAll { $0.id == id }
        for index in account.contents.items.indices where account.contents.items[index].folderID == id {
            account.contents.items[index].folderID = nil
        }
    }

    // MARK: Sends

    /// What the Sends the server got carry, by identifier.
    private var sendContents: [String: VaultSend] = [:]
    private var sendCount = 0
    /// The forms of the Sends the server got, in their order, each without the content of its file.
    public private(set) var savedSends: [SendDraft] = []
    /// The file names and the sizes of the files of the file Sends the server got.
    public private(set) var uploadedSendFiles: [(fileName: String, size: Int)] = []
    public private(set) var removedSendPasswords: [String] = []

    private func store(_ request: Data, sendID: String?, file: EncryptedSendFile?) throws -> String {
        guard let draft = try? JSONDecoder().decode(SendDraft.self, from: request) else {
            throw EngineError.server("HTTP 400: The Send is not readable")
        }
        let old = sendID.flatMap { id in account.contents.sends.first { $0.id == id } }
        if sendID != nil, old == nil { throw EngineError.server("HTTP 404: Send not found") }
        savedSends.append(draft)
        sendCount += 1
        let id = sendID ?? "created-send-\(sendCount)"
        let summary = VaultSendSummary(id: id, type: draft.type, name: draft.name, deletionDate: draft.deletionDate,
                                       expirationDate: draft.deletionDate, maxAccessCount: draft.maxAccessCount,
                                       accessCount: old?.accessCount ?? 0,
                                       hasPassword: draft.newPassword != nil || old?.hasPassword == true)
        let kept = sendContents[id]
        account.contents.sends.removeAll { $0.id == id }
        account.contents.sends.append(summary)
        sendContents[id] = VaultSend(summary: summary, notes: draft.notes.isEmpty ? nil : draft.notes,
                                     text: draft.type == .text ? draft.text : nil, hidesText: draft.hidesText,
                                     fileName: file.map { String($0.fileName.dropFirst(FakeUnlockedCrypto.fileNamePrefix.count)) } ?? kept?.fileName,
                                     fileSizeName: file.map { "\($0.contents.count - FakeUnlockedCrypto.fileContentsPrefix.count) Bytes" }
                                         ?? kept?.fileSizeName,
                                     hidesEmail: draft.hidesEmail, linkPath: "fake-access-\(id)/fake-key-\(id)")
        return id
    }

    public func saveSend(request: Data, sendID: String?, server: URL, accessToken: String) async throws -> String {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        return try store(request, sendID: sendID, file: nil)
    }

    public func saveFileSend(request: Data, file: EncryptedSendFile, server: URL, accessToken: String) async throws -> String {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard file.fileName.hasPrefix(FakeUnlockedCrypto.fileNamePrefix), file.contents.starts(with: FakeUnlockedCrypto.fileContentsPrefix) else {
            throw EngineError.server("HTTP 400: The file is not encrypted")
        }
        uploadedSendFiles.append((file.fileName, file.contents.count))
        return try store(request, sendID: nil, file: file)
    }

    public func deleteSend(id: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard account.contents.sends.contains(where: { $0.id == id }) else { throw EngineError.server("HTTP 404: Send not found") }
        account.contents.sends.removeAll { $0.id == id }
        sendContents[id] = nil
    }

    public func removeSendPassword(id: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let index = account.contents.sends.firstIndex(where: { $0.id == id }) else {
            throw EngineError.server("HTTP 404: Send not found")
        }
        account.contents.sends[index].hasPassword = false
        sendContents[id]?.summary.hasPassword = false
        removedSendPasswords.append(id)
    }

    /// The files the server keeps for each item, as the fake crypto has "encrypted" them.
    private var attachments: [String: [(info: ItemAttachment, contents: Data)]] = [:]
    private var attachmentCount = 0
    /// The file names the server got, encrypted the fake way, in their order.
    public private(set) var uploadedFileNames: [String] = []

    /// The next upload is stored damaged: what is read back differs from what was sent.
    public private(set) var damagesNextUpload = false

    public func setDamagesNextUpload() {
        damagesNextUpload = true
    }

    /// Puts a file of the old kind on an item: one without a key of its own.
    public func addOldAttachment(named name: String, contents: Data, to itemID: String) {
        guard let index = account.contents.items.firstIndex(where: { $0.id == itemID }) else { return }
        attachmentCount += 1
        attachments[itemID, default: []].append((ItemAttachment(id: "attachment-\(attachmentCount)", fileName: name,
                                                               sizeName: "\(contents.count) Bytes", hasOwnKey: false),
                                                FakeUnlockedCrypto.fileContentsPrefix + contents))
        account.contents.items[index].attachmentCount += 1
    }

    /// The files of an item as the server has them.
    public func attachmentList(of itemID: String) -> [ItemAttachment] {
        (attachments[itemID] ?? []).map(\.info)
    }

    /// The file goes in two halves: `progress` hears 0.5 and then 1.
    @discardableResult
    public func addAttachment(_ attachment: EncryptedAttachment, itemID: String, server: URL, accessToken: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard account.contents.items.contains(where: { $0.id == itemID }) else {
            throw EngineError.server("HTTP 400: Cipher doesn't exist")
        }
        guard attachment.fileName.hasPrefix(FakeUnlockedCrypto.fileNamePrefix) else {
            throw EngineError.server("HTTP 400: The file name is not encrypted")
        }
        progress(0.5)
        if holdsUpload {
            holdsUpload = false
            await withCheckedContinuation { continuation in
                uploadGate = continuation
                for waiter in uploadGateWaiters { waiter.resume() }
                uploadGateWaiters = []
            }
        }
        progress(1)
        // The items may have changed while the upload waited.
        guard let index = account.contents.items.firstIndex(where: { $0.id == itemID }) else {
            throw EngineError.server("HTTP 400: Cipher doesn't exist")
        }
        uploadedFileNames.append(attachment.fileName)
        attachmentCount += 1
        let name = String(attachment.fileName.dropFirst(FakeUnlockedCrypto.fileNamePrefix.count))
        let size = attachment.contents.count - FakeUnlockedCrypto.fileContentsPrefix.count
        let stored = damagesNextUpload ? attachment.contents + Data([0]) : attachment.contents
        damagesNextUpload = false
        attachments[itemID, default: []].append((ItemAttachment(id: "attachment-\(attachmentCount)", fileName: name,
                                                               sizeName: "\(size) Bytes"), stored))
        account.contents.items[index].attachmentCount += 1
        return "attachment-\(attachmentCount)"
    }

    public func attachmentContents(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws -> Data {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let file = attachments[itemID]?.first(where: { $0.info.id == attachmentID }) else { throw EngineError.notFound }
        return file.contents
    }

    public func deleteAttachment(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws {
        try takeFailure()
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        guard let index = account.contents.items.firstIndex(where: { $0.id == itemID }),
              attachments[itemID]?.contains(where: { $0.info.id == attachmentID }) == true else {
            throw EngineError.server("HTTP 400: Attachment doesn't exist")
        }
        attachments[itemID]?.removeAll { $0.info.id == attachmentID }
        account.contents.items[index].attachmentCount -= 1
    }

    private var syncFailure: EngineError?

    /// The next sync fails with this error; other requests go through.
    public func failNextSync(_ error: EngineError) {
        syncFailure = error
    }

    public func sync(server: URL, accessToken: String) async throws -> Data {
        try takeFailure()
        if let syncFailure {
            self.syncFailure = nil
            throw syncFailure
        }
        guard accessToken == self.accessToken else { throw EngineError.sessionExpired }
        syncCount += 1
        if holdsSync {
            holdsSync = false
            await withCheckedContinuation { continuation in
                syncGate = continuation
                for waiter in syncGateWaiters { waiter.resume() }
                syncGateWaiters = []
            }
        }
        // The list as `VaultContents` writes it, with the saved forms beside it.
        guard var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account.contents)) as? [String: Any] else {
            throw EngineError.unexpected("The fake vault is not writable.")
        }
        payload[FakeUnlockedCrypto.savedKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        payload[FakeUnlockedCrypto.attachmentsKey] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(attachments.mapValues { $0.map(\.info) }))
        payload[FakeUnlockedCrypto.sendsKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sendContents))
        payload[FakeUnlockedCrypto.importedKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(importedCredentials))
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: Cryptography

/// The fake request that gives an item to an organization.
public struct FakeShare: Codable, Sendable, Equatable {
    public var itemID: String
    public var organizationID: String
    public var collectionIDs: [String]

    public init(itemID: String, organizationID: String, collectionIDs: [String]) {
        self.itemID = itemID
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
    }
}

public struct FakeCrypto: CryptoPort {
    static let wrappedKeyPrefix = "fake-wrapped:"
    private let authenticationDelay: Duration
    /// A slow synthetic device for interaction checks. Production never uses this adapter.
    public init(authenticationDelay: Duration = .zero) { self.authenticationDelay = authenticationDelay }

    static func hash(password: String, salt: String) -> String {
        "fake-hash:\(salt):\(password)"
    }

    public func serverPasswordHash(password: String, prelogin: Prelogin) async throws -> String {
        try await Task.sleep(for: authenticationDelay)
        return Self.hash(password: password, salt: prelogin.salt)
    }

    public func unlock(_ request: UnlockRequest) async throws -> any UnlockedCrypto {
        try await Task.sleep(for: authenticationDelay)
        let expected = Self.wrappedKeyPrefix + Self.hash(password: request.masterPassword, salt: request.material.salt)
        guard request.material.masterKeyWrappedUserKey == expected else { throw EngineError.wrongMasterPassword }
        return FakeUnlockedCrypto(userKey: Self.userKey(of: request.material), authenticationDelay: authenticationDelay)
    }

    /// The fake user key of an account names the wrapped key it would come out of.
    static let userKeyPrefix = "fake-user-key:"

    static func userKey(of material: AccountCryptoMaterial) -> String {
        userKeyPrefix + material.masterKeyWrappedUserKey
    }

    public func unlock(_ request: KeyUnlockRequest) async throws -> any UnlockedCrypto {
        try await Task.sleep(for: authenticationDelay)
        guard request.userKey == Self.userKey(of: request.material) else { throw EngineError.biometrics(.keyRejected) }
        return FakeUnlockedCrypto(userKey: request.userKey, authenticationDelay: authenticationDelay)
    }

    /// The fake envelope names the PIN it was made with.
    static let envelopePrefix = "fake-pin-envelope:"
    static let encryptedPinPrefix = "fake-encrypted-pin:"

    public func unlock(_ request: PinUnlockRequest) async throws -> any UnlockedCrypto {
        try await Task.sleep(for: authenticationDelay)
        guard request.envelope == Self.envelopePrefix + request.pin else { throw EngineError.wrongPin }
        return FakeUnlockedCrypto(userKey: Self.userKey(of: request.material), authenticationDelay: authenticationDelay)
    }

    /// Nothing random: a value that shows what was asked for.
    public func generate(_ request: GeneratorRequest) async throws -> String {
        switch request {
        case .password(let options):
            let alphabet = (options.uppercase ? "A" : "") + (options.lowercase ? "b" : "") + (options.numbers ? "3" : "")
                + (options.special ? "#" : "")
            return String(repeating: alphabet, count: options.length).prefix(options.length).description
        case .passphrase(let options):
            let word = options.capitalize ? "Fake" : "fake"
            return Array(repeating: word, count: options.words).joined(separator: options.separator) + (options.includeNumber ? "7" : "")
        case .username(let options, let website):
            switch options.kind {
            case .randomWord: return (options.capitalize ? "Fakeword" : "fakeword") + (options.includeNumber ? "7" : "")
            case .plusAddressedEmail:
                guard let at = options.email.firstIndex(of: "@") else { throw EngineError.invalidState }
                return options.email[..<at] + "+fake" + options.email[at...]
            case .catchallEmail:
                guard !options.domain.isEmpty else { throw EngineError.invalidState }
                return (website ?? "fake") + "@" + options.domain
            }
        }
    }

    public func newSSHKey() async throws -> SSHKeyContent {
        SSHKeyContent(privateKey: "fake-new-private-key", publicKey: "ssh-ed25519 fake-new-public-key", fingerprint: "SHA256:fake-new")
    }

    /// A fake key text is "fake-ssh-key:" and a name, or "fake-encrypted-ssh-key:", its password,
    /// a colon and a name.
    public func importSSHKey(_ text: String, password: String?) async throws -> SSHKeyContent {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name: String
        switch parts.first {
        case "fake-ssh-key" where parts.count == 2:
            name = parts[1]
        case "fake-encrypted-ssh-key" where parts.count == 3:
            guard let password else { throw EngineError.sshKeyImport(.passwordRequired) }
            guard password == parts[1] else { throw EngineError.sshKeyImport(.wrongPassword) }
            name = parts[2]
        case "fake-dsa-key":
            throw EngineError.sshKeyImport(.unsupportedKind)
        default:
            throw EngineError.sshKeyImport(.notAKey)
        }
        return SSHKeyContent(privateKey: "fake-private-key-" + name, publicKey: "ssh-ed25519 fake-public-key-" + name,
                             fingerprint: "SHA256:fake-" + name)
    }
}

/// It makes up the fields of an item from what the list knows: every value starts with "fake-".
/// An item that was saved through a form has the content of that form.
actor FakeUnlockedCrypto: UnlockedCrypto {
    private let key: String
    private let authenticationDelay: Duration

    init(userKey: String, authenticationDelay: Duration = .zero) {
        key = userKey
        self.authenticationDelay = authenticationDelay
    }

    func userKey() async throws -> String {
        try await Task.sleep(for: authenticationDelay)
        return key
    }

    static let savedKey = "savedForms"
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var contents = VaultContents.empty
    private var saved: [String: ItemDraft] = [:]
    static let importedKey = "importedCredentials"
    private var importedCredentials: [String: VaultImport.Item] = [:]

    static let attachmentsKey = "attachmentLists"
    static let fileNamePrefix = "fake-encrypted-file:"
    static let fileContentsPrefix = Data("fake-encrypted-contents:".utf8)
    private var attachments: [String: [ItemAttachment]] = [:]

    static let sendsKey = "sendContents"
    private var sends: [String: VaultSend] = [:]

    private struct SavedForms: Decodable {
        var savedForms: [String: ItemDraft]?
        var attachmentLists: [String: [ItemAttachment]]?
        var sendContents: [String: VaultSend]?
        var importedCredentials: [String: VaultImport.Item]?
    }

    static func sshBlob(of itemID: String) -> Data { Data("fake-ssh-blob-\(itemID)".utf8) }

    func sshIdentities() async -> [SSHAgentIdentity] {
        contents.items.filter { $0.type == .sshKey && !$0.isInTrash && !$0.isArchived }
            .map { SSHAgentIdentity(itemID: $0.id, name: $0.name, publicKeyBlob: Self.sshBlob(of: $0.id),
                                   publicKeyFingerprint: "SHA256:synthetic-" + $0.id) }
    }

    func sshSignature(itemID: String, publicKeyBlob: Data, data: Data, flags: UInt32) async throws -> Data {
        guard contents.items.contains(where: { $0.id == itemID && $0.type == .sshKey }), publicKeyBlob == Self.sshBlob(of: itemID) else {
            throw EngineError.notFound
        }
        return Data("fake-signature:\(itemID):".utf8) + data
    }

    /// A Send that was saved through a form has the content of that form; another one has a
    /// made-up text or file. The summary is the one of the list.
    func send(id: String) async throws -> VaultSend {
        guard let summary = contents.sends.first(where: { $0.id == id }) else { throw EngineError.notFound }
        if var send = sends[id] {
            send.summary = summary
            return send
        }
        return VaultSend(summary: summary, text: summary.type == .text ? "fake-text-of-" + summary.name : nil,
                         fileName: summary.type == .file ? "fake-file-of-" + summary.name + ".txt" : nil,
                         fileSizeName: summary.type == .file ? "12 Bytes" : nil,
                         linkPath: "fake-access-\(id)/fake-key-\(id)")
    }

    /// The fake request is the draft itself, without the content of its file.
    func encryptSend(_ draft: SendDraft) async throws -> EncryptedSend {
        if let id = draft.id, !contents.sends.contains(where: { $0.id == id }) { throw EngineError.notFound }
        var request = draft
        request.file = nil
        let file = draft.file.map {
            EncryptedSendFile(fileName: Self.fileNamePrefix + $0.name, contents: Self.fileContentsPrefix + $0.data)
        }
        do {
            return EncryptedSend(request: try JSONEncoder().encode(request), file: file)
        } catch {
            throw EngineError.unexpected("The fake Send is not writable.")
        }
    }

    func encryptAttachment(itemID: String, fileName: String, data: Data) async throws -> EncryptedAttachment {
        guard contents.items.contains(where: { $0.id == itemID }) else { throw EngineError.notFound }
        return EncryptedAttachment(key: "fake-attachment-key", fileName: Self.fileNamePrefix + fileName,
                                   contents: Self.fileContentsPrefix + data)
    }

    func decryptAttachment(itemID: String, attachmentID: String, contents: Data) async throws -> Data {
        guard attachments[itemID]?.contains(where: { $0.id == attachmentID }) == true else { throw EngineError.notFound }
        guard contents.starts(with: Self.fileContentsPrefix) else { throw EngineError.unexpected("The fake file is not readable.") }
        return contents.dropFirst(Self.fileContentsPrefix.count)
    }

    func decryptVault(syncPayload: Data) async throws -> VaultContents {
        do {
            contents = try JSONDecoder().decode(VaultContents.self, from: syncPayload)
            let extras = try? JSONDecoder().decode(SavedForms.self, from: syncPayload)
            saved = extras?.savedForms ?? [:]
            attachments = extras?.attachmentLists ?? [:]
            sends = extras?.sendContents ?? [:]
            importedCredentials = extras?.importedCredentials ?? [:]
            for index in contents.items.indices {
                guard let passkeys = importedCredentials[contents.items[index].id]?.passkeys else { continue }
                // Fake IDs are readable strings, as the fake authenticator's IDs are.
                contents.items[index].passkeys = passkeys.map {
                    VaultPasskey(credentialID: Data($0.credentialId.utf8), rpID: $0.rpId,
                                 userName: $0.userName ?? "", userHandle: Data(($0.userHandle ?? "").utf8))
                }
            }
            return contents
        } catch {
            throw EngineError.unexpected("The fake vault payload is not readable.")
        }
    }

    func draft(id: String) async throws -> ItemDraft {
        if contents.items.first(where: { $0.id == id })?.isUndecryptable == true { throw EngineError.itemNotWritable }
        if let draft = saved[id] { return draft }
        let item = try await item(id: id)
        let content: ItemDraft.Content = switch item.content {
        case .login(let login):
            .login(ItemDraft.Login(username: login.username ?? "", password: login.password ?? "",
                                   verificationKey: login.hasVerificationCode ? "fake-verification-key" : "",
                                   websites: login.websites.map { ItemDraft.Website(address: $0) },
                                   passkeyCreated: login.passkeyCreated))
        case .card(let card): .card(card)
        case .identity(let identity): .identity(identity)
        case .secureNote: .secureNote
        case .sshKey(let key): .sshKey(key)
        }
        return ItemDraft(id: id, revised: item.revised, name: item.name, folderID: item.folderID, isFavorite: item.isFavorite,
                         asksForMasterPassword: item.asksForMasterPassword, notes: item.notes ?? "", content: content,
                         customFields: item.customFields)
    }

    /// The fake encryption of a history entry: a mark before its JSON.
    static let generatedPrefix = Data("fake-encrypted-generated:".utf8)

    func encryptGenerated(_ value: GeneratedValue) async throws -> Data {
        Self.generatedPrefix + (try JSONEncoder().encode(value))
    }

    func decryptGenerated(_ entries: [Data]) async throws -> [GeneratedValue?] {
        entries.map { entry in
            guard entry.starts(with: Self.generatedPrefix) else { return nil }
            return try? JSONDecoder().decode(GeneratedValue.self, from: entry.dropFirst(Self.generatedPrefix.count))
        }
    }

    /// The demo mail login has one earlier password.
    func passwordHistory(id: String) async throws -> [PasswordHistoryEntry] {
        guard contents.items.contains(where: { $0.id == id }) else { throw EngineError.notFound }
        if let history = importedCredentials[id]?.passwordHistory { return history }
        return id == "item-1" ? [PasswordHistoryEntry(password: "fake-old-password-item-1", lastUsed: Self.date)] : []
    }

    static let folderNamePrefix = "fake-encrypted-folder:"

    func encryptShare(itemID: String, organizationID: String, collectionIDs: [String]) async throws -> Data {
        guard let item = contents.items.first(where: { $0.id == itemID }) else { throw EngineError.notFound }
        guard !item.isUndecryptable, item.organizationID == nil else { throw EngineError.itemNotWritable }
        return try JSONEncoder().encode(FakeShare(itemID: itemID, organizationID: organizationID, collectionIDs: collectionIDs))
    }

    func encryptFolderName(_ name: String) async throws -> String {
        Self.folderNamePrefix + name
    }

    /// The fake request is the draft itself.
    func encrypt(_ draft: ItemDraft) async throws -> Data {
        if let id = draft.id, !contents.items.contains(where: { $0.id == id }) { throw EngineError.notFound }
        do {
            return try JSONEncoder().encode(draft)
        } catch {
            throw EngineError.unexpected("The fake draft is not writable.")
        }
    }

    private func item(of draft: ItemDraft, summary: VaultItemSummary) -> VaultItem {
        let content: ItemContent = switch draft.content {
        case .login(let login):
            .login(LoginContent(username: login.username.isEmpty ? nil : login.username,
                                password: login.password.isEmpty ? nil : login.password,
                                hasVerificationCode: !login.verificationKey.isEmpty, websites: login.websites.map(\.address),
                                passkeyCreated: summary.passkeys.isEmpty ? nil : Self.date))
        case .card(let card): .card(card)
        case .identity(let identity): .identity(identity)
        case .secureNote: .secureNote
        case .sshKey(let key): .sshKey(key)
        }
        return VaultItem(id: summary.id, name: draft.name, notes: draft.notes.isEmpty ? nil : draft.notes,
                         isFavorite: summary.isFavorite, folderID: summary.folderID, isInTrash: summary.isInTrash,
                         isArchived: summary.isArchived, asksForMasterPassword: draft.asksForMasterPassword, content: content,
                         customFields: draft.customFields, created: Self.date, revised: Self.date,
                         attachments: attachments[summary.id] ?? [])
    }

    func enrollPin(_ pin: String) async throws -> PinEnrollment {
        try await Task.sleep(for: authenticationDelay)
        return PinEnrollment(envelope: FakeCrypto.envelopePrefix + pin, encryptedPin: FakeCrypto.encryptedPinPrefix + pin)
    }

    // MARK: Passkeys

    /// What the fake authenticator adds to the request for the server: the passkey it made.
    struct MadePasskey: Codable {
        var fakePasskey: VaultPasskey?
    }

    static let signaturePrefix = Data("fake-signature:".utf8)
    static let verifiedData = Data("fake-authenticator-data:verified".utf8)
    static let presentData = Data("fake-authenticator-data:present".utf8)
    private var madePasskeys = 0

    /// The fake signature is the hash it was asked to sign behind a mark, and the authenticator
    /// data say only whether the user was verified.
    func passkeyAssertion(_ request: PasskeyAssertionRequest) async throws -> PasskeySigned {
        guard let item = contents.items.first(where: { $0.id == request.itemID }),
              let passkey = item.passkeys.first(where: { passkey in
                  passkey.rpID == request.rpID
                      && (request.allowedCredentialIDs.isEmpty || request.allowedCredentialIDs.contains(passkey.credentialID))
              }) else { throw EngineError.notFound }
        return PasskeySigned(assertion: PasskeyAssertion(
            rpID: request.rpID, credentialID: passkey.credentialID, userHandle: passkey.userHandle,
            authenticatorData: request.isUserVerified ? Self.verifiedData : Self.presentData,
            signature: Self.signaturePrefix + request.clientDataHash))
    }

    func makePasskey(_ request: PasskeyRegistrationRequest, newLoginName: String) async throws -> PasskeyMade {
        let existing = contents.items.flatMap(\.passkeys).map(\.credentialID)
        if request.excludedCredentialIDs.contains(where: existing.contains) { throw EngineError.passkeyExists }
        var draft: ItemDraft
        if let itemID = request.itemID {
            draft = try await self.draft(id: itemID)
            guard case .login(var login) = draft.content else { throw EngineError.itemNotWritable }
            login.passkeyCreated = Self.date
            draft.content = .login(login)
        } else {
            draft = ItemDraft(new: .login)
            draft.name = newLoginName
            draft.content = .login(ItemDraft.Login(username: request.userName, websites: [.init(address: "https://" + request.rpID)],
                                                   passkeyCreated: Self.date))
        }
        madePasskeys += 1
        let passkey = VaultPasskey(credentialID: Data("fake-credential-\(madePasskeys)".utf8), rpID: request.rpID,
                                   userName: request.userName, userHandle: request.userHandle)
        // The fake request is the draft with the passkey beside its fields.
        guard var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any] else {
            throw EngineError.unexpected("The fake draft is not writable.")
        }
        fields["fakePasskey"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(passkey))
        let registration = PasskeyRegistration(rpID: request.rpID, credentialID: passkey.credentialID,
                                               attestationObject: Data("fake-attestation:".utf8) + passkey.credentialID)
        return PasskeyMade(registration: registration,
                           save: PasskeySave(itemID: request.itemID, request: try JSONSerialization.data(withJSONObject: fields)))
    }

    func enrollPin(encryptedPin: String) async throws -> PinEnrollment {
        guard encryptedPin.hasPrefix(FakeCrypto.encryptedPinPrefix) else {
            throw EngineError.unexpected("The fake encrypted PIN is not readable.")
        }
        return PinEnrollment(envelope: FakeCrypto.envelopePrefix + encryptedPin.dropFirst(FakeCrypto.encryptedPinPrefix.count),
                             encryptedPin: encryptedPin)
    }

    func item(id: String) async throws -> VaultItem {
        guard let summary = contents.items.first(where: { $0.id == id }) else { throw EngineError.notFound }
        if summary.isUndecryptable { throw EngineError.itemNotReadable }
        if let draft = saved[id] { return item(of: draft, summary: summary) }
        let has = summary.fields.contains
        let content: ItemContent
        switch summary.type {
        case .login:
            content = .login(LoginContent(
                username: has(.username) ? summary.subtitle : nil, password: has(.password) ? "fake-password-\(id)" : nil,
                hasVerificationCode: has(.verificationCode), websites: has(.website) ? ["https://\(id).example"] : [],
                passkeyCreated: summary.passkeys.isEmpty ? nil : Self.date))
        case .card:
            content = .card(CardContent(cardholderName: "Fake Person", brand: summary.cardBrand, number: "4242424242424242",
                                        expirationMonth: "12", expirationYear: "2030", securityCode: "123"))
        case .identity:
            var identity = IdentityContent()
            identity.firstName = "Fake"
            identity.lastName = "Person"
            identity.email = "fake.person@example.com"
            content = .identity(identity)
        case .secureNote:
            content = .secureNote
        case .sshKey:
            content = .sshKey(SSHKeyContent(privateKey: "fake-private-key", publicKey: "fake-public-key", fingerprint: "SHA256:fake"))
        }
        return VaultItem(id: id, name: summary.name, notes: summary.type == .secureNote ? "A fake note." : nil,
                         isFavorite: summary.isFavorite, folderID: summary.folderID, isInTrash: summary.isInTrash,
                         isArchived: summary.isArchived, asksForMasterPassword: summary.asksForMasterPassword,
                         content: content, created: Self.date, revised: Self.date,
                         passwordHistoryCount: id == "item-1" ? 1 : 0, attachments: attachments[id] ?? [])
    }

    func verificationCode(itemID: String, at time: Date) async throws -> VerificationCode {
        guard contents.items.first(where: { $0.id == itemID })?.fields.contains(.verificationCode) == true else {
            throw EngineError.notFound
        }
        return VerificationCode(code: "123456", period: 30)
    }

    func isMasterPassword(_ password: String, material: AccountCryptoMaterial) async -> Bool {
        material.masterKeyWrappedUserKey == FakeCrypto.wrappedKeyPrefix + FakeCrypto.hash(password: password, salt: material.salt)
    }

    func fingerprintPhrase(userID: String) async throws -> [String] {
        ["fake", "phrase", "of", "five", "words"]
    }

    /// The fake export: a line that names the format, then the names of the items of the user
    /// that are not in the trash.
    func exportVault(format: VaultExportFormat) async throws -> Data {
        let mark = switch format {
        case .json: "fake-export:json"
        case .csv: "fake-export:csv"
        case .encryptedJson(let password): "fake-export:encrypted:" + password
        }
        let names = contents.items.filter { !$0.isInTrash }.map(\.name)
        return Data(([mark] + names).joined(separator: "\n").utf8)
    }

    /// The fake request of an import is the file itself.
    func encryptImport(_ file: VaultImport) async throws -> Data {
        try JSONEncoder().encode(file)
    }
}

// MARK: Clipboard

public actor FakeClipboard: ClipboardPort {
    public private(set) var text: String?
    public private(set) var wasSensitive = false

    public init() {}

    public func copy(_ text: String, isSensitive: Bool) async {
        self.text = text
        wasSensitive = isSensitive
    }

    public func clear(ifStill text: String) async {
        if self.text == text { self.text = nil }
    }

    public private(set) var readCount = 0

    public func read() async -> String? {
        readCount += 1
        return text
    }
}

// MARK: Storage

public actor InMemoryAccountStore: AccountStorePort {
    public private(set) var stored: StoredAccount?
    /// The saved settings by account identifier.
    public private(set) var settings: [String: EngineSettings]
    private var failsNextSettingsSave = false
    private let device: String

    public init(stored: StoredAccount? = nil, settings: [String: EngineSettings] = [:], pins: [String: StoredPin] = [:],
                deviceIdentifier: String = UUID().uuidString.lowercased()) {
        self.stored = stored
        self.settings = settings
        self.pins = pins
        device = deviceIdentifier
    }

    /// The next save of settings fails like a full disk.
    public func failNextSettingsSave() { failsNextSettingsSave = true }

    private var accountIsUnreadable = false
    private var settingsAreUnreadable = false

    /// The stored account, or the stored settings, are damaged files from now on.
    public func makeUnreadable(account: Bool = false, settings: Bool = false) {
        accountIsUnreadable = account
        settingsAreUnreadable = settings
    }

    public func deviceIdentifier() async throws -> String { device }

    public func load() async throws -> StoredAccount? {
        if accountIsUnreadable { throw EngineError.storage("The stored file account.json is not readable.") }
        return stored
    }
    private var logoutID: String?
    public func pendingLogout() async throws -> String? { logoutID }
    public func setPendingLogout(_ accountID: String?) async throws { logoutID = accountID }
    public func save(_ account: StoredAccount) async throws { stored = account }
    public func clear() async throws {
        stored = nil
        generatorHistory = []
    }

    /// The accounts that wait beside the stored one, each with its history of the generator.
    public private(set) var parked: [(account: StoredAccount, generatorHistory: [Data])] = []

    public func parkedAccounts() async throws -> [Account] { parked.map(\.account.account) }

    public func park() async throws {
        guard let stored else { return }
        parked.removeAll { $0.account.account.id == stored.account.id }
        parked.insert((stored, generatorHistory), at: 0)
        self.stored = nil
        generatorHistory = []
    }

    public func unpark(accountID: String) async throws {
        guard stored == nil, let index = parked.firstIndex(where: { $0.account.account.id == accountID }) else {
            throw EngineError.storage("The account that was put aside is not there.")
        }
        let entry = parked.remove(at: index)
        stored = entry.account
        generatorHistory = entry.generatorHistory
    }

    public func removeParked(accountID: String) async throws {
        parked.removeAll { $0.account.account.id == accountID }
    }

    /// The stored history of the generator, as the crypto port has encrypted it.
    public private(set) var generatorHistory: [Data] = []

    public func loadGeneratorHistory() async throws -> [Data] { generatorHistory }
    public func saveGeneratorHistory(_ entries: [Data]) async throws { generatorHistory = entries }
    public func loadSettings(accountID: String) async throws -> EngineSettings? {
        if settingsAreUnreadable { throw EngineError.storage("The stored file settings.json is not readable.") }
        return settings[accountID]
    }

    /// The PINs by account identifier.
    public private(set) var pins: [String: StoredPin]
    private var failsNextPinSave = false

    /// The next save of a PIN fails like a locked Keychain.
    public func failNextPinSave() { failsNextPinSave = true }

    public func loadPin(accountID: String) async throws -> StoredPin? { pins[accountID] }

    public func savePin(_ pin: StoredPin?, accountID: String) async throws {
        if failsNextPinSave {
            failsNextPinSave = false
            throw EngineError.storage("The PIN could not be saved.")
        }
        pins[accountID] = pin
    }

    /// The remembered devices by server and email.
    public private(set) var rememberTokens: [String: String] = [:]

    public func twoStepRememberToken(server: URL, email: String) async throws -> String? {
        rememberTokens[server.absoluteString + "|" + email.lowercased()]
    }

    public func saveTwoStepRememberToken(_ token: String?, server: URL, email: String) async throws {
        rememberTokens[server.absoluteString + "|" + email.lowercased()] = token
    }

    public func saveSettings(_ settings: EngineSettings, accountID: String) async throws {
        if failsNextSettingsSave {
            failsNextSettingsSave = false
            throw EngineError.storage("The settings could not be saved.")
        }
        self.settings[accountID] = settings
    }
}

// MARK: System events

/// System events that a test, or nothing at all, sends.
public final class ManualSystemEvents: SystemEventsPort, Sendable {
    private let stream: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: SystemEvent.self)
    }

    /// One consumer only: the engine.
    public func events() -> AsyncStream<SystemEvent> { stream }

    public func send(_ event: SystemEvent) {
        continuation.yield(event)
    }
}
