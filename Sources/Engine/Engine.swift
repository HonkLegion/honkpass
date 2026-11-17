import Foundation
import VaultModel

/// The one owner of the session, the keys and the decrypted vault.
///
/// It starts with the process and does not know whether any window exists. The main window, the
/// menu bar and later the AutoFill host are clients: they read `states()` and send commands.
/// All values that cross this API are `Sendable` and `Codable`, so the same calls can cross XPC.
public actor Engine {
    private let ports: EnginePorts
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    private var current = EngineState.initial
    private var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var stored: StoredAccount? {
        // The name of the account follows its access token, whichever way the token changes.
        didSet {
            let name = stored.flatMap { AccessTokenClaims.name(in: $0.accessToken) }
            if name != current.accountName { update { $0.accountName = name } }
        }
    }
    private var crypto: (any UnlockedCrypto)?
    /// Changes when a lock or logout interrupts the command in progress.
    private var epoch = 0
    /// Metadata issued by the active-field port, never supplied by a client for remembering an app.
    private var capturedFillTarget: (target: FillTarget, epoch: Int)?
    /// Session persistence that does not occupy the vault command slot.
    private var sessionChanges = 0
    private var timerGeneration = 0
    private var inactivityTimer: Task<Void, Never>?
    /// The PIN of the logged-in account as it is stored, and the envelope that opens the vault.
    /// A PIN that asks for the master password after a restart has its envelope here only.
    private var storedPin: StoredPin?
    private var pinEnvelope: String?
    /// The Mac can ask for Touch ID, and the Keychain keeps the key of the account.
    private var biometricsAvailable = false
    private var biometricKeyKept = false
    /// The system is asking the user for Touch ID.
    private var isAskingForBiometrics = false
    /// After this many wrong PINs in a row the account is logged out, as in the reference.
    static let pinAttemptLimit = 5
    /// The shortest PIN that can be set, as in the reference.
    public static let minimumPinLength = 4
    private var pendingLogin: PendingLogin?
    private var pendingLoginGeneration = 0
    private var pendingLoginTimer: Task<Void, Never>?
    /// How long a log-in waits for its second step.
    static let twoStepPatience: Duration = .seconds(300)
    private var clipboardTimer: Task<Void, Never>?
    /// Pictures of websites by host; nil for a host the server has no picture for.
    private var websiteIcons: [String: Data?] = [:]
    private var accountAvatars: [String: Data?] = [:]
    private var systemEvents: Task<Void, Never>?
    private var isStarted = false
    /// What the generator has made for the unlocked account, the newest first, with the
    /// encrypted form of each value that the store keeps. A lock drops it from memory.
    private var generated: [(value: GeneratedValue, stored: Data)] = []
    private var hasLoadedGenerated = false
    /// How many values the history of the generator keeps, as in the reference.
    static let generatorHistoryLimit = 200
    /// The commands that wait until no other command is in progress.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The keys the SSH agent offers. A lock leaves them, as the reference does, so that an SSH
    /// client can name a key whose vault it then asks to unlock; they hold no private part.
    private var sshIdentityList: [SSHAgentIdentity] = []
    private var isSSHAgentRunning = false
    private var isApplyingSSHAgent = false
    /// Under "remember until vault is locked": for each key, where its use was allowed.
    private var sshAuthorized: Set<SSHAuthorization> = []
    private var sshAuthorizationGeneration = 0
    /// The questions that wait for the user, the one on screen first, and their askers.
    private var sshApprovals: [SSHApproval] = []
    private var sshApprovalWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// The SSH clients that wait for the vault to be unlocked.
    private var sshUnlockWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var sshUnlockRequests: [SSHUnlockRequest] = []
    private var sshActiveRequests: Set<UUID> = []
    private var sshCancelledRequests: Set<UUID> = []
    static let sshApprovalPatience: Duration = .seconds(60)
    /// How long an SSH client waits for the unlock, as in the reference.
    static let sshUnlockPatience: Duration = .seconds(60)

    /// - Parameter notices: what the composition root has to tell the user, such as a store
    ///   that could not be opened.
    public init(ports: EnginePorts, clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = { Date() }, notices: [EngineNotice] = []) {
        self.ports = ports
        self.clock = clock
        self.now = now
        current.notices = notices
    }

    deinit {
        clipboardTimer?.cancel()
        inactivityTimer?.cancel()
        pendingLoginTimer?.cancel()
        systemEvents?.cancel()
        for observer in observers.values { observer.finish() }
    }

    // MARK: State

    public var state: EngineState { current }

    /// The current state, then every change. Each caller gets its own stream.
    public func states() -> AsyncStream<EngineState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: EngineState.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(current)
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func update(_ change: (inout EngineState) -> Void) {
        var next = current
        change(&next)
        // A locked session must not publish an approval left over from the unlocked vault.
        if current.session.isUnlocked, !next.session.isUnlocked { next.sshApproval = nil }
        guard next != current else { return }
        let before = current
        current = next
        for observer in observers.values { observer.yield(next) }
        noteIdentities(before: before, after: next)
        noteSSHAgent(before: before, after: next)
        if next.activity == nil, !idleWaiters.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    // MARK: AutoFill of the system

    /// What the store of the system has to hold next. nil inside is "nothing at all".
    private var identitiesToStore: [AutoFillIdentity]??
    private var isStoringIdentities = false

    /// The AutoFill of the system follows the vault, as `sync` of the reference's
    /// desktop-autofill.service.ts: while the vault is unlocked its logins are the entries of
    /// the store, a logout removes them all, and a lock leaves them, so that the system can
    /// offer a login whose vault it then asks to unlock.
    private func noteIdentities(before: EngineState, after: EngineState) {
        if case .loggedOut = after.session {
            if before.session != .loggedOut { store(identities: nil) }
        } else if after.session.isUnlocked {
            let wanted = after.vault.autoFillIdentities
            if !before.session.isUnlocked || before.vault.autoFillIdentities != wanted { store(identities: wanted) }
        }
    }

    /// Answers a question of the AutoFill extension. The answer is all the extension learns:
    /// a locked vault tells it nothing of its items, a login that asks for the master
    /// password keeps its password, and a wrong PIN counts as one typed in the window.
    public func autoFill(_ request: AutoFillRequest) async -> AutoFillResponse {
        switch request {
        case .status:
            // A sensor comes and goes with a keyboard: a locked vault looks again before it
            // says how it can be opened.
            if case .locked = current.session { await refreshBiometrics() }
            return .status(autoFillStatus)
        case .unlockWithTouchID(let reason):
            do {
                try await unlockWithBiometrics(reason: reason)
                return .status(autoFillStatus)
            } catch EngineError.biometrics(.cancelled), EngineError.cancelled, EngineError.busy {
                // The user closed the question, the vault was opened another way meanwhile, or
                // another window asks already: the state of the vault is the answer.
                return .status(autoFillStatus)
            } catch {
                return current.session.isUnlocked ? .status(autoFillStatus) : .failure(.touchIDFailed)
            }
        case .storeIdentities:
            if current.session.isUnlocked { store(identities: current.vault.autoFillIdentities) }
            return .status(autoFillStatus)
        case .unlock(let pin):
            do {
                try await unlock(pin: pin)
                return .status(autoFillStatus)
            } catch EngineError.wrongPin {
                return .failure(.wrongPin)
            } catch {
                return .failure(current.session.isUnlocked ? .unavailable : .pinUnavailable)
            }
        case .logins(let services):
            guard let refusal = autoFillRefusal else {
                let vault = current.vault
                // Every login that can be filled when the system names no website; else the
                // logins of the websites it names, by the rules that match a website to a page.
                var found = services.isEmpty ? vault.items(in: .type(.login)) : []
                for service in services {
                    for item in vault.logins(ofPage: service) where !found.contains(where: { $0.id == item.id }) {
                        found.append(item)
                    }
                }
                return .logins(found
                    .filter { !$0.isUndecryptable && $0.fields.contains(.password) }
                    .map { AutoFillLogin(itemID: $0.id, name: $0.name, username: $0.subtitle,
                                         asksForMasterPassword: $0.asksForMasterPassword) })
            }
            return .failure(refusal)
        case .password(let itemID):
            if let refusal = autoFillRefusal { return .failure(refusal) }
            guard let listed = current.vault.items.first(where: { $0.id == itemID }), listed.type == .login,
                  !listed.isInTrash, !listed.isUndecryptable else { return .failure(.notFound) }
            guard !listed.asksForMasterPassword else { return .failure(.masterPasswordRequired) }
            guard let item = try? await item(id: itemID), let password = item.value(of: .password) else {
                return .failure(current.session.isUnlocked ? .notFound : .locked)
            }
            // A lock while the item was read must not let its password out.
            guard current.session.isUnlocked else { return .failure(.locked) }
            return .password(AutoFillPassword(username: item.value(of: .username) ?? "", password: password))
        case .verificationCode(let itemID):
            if let refusal = autoFillRefusal { return .failure(refusal) }
            guard let listed = current.vault.items.first(where: { $0.id == itemID }), listed.type == .login,
                  !listed.isInTrash, !listed.isUndecryptable, listed.fields.contains(.verificationCode) else {
                return .failure(.notFound)
            }
            guard !listed.asksForMasterPassword else { return .failure(.masterPasswordRequired) }
            guard let code = try? await verificationCode(for: itemID) else {
                return .failure(current.session.isUnlocked ? .notFound : .locked)
            }
            guard current.session.isUnlocked else { return .failure(.locked) }
            return .verificationCode(code.code)
        case .passkeys(let rpID, let allowed):
            if let refusal = autoFillRefusal { return .failure(refusal) }
            return .passkeys(passkeyLogins.flatMap { item in
                item.passkeys.filter { $0.rpID == rpID && (allowed.isEmpty || allowed.contains($0.credentialID)) }.map {
                    AutoFillPasskey(itemID: item.id, credentialID: $0.credentialID, name: item.name,
                                    username: $0.userName.isEmpty ? item.subtitle : $0.userName,
                                    asksForMasterPassword: item.asksForMasterPassword)
                }
            })
        case .passkeyAssertion(let request):
            return await passkeyAssertion(request)
        case .passkeyTargets(let rpID, let userHandle):
            if let refusal = autoFillRefusal { return .failure(refusal) }
            // The rule of the reference (`computeMatchingLogins`): a login of the website, or one
            // with a passkey of this relying party, that has no passkey of another user.
            let ofWebsite = Set(current.vault.logins(ofPage: "https://" + rpID).map(\.id))
            return .logins(passkeyLogins.filter { item in
                (ofWebsite.contains(item.id) || item.passkeys.contains { $0.rpID == rpID })
                    && item.passkeys.allSatisfy { $0.userHandle == userHandle }
            }.map {
                AutoFillLogin(itemID: $0.id, name: $0.name, username: $0.subtitle,
                              asksForMasterPassword: $0.asksForMasterPassword, hasPasskey: !$0.passkeys.isEmpty)
            })
        case .registerPasskey(let request):
            return await registerPasskey(request)
        }
    }

    /// The logins a passkey can be used from or saved to: not deleted, not archived, readable.
    private var passkeyLogins: [VaultItemSummary] {
        current.vault.items.filter { $0.type == .login && !$0.isInTrash && !$0.isArchived && !$0.isUndecryptable }
    }

    private func passkeyAssertion(_ request: PasskeyAssertionRequest) async -> AutoFillResponse {
        await whenIdle()
        if let refusal = autoFillRefusal { return .failure(refusal) }
        guard case .unlocked(let account) = current.session, let crypto,
              let item = passkeyLogins.first(where: { $0.id == request.itemID }),
              item.passkeys.contains(where: { $0.rpID == request.rpID }) else { return .failure(.notFound) }
        guard !item.asksForMasterPassword else { return .failure(.masterPasswordRequired) }
        guard request.userVerification != .required || request.isUserVerified else { return .failure(.userNotVerified) }
        do {
            let signed = try await crypto.passkeyAssertion(request)
            // A lock while the SDK signed must not let the signature out.
            guard current.session.isUnlocked else { return .failure(.locked) }
            if let save = signed.save {
                // The login changed with its use. The signature is good with or without the write.
                _ = try? await write(account: account) { accessToken in
                    try await ports.server.save(request: save.request, itemID: save.itemID, server: account.serverURL,
                                                accessToken: accessToken)
                }
            }
            return .passkeyAssertion(signed.assertion)
        } catch EngineError.notFound {
            return .failure(.notFound)
        } catch {
            return .failure(current.session.isUnlocked ? .unavailable : .locked)
        }
    }

    private func registerPasskey(_ request: PasskeyRegistrationRequest) async -> AutoFillResponse {
        await whenIdle()
        if let refusal = autoFillRefusal { return .failure(refusal) }
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else { return .failure(.unavailable) }
        if let itemID = request.itemID {
            guard let item = passkeyLogins.first(where: { $0.id == itemID }) else { return .failure(.notFound) }
            guard !item.asksForMasterPassword else { return .failure(.masterPasswordRequired) }
        }
        guard request.userVerification != .required || request.isUserVerified else { return .failure(.userNotVerified) }
        do {
            // The new login has the name of the relying party, as in the reference (`createCipher`).
            let made = try await crypto.makePasskey(request, newLoginName: request.rpID)
            guard current.session.isUnlocked else { return .failure(.locked) }
            // The website gets the passkey only when the server has it.
            _ = try await write(account: account) { accessToken in
                try await ports.server.save(request: made.save.request, itemID: made.save.itemID, server: account.serverURL,
                                            accessToken: accessToken)
            }
            return .passkeyRegistration(made.registration)
        } catch EngineError.passkeyExists {
            return .failure(.passkeyExists)
        } catch EngineError.notFound {
            return .failure(.notFound)
        } catch {
            return .failure(current.session.isUnlocked ? .unavailable : .locked)
        }
    }

    private var autoFillStatus: AutoFillStatus {
        switch current.session {
        case .loggedOut: AutoFillStatus(vault: .loggedOut)
        case .locked(let account):
            AutoFillStatus(vault: .locked, canUnlockWithPin: current.pin.canUnlock,
                           canUnlockWithTouchID: current.biometrics.canUnlock,
                           asksForTouchIDAtOnce: current.settings.asksForBiometricsOnStart, account: account.email)
        case .unlocked(let account): AutoFillStatus(vault: .unlocked, account: account.email)
        }
    }

    /// Why the vault gives nothing out now. nil while it is unlocked.
    private var autoFillRefusal: AutoFillFailure? {
        switch current.session {
        case .loggedOut: .loggedOut
        case .locked: .locked
        case .unlocked: nil
        }
    }

    /// Stores the newest list; a list that waits behind a slower write is replaced by it.
    private func store(identities: [AutoFillIdentity]?) {
        identitiesToStore = .some(identities)
        guard !isStoringIdentities else { return }
        isStoringIdentities = true
        Task { await storeIdentities() }
    }

    private func storeIdentities() async {
        while let next = identitiesToStore {
            identitiesToStore = nil
            if let next {
                // Nothing is stored before the user has turned PassVault on in the system.
                if await ports.identities.isEnabled() { await ports.identities.replace(with: next) }
            } else {
                await ports.identities.removeAll()
            }
        }
        isStoringIdentities = false
    }

    /// Returns when no command is in progress. A change of an item waits here for the sync
    /// that follows an unlock, instead of being refused as busy.
    private func whenIdle() async {
        while current.activity != nil {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    // MARK: Commands

    /// Loads the stored account and starts to listen for system events. Later calls do nothing.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        let events = ports.systemEvents.events()
        systemEvents = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        // What cannot be read is not thrown away: the engine goes on without it and says so.
        var found: [EngineNotice] = []
        do {
            stored = try await ports.store.load()
        } catch {
            stored = nil
            found.append(.storedAccountUnreadable)
        }
        // The accounts that wait beside it. The app may have ended at the log-in of one more
        // account: then the first of them is the account again.
        var others = (try? await ports.store.parkedAccounts()) ?? []
        if stored == nil, !found.contains(.storedAccountUnreadable), let first = others.first,
           (try? await ports.store.unpark(accountID: first.id)) != nil {
            stored = try? await ports.store.load()
            if stored != nil { others.removeFirst() }
        }
        var settings = EngineSettings.default
        if let id = stored?.account.id {
            do {
                settings = try await ports.store.loadSettings(accountID: id) ?? .default
                storedPin = try await ports.store.loadPin(accountID: id)
            } catch {
                found.append(.storedSettingsUnreadable)
            }
            pinEnvelope = storedPin?.envelope
            biometricKeyKept = await ports.biometrics.hasKey(accountID: id)
        }
        biometricsAvailable = await ports.biometrics.isAvailable()
        update { state in
            state.activity = nil
            state.settings = settings
            state.pin = pinState
            state.biometrics = biometricState
            state.otherAccounts = others
            if let stored { state.session = .locked(stored.account) }
            for notice in found where !state.notices.contains(notice) { state.notices.append(notice) }
        }
    }

    // MARK: More than one account

    /// The most accounts that are logged in at once, as in the reference.
    public static let accountLimit = 5

    /// "Add account": puts the account aside, locked, and shows the log-in for another one.
    /// The account waits in `otherAccounts`. At the limit of accounts nothing happens (`invalidState`).
    public func addAccount() async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard current.activity != .starting, current.session.account != nil,
              current.otherAccounts.count + 1 < Engine.accountLimit else { throw EngineError.invalidState }
        await whenIdle()
        try await parkAccount()
    }

    /// Makes one of the other accounts the account. The one that was it waits in its place,
    /// locked: only one account has its keys in memory. The new one is locked until the user
    /// unlocks it.
    public func switchAccount(to id: String) async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard current.activity != .starting, current.otherAccounts.contains(where: { $0.id == id }) else {
            throw EngineError.notFound
        }
        await whenIdle()
        if current.session.account != nil { try await parkAccount() }
        try await activateAccount(id)
    }

    /// Locks the account and puts it aside in the store. The session is "logged out" after it,
    /// with the account in `otherAccounts`.
    private func parkAccount() async throws {
        guard let account = current.session.account else { return }
        interrupt()
        do {
            try await ports.store.park()
        } catch {
            // The account stays where it is, locked.
            update { state in
                state.session = .locked(account)
                state.vault = .empty
                state.activity = nil
            }
            throw EngineError(error)
        }
        stored = nil
        storedPin = nil
        pinEnvelope = nil
        // The key of the account stays in the Keychain: it waits with the account.
        biometricKeyKept = false
        websiteIcons = [:]
        update { state in
            state.session = .loggedOut
            state.vault = .empty
            state.activity = nil
            state.settings = .default
            state.pin = .none
            state.biometrics = biometricState
            // "Most recently active first" (default-account-switcher.service.ts).
            state.otherAccounts.insert(account, at: 0)
        }
    }

    private func activateAccount(_ id: String) async throws {
        guard case .loggedOut = current.session, stored == nil else { throw EngineError.invalidState }
        forgetPendingLogin()
        do {
            try await ports.store.unpark(accountID: id)
            guard let record = try await ports.store.load(), record.account.id == id else {
                throw EngineError.storage("The account that was put aside is not readable.")
            }
            let settings = await savedSettings(of: id)
            let pin = try? await ports.store.loadPin(accountID: id)
            let hasBiometricKey = await ports.biometrics.hasKey(accountID: id)
            // A log-in that began meanwhile has the session; the account waits on.
            guard case .loggedOut = current.session, stored == nil else { throw EngineError.cancelled }
            stored = record
            storedPin = pin
            pinEnvelope = pin?.envelope
            biometricKeyKept = hasBiometricKey
            update { state in
                state.session = .locked(record.account)
                state.settings = settings
                state.pin = pinState
                state.biometrics = biometricState
                state.twoStep = nil
                state.otherAccounts.removeAll { $0.id == id }
            }
        } catch {
            throw EngineError(error)
        }
    }

    private var biometricState: BiometricState {
        BiometricState(isAvailable: biometricsAvailable, isEnabled: biometricKeyKept)
    }

    private var pinState: PinState {
        guard let storedPin else { return .none }
        return PinState(isSet: true, asksForMasterPasswordAfterRestart: storedPin.envelope == nil, canUnlock: pinEnvelope != nil)
    }

    /// The settings of an account that has just logged in. Unreadable ones are reported.
    private func savedSettings(of accountID: String) async -> EngineSettings {
        do {
            return try await ports.store.loadSettings(accountID: accountID) ?? .default
        } catch {
            note(.storedSettingsUnreadable)
            return .default
        }
    }

    private func note(_ notice: EngineNotice) {
        update { if !$0.notices.contains(notice) { $0.notices.append(notice) } }
    }

    /// A client has shown the notice to the user.
    public func dismiss(_ notice: EngineNotice) {
        update { $0.notices.removeAll { $0 == notice } }
    }

    /// Logs in with the master password. For an account with two-step login it throws
    /// `twoStepLoginRequired` and waits: `state.twoStep` says how the second step can be given,
    /// and `submitTwoStepCode` finishes the log-in. A token of an earlier "remember me" is tried first.
    public func logIn(server: URL, email: String, masterPassword: String) async throws {
        guard case .loggedOut = current.session else { throw EngineError.invalidState }
        // A new attempt replaces one that waits for its second step.
        forgetPendingLogin()
        let token = try begin(.loggingIn)
        defer { finish(token) }
        update { $0.authenticationPhase = .authenticating }
        do {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let prelogin = try await ports.server.prelogin(server: server, email: email)
            let hash = try await ports.crypto.serverPasswordHash(password: masterPassword, prelogin: prelogin)
            let device = try await ports.store.deviceIdentifier()
            let remembered = (try? await ports.store.twoStepRememberToken(server: server, email: email)).flatMap { $0 }
            try check(token)
            let pending = PendingLogin(server: server, email: email, masterPassword: masterPassword, passwordHash: hash,
                                       prelogin: prelogin, deviceIdentifier: device)
            let proof = remembered.map { TwoStepProof(kind: .rememberedDevice, token: $0, remember: false) }
            let outcome = try await ports.server.logIn(pending.request(twoStep: proof))
            try check(token)
            switch outcome {
            case .granted(let grant):
                try await complete(grant, pending, token: token)
            case .needsTwoStep(let challenge):
                // The server no longer accepts the remembered token.
                if remembered != nil { try? await ports.store.saveTwoStepRememberToken(nil, server: server, email: email) }
                try check(token)
                guard !challenge.methods.isEmpty else { throw EngineError.twoStepMethodsUnsupported }
                pendingLogin = pending
                update { $0.twoStep = challenge }
                startPendingLoginTimer()
                throw EngineError.twoStepLoginRequired
            }
        } catch {
            throw EngineError(error)
        }
    }

    /// The second step of the waiting log-in. A code the server does not accept throws
    /// `invalidTwoStepCode` and the log-in keeps waiting. With `rememberDevice` the server gives a
    /// token that replaces the second step on this installation for a while.
    public func submitTwoStepCode(_ code: String, method: TwoStepMethod, rememberDevice: Bool) async throws {
        guard case .loggedOut = current.session, let pending = pendingLogin,
              current.twoStep?.methods.contains(method) == true else { throw EngineError.invalidState }
        // Authenticator apps and mails show codes with spaces in them. The answer of a security
        // key goes to the server as it is.
        let code = method == .webAuthn ? code : code.filter { !$0.isWhitespace }
        guard !code.isEmpty else { throw EngineError.invalidTwoStepCode }
        let token = try begin(.loggingIn)
        defer { finish(token) }
        do {
            let proof = TwoStepProof(kind: .method(method), token: code, remember: rememberDevice)
            let outcome = try await ports.server.logIn(pending.request(twoStep: proof))
            try check(token)
            switch outcome {
            case .granted(let grant):
                if rememberDevice, let rememberToken = grant.twoStepRememberToken {
                    // Without the token the user is asked again next time; the log-in itself is good.
                    try? await ports.store.saveTwoStepRememberToken(rememberToken, server: pending.server, email: pending.email)
                }
                try await complete(grant, pending, token: token)
            case .needsTwoStep(let challenge):
                // The server asks again instead of naming the code as wrong.
                if !challenge.methods.isEmpty { update { $0.twoStep = challenge } }
                throw EngineError.invalidTwoStepCode
            }
        } catch {
            throw EngineError(error)
        }
    }

    /// Asks the server to send a code for the waiting log-in to the address of the account.
    public func sendTwoStepEmail() async throws {
        guard let pending = pendingLogin, current.twoStep?.methods.contains(.email) == true else {
            throw EngineError.invalidState
        }
        do {
            try await ports.server.sendTwoStepEmail(pending.request(twoStep: nil))
        } catch {
            throw EngineError(error)
        }
    }

    /// Gives up the log-in that waits for its second step.
    public func cancelTwoStepLogin() {
        guard pendingLogin != nil || current.twoStep != nil else { return }
        interrupt()
        update { $0.activity = nil }
    }

    /// What a log-in needs again for its second step. It holds the master password, so it lives
    /// only until the log-in ends, is cancelled or has waited too long.
    private struct PendingLogin {
        let server: URL
        let email: String
        let masterPassword: String
        let passwordHash: String
        let prelogin: Prelogin
        let deviceIdentifier: String

        func request(twoStep: TwoStepProof?) -> LoginRequest {
            LoginRequest(server: server, email: email, passwordHash: passwordHash, prelogin: prelogin,
                         deviceIdentifier: deviceIdentifier, twoStep: twoStep)
        }
    }

    /// The server has granted the log-in: opens the keys, fetches the vault and stores the account.
    private func complete(_ grant: LoginGrant, _ login: PendingLogin, token: Int) async throws {
        try check(token)
        update { $0.activity = .loadingVault }
        let unlocked = try await ports.crypto.unlock(UnlockRequest(
            userID: grant.userID, email: login.email, material: grant.crypto, masterPassword: login.masterPassword))
        try authenticationPhase(.syncing, token: token)
        let payload = try await ports.server.sync(server: login.server, accessToken: grant.accessToken)
        try authenticationPhase(.loadingVault, token: token)
        var contents = try await unlocked.decryptVault(syncPayload: payload)
        try check(token)
        try authenticationPhase(.saving, token: token)

        let syncDate = now()
        let record = StoredAccount(
            account: Account(id: grant.userID, email: login.email, serverURL: login.server), crypto: grant.crypto,
            accessToken: grant.accessToken, refreshToken: grant.refreshToken,
            accessTokenExpiry: syncDate.addingTimeInterval(grant.expiresIn), vaultPayload: payload, lastSync: syncDate)
        // An account that waits beside this log-in and is the same one is replaced by it.
        if current.otherAccounts.contains(where: { $0.id == grant.userID }) {
            try await ports.store.removeParked(accountID: grant.userID)
        }
        try await ports.store.save(record)
        let settings = await savedSettings(of: grant.userID)
        let pin = try? await ports.store.loadPin(accountID: grant.userID)
        let hasBiometricKey = await ports.biometrics.hasKey(accountID: grant.userID)
        try check(token)

        contents.lastSync = syncDate
        stored = record
        crypto = unlocked
        storedPin = pin
        pinEnvelope = pin?.envelope
        biometricKeyKept = hasBiometricKey
        forgetPendingLogin(publish: false)
        update { state in
            state.twoStep = nil
            state.session = .unlocked(record.account)
            state.vault = contents
            state.settings = settings
            state.pin = pinState
            state.biometrics = biometricState
            state.otherAccounts.removeAll { $0.id == grant.userID }
        }
        restartInactivityTimer()
    }

    private func forgetPendingLogin(publish: Bool = true) {
        pendingLogin = nil
        pendingLoginGeneration += 1
        pendingLoginTimer?.cancel()
        pendingLoginTimer = nil
        if publish { update { $0.twoStep = nil } }
    }

    /// A log-in that waits for its second step is given up after a while, so that the master
    /// password does not stay in memory behind an abandoned window.
    private func startPendingLoginTimer() {
        pendingLoginGeneration += 1
        pendingLoginTimer?.cancel()
        let generation = pendingLoginGeneration
        let clock = self.clock
        pendingLoginTimer = Task { [weak self] in
            do { try await clock.sleep(for: Engine.twoStepPatience) } catch { return }
            await self?.pendingLoginTimerFired(generation)
        }
    }

    private func pendingLoginTimerFired(_ generation: Int) {
        guard generation == pendingLoginGeneration, pendingLogin != nil else { return }
        // A second step that is being sent right now may still finish.
        forgetPendingLogin()
    }

    /// Opens the locked vault from the stored copy. It does not contact the server.
    public func unlock(masterPassword: String) async throws {
        guard case .locked(let account) = current.session, let stored else { throw EngineError.invalidState }
        let token = try begin(.unlocking)
        defer { finish(token) }
        do {
            let unlocked = try await ports.crypto.unlock(UnlockRequest(
                userID: account.id, email: account.email, material: stored.crypto, masterPassword: masterPassword))
            var contents = VaultContents.empty
            if let payload = stored.vaultPayload {
                try authenticationPhase(.loadingVault, token: token)
                contents = try await unlocked.decryptVault(syncPayload: payload)
            }
            // A PIN that waited for the master password works again from now on.
            var envelope = pinEnvelope
            if envelope == nil, let storedPin {
                try authenticationPhase(.preparingPin, token: token)
                envelope = try? await unlocked.enrollPin(encryptedPin: storedPin.encryptedPin).envelope
            }
            await forgetWrongPins(accountID: account.id)
            try check(token)
            finishUnlock(unlocked, contents: contents, account: account, lastSync: stored.lastSync, envelope: envelope)
        } catch {
            throw EngineError(error)
        }
        // The stored copy is on screen at once; the server's version follows when it answers.
        Task { [weak self] in try? await self?.sync() }
    }

    /// Opens the locked vault with the PIN, from the stored copy. A wrong PIN is counted; at the
    /// limit the account is logged out and the command throws `tooManyPinAttempts`.
    public func unlock(pin: String) async throws {
        guard case .locked(let account) = current.session, let stored, let storedPin, let envelope = pinEnvelope else {
            throw EngineError.invalidState
        }
        let token = try begin(.unlocking)
        defer { finish(token) }
        do {
            let unlocked: any UnlockedCrypto
            do {
                unlocked = try await ports.crypto.unlock(PinUnlockRequest(
                    userID: account.id, email: account.email, material: stored.crypto, pin: pin, envelope: envelope))
            } catch EngineError.wrongPin {
                try check(token)
                var counted = storedPin
                counted.failedAttempts += 1
                if counted.failedAttempts >= Engine.pinAttemptLimit {
                    try? await logOut()
                    throw EngineError.tooManyPinAttempts
                }
                self.storedPin = counted
                // An attempt that cannot be counted must not be free: the PIN stops working instead.
                do {
                    try await ports.store.savePin(counted, accountID: account.id)
                } catch {
                    pinEnvelope = nil
                    update { $0.pin = pinState }
                }
                throw EngineError.wrongPin
            }
            var contents = VaultContents.empty
            if let payload = stored.vaultPayload {
                try authenticationPhase(.loadingVault, token: token)
                contents = try await unlocked.decryptVault(syncPayload: payload)
            }
            await forgetWrongPins(accountID: account.id)
            try check(token)
            finishUnlock(unlocked, contents: contents, account: account, lastSync: stored.lastSync, envelope: envelope)
        } catch {
            throw EngineError(error)
        }
        Task { [weak self] in try? await self?.sync() }
    }

    /// A successful unlock starts the count of wrong PINs again. It runs before the unlock is
    /// checked a last time, so that a logout meanwhile still removes the PIN after it.
    private func forgetWrongPins(accountID: String) async {
        guard var counted = storedPin, counted.failedAttempts > 0 else { return }
        counted.failedAttempts = 0
        storedPin = counted
        try? await ports.store.savePin(counted, accountID: accountID)
    }

    private func finishUnlock(_ unlocked: any UnlockedCrypto, contents: VaultContents, account: Account, lastSync: Date?,
                              envelope: String?) {
        var contents = contents
        contents.lastSync = lastSync
        crypto = unlocked
        pinEnvelope = envelope
        update { state in
            state.session = .unlocked(account)
            state.vault = contents
            state.pin = pinState
        }
        restartInactivityTimer()
    }

    /// Sets the PIN of the unlocked account, or replaces it. With `asksForMasterPasswordAfterRestart`
    /// nothing that opens the vault is stored: after a restart the master password comes first.
    public func setPin(_ pin: String, asksForMasterPasswordAfterRestart: Bool) async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard case .unlocked(let account) = current.session, let crypto else { throw EngineError.invalidState }
        guard pin.count >= Engine.minimumPinLength else { throw EngineError.wrongPin }
        do {
            let enrollment = try await crypto.enrollPin(pin)
            let record = StoredPin(envelope: asksForMasterPasswordAfterRestart ? nil : enrollment.envelope,
                                   encryptedPin: enrollment.encryptedPin)
            try await ports.store.savePin(record, accountID: account.id)
            guard current.session.account?.id == account.id else { throw EngineError.cancelled }
            storedPin = record
            pinEnvelope = enrollment.envelope
            update { $0.pin = pinState }
        } catch {
            throw EngineError(error)
        }
    }

    public func removePin() async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard let account = current.session.account else { throw EngineError.invalidState }
        do {
            try await ports.store.savePin(nil, accountID: account.id)
        } catch {
            throw EngineError(error)
        }
        guard current.session.account?.id == account.id else { return }
        storedPin = nil
        pinEnvelope = nil
        update { $0.pin = .none }
    }

    // MARK: Touch ID

    /// Looks again whether the Mac can ask for Touch ID and whether the key of the account is
    /// kept. A client calls it where it shows the answer: a sensor comes and goes with a
    /// keyboard and with the lid of the Mac, and the engine is not told of it.
    public func refreshBiometrics() async {
        let accountID = current.session.account?.id
        let isAvailable = await ports.biometrics.isAvailable()
        var isKept = false
        if let accountID { isKept = await ports.biometrics.hasKey(accountID: accountID) }
        // The account may have changed while the system was asked.
        guard current.session.account?.id == accountID else { return }
        biometricsAvailable = isAvailable
        biometricKeyKept = isKept
        if current.biometrics != biometricState { update { $0.biometrics = biometricState } }
    }

    /// Turns the unlock with Touch ID on or off for the account. On, for the unlocked vault:
    /// the key that opens it goes from the SDK to the Keychain of the system, which keeps it
    /// behind Touch ID; no client sees it. Off: the key is removed. Throws
    /// `EngineError.biometrics`: `.unavailable` on a Mac that cannot ask for Touch ID now,
    /// `.failed` when the system did not keep the key.
    public func setBiometricUnlock(_ isOn: Bool) async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard let account = current.session.account else { throw EngineError.invalidState }
        do {
            if isOn {
                guard case .unlocked = current.session, let crypto else { throw EngineError.invalidState }
                guard await ports.biometrics.isAvailable() else { throw EngineError.biometrics(.unavailable) }
                let key = try await crypto.userKey()
                // A lock or a logout while the key was read must not let it out.
                guard case .unlocked(let now) = current.session, now.id == account.id else { throw EngineError.cancelled }
                try await ports.biometrics.keep(key, accountID: account.id)
            } else {
                try await ports.biometrics.remove(accountID: account.id)
            }
        } catch {
            await refreshBiometrics()
            throw EngineError(error)
        }
        await refreshBiometrics()
        // On only when the system says that it keeps the key.
        if isOn, current.session.account?.id == account.id, !current.biometrics.isEnabled {
            throw EngineError.biometrics(.failed)
        }
    }

    /// Opens the locked vault with the key the Keychain keeps behind Touch ID, from the stored
    /// copy. The system asks the user; `reason` is what its question says the app wants to do.
    /// The engine does not hold a command while a person answers: the master password and the
    /// PIN open the vault meanwhile, and then this command ends with `cancelled`. Throws
    /// `EngineError.biometrics`; after `.keyRejected` the key is removed.
    public func unlockWithBiometrics(reason: String) async throws {
        guard !current.isPreparingAppUpdate else { throw EngineError.busy }
        guard case .locked(let account) = current.session, stored != nil else { throw EngineError.invalidState }
        guard biometricKeyKept else { throw EngineError.biometrics(.notEnabled) }
        guard !isAskingForBiometrics else { throw EngineError.busy }
        isAskingForBiometrics = true
        defer { isAskingForBiometrics = false }
        let key: String
        do {
            key = try await ports.biometrics.key(accountID: account.id, reason: reason)
        } catch {
            // A key that is gone, or a sensor that is, is no way to unlock any more.
            await refreshBiometrics()
            throw EngineError(error)
        }
        // The vault was opened another way meanwhile, or the account is another one.
        guard case .locked(let now) = current.session, now.id == account.id, let stored else { throw EngineError.cancelled }
        let token = try begin(.unlocking)
        defer { finish(token) }
        do {
            let unlocked: any UnlockedCrypto
            do {
                unlocked = try await ports.crypto.unlock(KeyUnlockRequest(
                    userID: account.id, email: account.email, material: stored.crypto, userKey: key))
            } catch EngineError.biometrics(.keyRejected) {
                // The keys of the account were changed elsewhere: the kept key opens nothing.
                try? await ports.biometrics.remove(accountID: account.id)
                await refreshBiometrics()
                throw EngineError.biometrics(.keyRejected)
            }
            var contents = VaultContents.empty
            if let payload = stored.vaultPayload {
                try authenticationPhase(.loadingVault, token: token)
                contents = try await unlocked.decryptVault(syncPayload: payload)
            }
            // A PIN that waited for the master password works again, as after any unlock.
            var envelope = pinEnvelope
            if envelope == nil, let storedPin {
                try authenticationPhase(.preparingPin, token: token)
                envelope = try? await unlocked.enrollPin(encryptedPin: storedPin.encryptedPin).envelope
            }
            await forgetWrongPins(accountID: account.id)
            try check(token)
            finishUnlock(unlocked, contents: contents, account: account, lastSync: stored.lastSync, envelope: envelope)
        } catch {
            throw EngineError(error)
        }
        Task { [weak self] in try? await self?.sync() }
    }

    /// Fetches the vault from the server again. It renews the access token when needed.
    /// When the server has ended the session, the engine logs out and throws `sessionExpired`.
    public func sync() async throws {
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        let token = try begin(.syncing)
        defer { finish(token) }
        do {
            try await reload(account: account, token: token)
        } catch EngineError.sessionExpired {
            await sessionEnded(token)
            throw EngineError.sessionExpired
        } catch {
            throw EngineError(error)
        }
    }

    /// Fetches the vault, decrypts it, stores it and shows it.
    private func reload(account: Account, token: Int) async throws {
        guard let crypto else { throw EngineError.cancelled }
        let payload = try await withAccessToken(token: token) { accessToken in
            try await ports.server.sync(server: account.serverURL, accessToken: accessToken)
        }
        var contents = try await crypto.decryptVault(syncPayload: payload)
        try check(token)
        guard var record = stored else { throw EngineError.cancelled }
        record.vaultPayload = payload
        record.lastSync = now()
        try await ports.store.save(record)
        try check(token)
        contents.lastSync = record.lastSync
        stored = record
        update { $0.vault = contents }
        // The crypto port has the items of the server now; the list may have shown a change before it.
        if current.settings.sshAgent.isEnabled { await refreshSSHIdentities() }
    }

    /// The server has ended the session: the account is logged out and the user is told why.
    private func sessionEnded(_ token: Int) async {
        guard token == epoch else { return }
        try? await logOut()
        note(.sessionExpired)
    }

    /// Sends a request with the access token: with a new one when the old one is at its end, and
    /// once more when the server refuses a token that should still be good.
    private func withAccessToken<Answer: Sendable>(token: Int,
                                                   _ request: (String) async throws -> Answer) async throws -> Answer {
        guard var record = stored else { throw EngineError.cancelled }
        if record.accessToken.isEmpty || now() >= record.accessTokenExpiry.addingTimeInterval(-60) {
            record = try await renewTokens(record, token: token)
        }
        do {
            return try await request(record.accessToken)
        } catch EngineError.sessionExpired {
            record = try await renewTokens(record, token: token)
            return try await request(record.accessToken)
        }
    }

    private func renewTokens(_ record: StoredAccount, token: Int) async throws -> StoredAccount {
        guard let refreshToken = record.refreshToken else { throw EngineError.sessionExpired }
        let fresh = try await ports.server.refresh(server: record.account.serverURL, refreshToken: refreshToken)
        try check(token)
        var record = record
        record.accessToken = fresh.accessToken
        record.refreshToken = fresh.refreshToken ?? refreshToken
        record.accessTokenExpiry = now().addingTimeInterval(fresh.expiresIn)
        try await ports.store.save(record)
        try check(token)
        stored = record
        return record
    }

    // MARK: Items

    /// One item with all its fields. The vault must be unlocked.
    public func item(id: String) async throws -> VaultItem {
        guard current.session.isUnlocked, let crypto else { throw EngineError.invalidState }
        do {
            return try await crypto.item(id: id)
        } catch {
            throw EngineError(error)
        }
    }

    /// The current verification code of a login.
    public func verificationCode(for id: String) async throws -> VerificationCode {
        guard current.session.isUnlocked, let crypto else { throw EngineError.invalidState }
        do {
            return try await crypto.verificationCode(itemID: id, at: now())
        } catch {
            throw EngineError(error)
        }
    }

    /// Puts one field of an item on the clipboard. The value leaves the clipboard again after a while.
    public func copy(_ field: ItemField, of id: String) async throws {
        let value: String
        if field == .verificationCode {
            value = try await verificationCode(for: id).code
        } else {
            guard let text = try await item(id: id).value(of: field) else { throw EngineError.notFound }
            value = text
        }
        // A lock while the item was read must not leave its value behind.
        guard current.session.isUnlocked else { throw EngineError.cancelled }
        await place(value, isSensitive: !field.isPublic)
    }

    // MARK: Fill

    /// Whether the system lets PassVault fill the fields of other apps.
    public func isFillAllowed() async -> Bool {
        await ports.activeField.isAllowed()
    }

    /// Has the system ask the user for the permission to fill. A client calls it only after
    /// the user chose to fill.
    public func askForFillPermission() async {
        await ports.activeField.askToBeAllowed()
    }

    /// The field that has the cursor in the app the user works in, for `fill`. nil while the
    /// vault is locked, without the permission, and when there is no such field.
    public func fillTarget() async -> FillTarget? {
        guard current.session.isUnlocked else { return nil }
        let token = epoch
        let target = await ports.activeField.capture()
        guard token == epoch, current.session.isUnlocked else { return nil }
        capturedFillTarget = target.map { ($0, token) }
        return target
    }

    /// Puts one field of an item into a captured field. The value goes from the vault to the
    /// field and to no client. Nothing is written when the cursor has left that field.
    public func fill(_ field: ItemField, of id: String, into target: FillTarget) async throws {
        let token = epoch
        guard target.takesValue else { throw EngineError.fill(.noField) }
        let value: String
        if field == .verificationCode {
            value = try await verificationCode(for: id).code
        } else {
            guard let text = try await item(id: id).value(of: field) else { throw EngineError.notFound }
            value = text
        }
        // A lock while the item was read must not let its value out.
        try check(token)
        guard current.session.isUnlocked else { throw EngineError.cancelled }
        do {
            try await ports.activeField.write(value, to: target) {
                try await self.checkVaultSession(VaultSessionToken(epoch: token))
            }
        } catch {
            throw EngineError(error)
        }
    }

    /// Puts the user name and the password of a login into the two fields of a captured login
    /// form. Both go from the vault to the form and to no client. `fill(.noField)` for a
    /// target that is no login form, `notFound` for an item without both values.
    public func fillLogin(of id: String, into target: FillTarget) async throws {
        let token = epoch
        guard target.takesLogin else { throw EngineError.fill(.noField) }
        let item = try await item(id: id)
        guard let username = item.value(of: .username), !username.isEmpty,
              let password = item.value(of: .password), !password.isEmpty else { throw EngineError.notFound }
        let code: String?
        if target.takesVerificationCode, case .login(let login) = item.content, login.hasVerificationCode {
            code = try await verificationCode(for: id).code
        } else {
            code = nil
        }
        // A lock while the item was read must not let its values out.
        try check(token)
        guard current.session.isUnlocked else { throw EngineError.cancelled }
        do {
            try await ports.activeField.writeLogin(username: username, password: password, verificationCode: code, to: target) {
                try await self.checkVaultSession(VaultSessionToken(epoch: token))
            }
        } catch {
            throw EngineError(error)
        }
    }

    /// Adds a website to a login, after the websites it has: the page the user has just filled
    /// the login into and said to belong to it. A login that has the address already stays as
    /// it is. The address of an app is added as the form adds an app. Throws as `save` does,
    /// and `notFound` for an item that is no login.
    public func addWebsite(_ address: String, toLogin id: String, session: VaultSessionToken? = nil) async throws {
        let session = try session ?? vaultSession()
        var draft = try await draft(of: id)
        try checkVaultSession(session)
        guard case .login(var login) = draft.content else { throw EngineError.notFound }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !login.websites.contains(where: { $0.address == address }) else { return }
        login.websites.append(AppAddress(address).map { ItemDraft.Website(app: $0) } ?? ItemDraft.Website(address: address))
        draft.content = .login(login)
        _ = try await save(draft, session: session)
    }

    /// Remember only the exact signed application issued with this capture, after a successful
    /// write. A later persistence failure returns false and never retries the credential write.
    public func fillAndSaveApp(_ field: ItemField?, of id: String, into target: FillTarget) async throws -> Bool {
        let session = try vaultSession()
        guard let captured = capturedFillTarget, captured.epoch == epoch, captured.target == target,
              let app = target.app, target.website == nil, target.bundleID == app.bundleID,
              let item = current.vault.items.first(where: { $0.id == id }), item.type == .login,
              !item.isReadOnly, !item.isUndecryptable, !item.isInTrash, !item.isArchived else { throw EngineError.appNotAccepted }
        capturedFillTarget = nil
        if let field { try await fill(field, of: id, into: target) } else { try await fillLogin(of: id, into: target) }
        do {
            try checkVaultSession(session)
            try await addWebsite(app.address, toLogin: id, session: session)
            return true
        } catch {
            return false
        }
    }

    public func runningApps() async throws -> [RunningApp] {
        let session = try vaultSession()
        let apps = await ports.appSignatures.runningApps()
        try checkVaultSession(session)
        return apps
    }

    public func appAddress(ofRunningApp id: UUID) async throws -> AppAddress {
        let session = try vaultSession()
        let app = await ports.appSignatures.app(runningID: id)
        try checkVaultSession(session)
        guard let app, !app.isBrowser else { throw EngineError.appNotAccepted }
        return app.address
    }

    /// The address a login gets for an app of the disk that the user chose: the bundle
    /// identifier and the developer of its code signature. With it among its websites the login
    /// belongs to that app. Throws `EngineError.appNotAccepted` for what is no app, for an app
    /// without a valid signature of a developer, and for a browser. Nothing of the vault is
    /// read or changed; the form of the login takes the address.
    public func appAddress(ofAppAt location: URL) async throws -> AppAddress {
        let session = try vaultSession()
        let app = await ports.appSignatures.app(at: location)
        try checkVaultSession(session)
        guard let app, !app.isBrowser else { throw EngineError.appNotAccepted }
        return app.address
    }

    /// Puts a text on the clipboard that a client shows from an open item, under the same rules.
    /// For the fields of the item view that `ItemField` does not name.
    public func copy(text: String, isSensitive: Bool) async throws {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        await place(text, isSensitive: isSensitive)
    }

    private func place(_ value: String, isSensitive: Bool) async {
        await ports.clipboard.copy(value, isSensitive: isSensitive)
        clipboardTimer?.cancel()
        guard case .after(let seconds) = current.settings.clipboardClearing else { return }
        let clipboardLifetime = Duration.seconds(seconds)
        let clock = self.clock
        let clipboard = ports.clipboard
        clipboardTimer = Task {
            do { try await clock.sleep(for: clipboardLifetime) } catch { return }
            await clipboard.clear(ifStill: value)
        }
    }

    // MARK: Changes

    /// One write to the server, as the activity `saving`. `send` gets an access token the server
    /// takes; `show` changes the list at once after it. Then the vault is fetched again, so the
    /// clients see what the server has; when that cannot be done now, the write is done all the
    /// same and the next sync brings the rest. A write the server refuses is followed by a fetch
    /// too, which shows why: an item that another device has changed or deleted meanwhile.
    private func write<Answer: Sendable>(account: Account, _ send: (String) async throws -> Answer,
                                         show: (inout VaultContents, Answer) -> Void = { _, _ in }) async throws -> Answer {
        let token = try begin(.saving)
        defer { finish(token) }
        do {
            let answer: Answer
            do {
                answer = try await withAccessToken(token: token, send)
            } catch let error as EngineError {
                switch error {
                case .server, .itemChanged: try? await reload(account: account, token: token)
                default: break
                }
                throw error
            }
            try check(token)
            update { show(&$0.vault, answer) }
            do {
                try await reload(account: account, token: token)
            } catch EngineError.sessionExpired {
                throw EngineError.sessionExpired
            } catch EngineError.cancelled {
                throw EngineError.cancelled
            } catch {}
            return answer
        } catch EngineError.sessionExpired {
            await sessionEnded(token)
            throw EngineError.sessionExpired
        } catch {
            throw EngineError(error)
        }
    }

    /// Changes an item on the server and fetches the vault again. The server does the change
    /// itself; no content of the item is sent. A command in progress is waited for.
    ///
    /// Throws `notFound` for an unknown item and `invalidState` for a change that does not apply
    /// to the item as it is, such as restoring an item that is not in the trash.
    public func change(_ change: ItemChange, of id: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        guard let item = current.vault.items.first(where: { $0.id == id }) else { throw EngineError.notFound }
        guard item.allows(change) else { throw EngineError.invalidState }
        if case .moveToFolder(let folderID?) = change, !current.vault.folders.contains(where: { $0.id == folderID }) {
            throw EngineError.notFound
        }
        let itemWrite: ItemWrite = switch change {
        case .favorite(let isFavorite): .placement(isFavorite: isFavorite, folderID: item.folderID)
        case .moveToFolder(let folderID): .placement(isFavorite: item.isFavorite, folderID: folderID)
        case .archive: .archive
        case .unarchive: .unarchive
        case .moveToTrash: .moveToTrash
        case .restore: .restore
        case .deletePermanently: .deletePermanently
        }
        try await write(account: account) { accessToken in
            try await ports.server.write(itemWrite, itemID: id, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            vault.apply(change, to: id)
        }
    }

    /// The same change of several items, in one request to the server. Nothing is sent unless
    /// the change applies to every one of them; the favourite mark has no such request.
    public func change(_ change: ItemChange, ofItems ids: [String]) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { throw EngineError.invalidState }
        for id in ids {
            guard let item = current.vault.items.first(where: { $0.id == id }) else { throw EngineError.notFound }
            guard item.allows(change) else { throw EngineError.invalidState }
        }
        let bulkWrite: ItemBulkWrite
        switch change {
        case .favorite: throw EngineError.invalidState
        case .moveToFolder(let folderID):
            if let folderID, !current.vault.folders.contains(where: { $0.id == folderID }) { throw EngineError.notFound }
            bulkWrite = .moveToFolder(folderID)
        case .archive: bulkWrite = .archive
        case .unarchive: bulkWrite = .unarchive
        case .moveToTrash: bulkWrite = .moveToTrash
        case .restore: bulkWrite = .restore
        case .deletePermanently: bulkWrite = .deletePermanently
        }
        try await write(account: account) { accessToken in
            try await ports.server.write(bulkWrite, itemIDs: ids, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            for id in ids { vault.apply(change, to: id) }
        }
    }

    /// What the form of an item holds. Throws `itemNotWritable` for an item that PassVault could
    /// not write back whole, so its form never opens.
    public func draft(of id: String) async throws -> ItemDraft {
        guard current.session.isUnlocked, let crypto else { throw EngineError.invalidState }
        do {
            return try await crypto.draft(id: id)
        } catch {
            throw EngineError(error)
        }
    }

    /// Saves the form of an item: a new item for a draft without an identifier, else the change
    /// of the item it was made from. Returns the identifier of the item. The vault is fetched
    /// again after it. A command in progress is waited for.
    ///
    /// The crypto port refuses a draft whose item cannot be written back whole (`itemNotWritable`)
    /// or has changed since the draft was made (`itemChanged`); the server refuses a change of an
    /// item it has a newer copy of (`itemChanged`). An item needs a name (`invalidState`).
    @discardableResult
    public func save(_ draft: ItemDraft, session: VaultSessionToken? = nil) async throws -> String {
        let requestedEpoch = session?.epoch ?? epoch
        await whenIdle()
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.invalidState }
        var draft = draft
        if let id = draft.id {
            guard let item = current.vault.items.first(where: { $0.id == id }) else { throw EngineError.notFound }
            // The reference has no form for an item in the trash.
            guard !item.isInTrash, !item.isReadOnly else { throw EngineError.invalidState }
            // An item of the vault stays with its owner; "assign to collections" moves it.
            draft.organizationID = item.organizationID
            draft.collectionIDs = item.collectionIDs
        } else if let organizationID = draft.organizationID {
            try checkCollections(draft.collectionIDs, of: organizationID)
        } else {
            draft.collectionIDs = []
        }
        let isNewShared = draft.id == nil && draft.organizationID != nil
        // Encrypted once, also when the request is sent again with a new access token.
        var request: Data?
        return try await write(account: account) { [draft] accessToken in
            let body: Data
            if let request {
                body = request
            } else {
                body = try await crypto.encrypt(draft)
                request = body
            }
            if Task.isCancelled { throw EngineError.cancelled }
            try check(requestedEpoch)
            if isNewShared {
                return try await ports.server.share(request: body, itemID: nil, server: account.serverURL, accessToken: accessToken)
            }
            return try await ports.server.save(request: body, itemID: draft.id, server: account.serverURL, accessToken: accessToken)
        }
    }

    // MARK: Organizations

    /// An organization of the account, and collections of it that take an item: at least one.
    private func checkCollections(_ collectionIDs: [String], of organizationID: String) throws {
        guard current.vault.organizations.contains(where: { $0.id == organizationID }) else { throw EngineError.notFound }
        let open = Set(current.vault.assignableCollections(of: organizationID).map(\.id))
        guard !collectionIDs.isEmpty, Set(collectionIDs).count == collectionIDs.count, Set(collectionIDs).isSubset(of: open) else {
            throw EngineError.invalidState
        }
    }

    /// "Assign to collections": gives an item of the user to an organization and puts it into
    /// collections of it, or sets the collections of an item the organization has already.
    /// The SDK encrypts a moved item again under the key of the organization.
    ///
    /// An item of another organization does not move (`invalidState`); neither does one in the
    /// trash or one the user may not change.
    public func assign(itemID: String, toOrganization organizationID: String, collectionIDs: [String]) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard let item = current.vault.items.first(where: { $0.id == itemID }) else { throw EngineError.notFound }
        guard !item.isInTrash, !item.isReadOnly, !item.isUndecryptable,
              item.organizationID == nil || item.organizationID == organizationID else { throw EngineError.invalidState }
        try checkCollections(collectionIDs, of: organizationID)
        // The collections the user cannot change stay as they are.
        let closed = item.collectionIDs.filter { id in current.vault.collections.first { $0.id == id }?.isReadOnly != false }
        let wanted = collectionIDs + closed.filter { !collectionIDs.contains($0) }
        if item.organizationID != nil {
            try await write(account: account) { accessToken in
                try await ports.server.setCollections(wanted, itemID: itemID, server: account.serverURL, accessToken: accessToken)
            } show: { vault, _ in
                if let index = vault.items.firstIndex(where: { $0.id == itemID }) { vault.items[index].collectionIDs = wanted }
            }
            return
        }
        var request: Data?
        _ = try await write(account: account) { accessToken in
            let body: Data
            if let request {
                body = request
            } else {
                body = try await crypto.encryptShare(itemID: itemID, organizationID: organizationID, collectionIDs: collectionIDs)
                request = body
            }
            return try await ports.server.share(request: body, itemID: itemID, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            if let index = vault.items.firstIndex(where: { $0.id == itemID }) {
                vault.items[index].organizationID = organizationID
                vault.items[index].collectionIDs = collectionIDs
            }
        }
    }

    // MARK: Folders

    /// Adds a folder (`id` nil) or renames one. Returns the identifier of the folder. A folder
    /// needs a name (`invalidState`); an unknown folder is `notFound`.
    @discardableResult
    public func saveFolder(id: String? = nil, name: String) async throws -> String {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.invalidState }
        if let id, !current.vault.folders.contains(where: { $0.id == id }) { throw EngineError.notFound }
        var encryptedName: String?
        return try await write(account: account) { accessToken in
            let encrypted: String
            if let encryptedName {
                encrypted = encryptedName
            } else {
                encrypted = try await crypto.encryptFolderName(name)
                encryptedName = encrypted
            }
            return try await ports.server.saveFolder(id: id, encryptedName: encrypted, server: account.serverURL, accessToken: accessToken)
        } show: { vault, folderID in
            vault.folders.removeAll { $0.id == folderID }
            vault.folders.append(VaultFolder(id: folderID, name: name))
        }
    }

    /// Deletes a folder. Its items stay in the vault without a folder.
    public func deleteFolder(id: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        guard current.vault.folders.contains(where: { $0.id == id }) else { throw EngineError.notFound }
        try await write(account: account) { accessToken in
            try await ports.server.deleteFolder(id: id, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            vault.folders.removeAll { $0.id == id }
            for index in vault.items.indices where vault.items[index].folderID == id { vault.items[index].folderID = nil }
        }
    }

    /// The picture of a website, from the icon service of the account's server. The engine keeps
    /// it for the life of the process. nil when the server has none, and when the settings say
    /// that the server is not to be asked.
    public func websiteIcon(host: String) async -> Data? {
        guard current.settings.showsWebsiteIcons else { return nil }
        if let known = websiteIcons[host] { return known }
        guard let server = current.session.account?.serverURL, current.session.isUnlocked else { return nil }
        let icon = try? await ports.server.websiteIcon(server: server, host: host)
        websiteIcons[host] = .some(icon)
        return icon
    }

    // MARK: Attachments

    /// The largest file an item takes, as in the reference: 500 MB.
    public static let maximumAttachmentBytes = 500 * 1_024 * 1_024

    /// One file of an item with its content, decrypted. Nothing of it is kept by the engine.
    public func attachment(_ attachmentID: String, of itemID: String) async throws -> AttachmentFile {
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        // A download is no command of its own: a sync or a change may run beside it. A lock ends it.
        let token = epoch
        do {
            guard let listed = try await crypto.item(id: itemID).attachments.first(where: { $0.id == attachmentID }) else {
                throw EngineError.notFound
            }
            let contents = try await withAccessToken(token: token) { accessToken in
                try await ports.server.attachmentContents(itemID: itemID, attachmentID: attachmentID, server: account.serverURL,
                                                          accessToken: accessToken)
            }
            try check(token)
            let data = try await crypto.decryptAttachment(itemID: itemID, attachmentID: attachmentID, contents: contents)
            try check(token)
            return AttachmentFile(fileName: listed.fileName, data: data)
        } catch EngineError.sessionExpired {
            await sessionEnded(token)
            throw EngineError.sessionExpired
        } catch {
            throw EngineError(error)
        }
    }

    /// Adds a file to an item: the crypto port encrypts it, the server stores it. An item in the
    /// trash takes no file (`invalidState`); an empty or too large file is `attachmentTooLarge`.
    public func addAttachment(to itemID: String, fileName: String, data: Data, session: VaultSessionToken? = nil) async throws {
        let requestedEpoch = session?.epoch ?? epoch
        await whenIdle()
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard let item = current.vault.items.first(where: { $0.id == itemID }) else { throw EngineError.notFound }
        guard !item.isInTrash, !fileName.isEmpty else { throw EngineError.invalidState }
        guard !data.isEmpty, data.count <= Engine.maximumAttachmentBytes else { throw EngineError.attachmentTooLarge }
        var encrypted: EncryptedAttachment?
        // The reports of the server port come from the thread of its request; the stream keeps
        // them in their order, and the upload ends only after the last of them is shown.
        let (reports, reporter) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .unbounded)
        // `uploadProgress.set(0)` before the save: the bar is there from the start.
        update { $0.upload = AttachmentUpload(itemID: itemID, percent: 0) }
        let follower = Task { for await part in reports { uploadProgressed(part, of: itemID) } }
        do {
            try await write(account: account) { accessToken in
                let attachment: EncryptedAttachment
                if let encrypted {
                    attachment = encrypted
                } else {
                    attachment = try await crypto.encryptAttachment(itemID: itemID, fileName: fileName, data: data)
                    encrypted = attachment
                }
                if Task.isCancelled { throw EngineError.cancelled }
                try check(requestedEpoch)
                try await ports.server.addAttachment(attachment, itemID: itemID, server: account.serverURL,
                                                     accessToken: accessToken) { reporter.yield($0) }
            } show: { vault, _ in
                if let index = vault.items.firstIndex(where: { $0.id == itemID }) { vault.items[index].attachmentCount += 1 }
            }
        } catch {
            await endUpload(reporter, follower)
            throw error
        }
        await endUpload(reporter, follower)
    }

    /// A part of a file has gone: the per cent of `upload`, rounded as the reference rounds it.
    private func uploadProgressed(_ part: Double, of itemID: String) {
        guard current.upload?.itemID == itemID else { return }
        let percent = min(max(Int((part * 100).rounded()), 0), 100)
        update { $0.upload?.percent = percent }
    }

    /// `uploadProgress.set(null)` in the `finally` of the reference: after the last report.
    private func endUpload(_ reporter: AsyncStream<Double>.Continuation, _ follower: Task<Void, Never>) async {
        reporter.finish()
        await follower.value
        update { $0.upload = nil }
    }

    /// Gives a file of the old kind, which is encrypted with the key of its item, a key of its
    /// own, as "fix encryption" of the reference does: the file is read, stored again as a new
    /// attachment, and the old one is removed. The old one stays unless the server gives back
    /// the new one byte for byte as it was sent.
    public func repairAttachment(_ attachmentID: String, of itemID: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard let item = current.vault.items.first(where: { $0.id == itemID }) else { throw EngineError.notFound }
        guard let listed = try await crypto.item(id: itemID).attachments.first(where: { $0.id == attachmentID }) else {
            throw EngineError.notFound
        }
        guard !item.isInTrash, !listed.hasOwnKey else { throw EngineError.invalidState }
        let server = ports.server
        // A request that is sent again after a renewed token must not store the file twice.
        var sent: (attachment: EncryptedAttachment, id: String)?
        try await write(account: account) { accessToken in
            let new: (attachment: EncryptedAttachment, id: String)
            if let sent {
                new = sent
            } else {
                let old = try await server.attachmentContents(itemID: itemID, attachmentID: attachmentID,
                                                              server: account.serverURL, accessToken: accessToken)
                let data = try await crypto.decryptAttachment(itemID: itemID, attachmentID: attachmentID, contents: old)
                let attachment = try await crypto.encryptAttachment(itemID: itemID, fileName: listed.fileName, data: data)
                let id = try await server.addAttachment(attachment, itemID: itemID, server: account.serverURL,
                                                        accessToken: accessToken) { _ in }
                new = (attachment, id)
                sent = new
            }
            let kept = try await server.attachmentContents(itemID: itemID, attachmentID: new.id, server: account.serverURL,
                                                           accessToken: accessToken)
            guard kept == new.attachment.contents else {
                try? await server.deleteAttachment(itemID: itemID, attachmentID: new.id, server: account.serverURL,
                                                   accessToken: accessToken)
                throw EngineError.server("The server did not keep the new file as it was sent; the old one stays.")
            }
            try await server.deleteAttachment(itemID: itemID, attachmentID: attachmentID, server: account.serverURL,
                                              accessToken: accessToken)
        } show: { _, _ in }
    }

    public func deleteAttachment(_ attachmentID: String, of itemID: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        guard current.vault.items.contains(where: { $0.id == itemID }) else { throw EngineError.notFound }
        try await write(account: account) { accessToken in
            try await ports.server.deleteAttachment(itemID: itemID, attachmentID: attachmentID, server: account.serverURL,
                                                    accessToken: accessToken)
        } show: { vault, _ in
            if let index = vault.items.firstIndex(where: { $0.id == itemID }) {
                vault.items[index].attachmentCount = max(vault.items[index].attachmentCount - 1, 0)
            }
        }
    }

    // MARK: Generator

    /// A new password, passphrase or user name from the options, which are brought inside their
    /// limits first. The vault must be unlocked: the generator belongs to an account.
    public func generate(_ request: GeneratorRequest) async throws -> String {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        let normalized: GeneratorRequest = switch request {
        case .password(let options): .password(options.normalized)
        case .passphrase(let options): .passphrase(options.normalized)
        // The website counts only as its host, and only for the address that is made from it.
        case .username(let options, let website):
            .username(options, website: options.kind == .catchallEmail && options.catchallUsesWebsiteName
                ? UsernameOptions.hostname(ofWebsite: website) : nil)
        }
        let kind: GeneratorKind = switch request {
        case .password: .password
        case .passphrase: .passphrase
        case .username: .username
        }
        let token = epoch
        do {
            let value = try await ports.crypto.generate(normalized)
            // A lock meanwhile: nothing made for the closed vault is given out.
            try check(token)
            await remember(GeneratedValue(value: value, kind: kind, date: now()), token: token)
            try check(token)
            return value
        } catch {
            throw EngineError(error)
        }
    }

    /// The history of the generator: what it has made for this account, the newest first. It is
    /// kept encrypted with the account on this Mac and goes with it at a logout.
    public func generatorHistory() async throws -> [GeneratedValue] {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        let token = epoch
        await loadGenerated(token: token)
        try check(token)
        return generated.map(\.value)
    }

    public func clearGeneratorHistory() async throws {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        let token = epoch
        do {
            try await ports.store.saveGeneratorHistory([])
        } catch {
            throw EngineError(error)
        }
        try check(token)
        generated = []
        hasLoadedGenerated = true
    }

    /// Reads the stored history once after an unlock. What cannot be read is left out.
    private func loadGenerated(token: Int) async {
        guard !hasLoadedGenerated, let crypto else { return }
        let entries = (try? await ports.store.loadGeneratorHistory()) ?? []
        let values = (try? await crypto.decryptGenerated(entries)) ?? []
        guard token == epoch, !hasLoadedGenerated else { return }
        // What was made while the stored history was read comes first.
        let stored = zip(values, entries).compactMap { value, entry in value.map { (value: $0, stored: entry) } }
        generated += stored.filter { old in !generated.contains { $0.value.value == old.value.value } }
        hasLoadedGenerated = true
    }

    /// Adds a value to the history unless it is in it already, and stores the history. A history
    /// that cannot be stored is still there until the lock: the value itself was made.
    private func remember(_ value: GeneratedValue, token: Int) async {
        guard let crypto else { return }
        await loadGenerated(token: token)
        guard token == epoch, !generated.contains(where: { $0.value.value == value.value }),
              let stored = try? await crypto.encryptGenerated(value), token == epoch else { return }
        generated.insert((value, stored), at: 0)
        generated = Array(generated.prefix(Engine.generatorHistoryLimit))
        try? await ports.store.saveGeneratorHistory(generated.map(\.stored))
    }

    /// A new SSH key for the form of a new item.
    public func newSSHKey() async throws -> SSHKeyContent {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        do {
            let key = try await ports.crypto.newSSHKey()
            guard current.session.isUnlocked else { throw EngineError.cancelled }
            return key
        } catch {
            throw EngineError(error)
        }
    }

    /// The SSH key that is on the clipboard as a private key text, for the form of an SSH key.
    /// An encrypted key throws `sshKeyImport(.passwordRequired)`; the client asks for its
    /// password and calls again. The clipboard is read only here, when the user asks for it.
    public func importSSHKeyFromClipboard(password: String? = nil) async throws -> SSHKeyContent {
        guard current.session.isUnlocked else { throw EngineError.invalidState }
        guard let text = await ports.clipboard.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.sshKeyImport(.notAKey)
        }
        do {
            let key = try await ports.crypto.importSSHKey(text, password: password)
            guard current.session.isUnlocked else { throw EngineError.cancelled }
            return key
        } catch {
            throw EngineError(error)
        }
    }

    /// The earlier passwords of an item, the newest first.
    public func passwordHistory(of id: String) async throws -> [PasswordHistoryEntry] {
        guard current.session.isUnlocked, let crypto else { throw EngineError.invalidState }
        do {
            return try await crypto.passwordHistory(id: id)
        } catch {
            throw EngineError(error)
        }
    }

    /// How often a password is in known data leaks, by the leaked password service. The user asks
    /// for it in the form of a login; the engine never checks a password by itself.
    public func timesLeaked(password: String) async throws -> Int {
        guard current.session.isUnlocked, !password.isEmpty else { throw EngineError.invalidState }
        do {
            return try await ports.leaks.timesLeaked(password)
        } catch {
            throw EngineError(error)
        }
    }

    /// Whether this is the master password of the logged-in account. Items that ask for the
    /// master password again use it.
    public func isMasterPassword(_ password: String) async -> Bool {
        guard current.session.isUnlocked, let crypto, let stored else { return false }
        return await crypto.isMasterPassword(password, material: stored.crypto)
    }

    // MARK: SSH agent

    /// The agent runs while it is turned on and an account is logged in, locked or not, as
    /// `SshAgentService` of the reference. Its keys follow the vault, a lock ends what was
    /// allowed "until the vault is locked" and every question that waits, a logout forgets the keys.
    private func noteSSHAgent(before: EngineState, after: EngineState) {
        func wanted(_ state: EngineState) -> Bool { state.settings.sshAgent.isEnabled && state.session.account != nil }
        func keys(_ state: EngineState) -> [VaultItemSummary] { state.vault.items.filter { $0.type == .sshKey } }
        if wanted(before) != wanted(after) { Task { [weak self] in await self?.applySSHAgent() } }
        if before.session.isUnlocked && !after.session.isUnlocked
            || before.session.account?.id != after.session.account?.id
            || before.settings.sshAgent != after.settings.sshAgent || keys(before) != keys(after) {
            sshAuthorizationGeneration += 1
            sshAuthorized = []
            let waiting = sshApprovalWaiters
            sshApprovalWaiters = [:]
            sshApprovals = []
            for waiter in waiting.values { waiter.resume(returning: false) }
            // `update` is running: the state is changed after it.
            Task { [weak self] in await self?.showNextSSHApproval() }
        }
        if !wanted(after) || before.session.account?.id != after.session.account?.id
            || (before.session.isUnlocked && !after.session.isUnlocked)
            || before.settings.sshAgent != after.settings.sshAgent {
            sshCancelledRequests.formUnion(sshActiveRequests)
            let waiting = sshUnlockWaiters
            sshUnlockWaiters = [:]
            sshUnlockRequests = []
            for waiter in waiting.values { waiter.resume(returning: false) }
            Task { [weak self] in await self?.showNextSSHApproval() }
        }
        if case .loggedOut = after.session { sshIdentityList = [] }
        if after.session.isUnlocked {
            if !before.session.isUnlocked {
                let waiting = sshUnlockWaiters
                sshUnlockWaiters = [:]
                for waiter in waiting.values { waiter.resume(returning: true) }
                Task { [weak self] in await self?.showNextSSHApproval() }
            }
            if wanted(after), !before.session.isUnlocked || !wanted(before) || keys(before) != keys(after) {
                Task { [weak self] in await self?.refreshSSHIdentities() }
            }
        }
    }

    /// Starts or stops the port until it is as the state wants it.
    private func applySSHAgent() async {
        guard !isApplyingSSHAgent else { return }
        isApplyingSSHAgent = true
        defer { isApplyingSSHAgent = false }
        while true {
            let wanted = current.settings.sshAgent.isEnabled && current.session.account != nil
            if wanted == isSSHAgentRunning { return }
            if wanted {
                do {
                    try await ports.sshAgent.start(EngineSSHAnswers(self))
                    isSSHAgentRunning = true
                } catch {
                    note(.sshAgentUnavailable)
                    return
                }
            } else {
                isSSHAgentRunning = false
                await ports.sshAgent.stop()
            }
        }
    }

    private func refreshSSHIdentities() async {
        guard current.session.isUnlocked, let crypto else { return }
        let token = epoch
        let identities = await crypto.sshIdentities()
        guard token == epoch, current.session.isUnlocked else { return }
        if sshIdentityList != identities {
            sshAuthorizationGeneration += 1
            sshAuthorized = []
        }
        sshIdentityList = identities
    }

    /// The keys an SSH client is offered. None while the agent is off.
    func sshIdentities() -> [SSHAgentIdentity] {
        guard current.settings.sshAgent.isEnabled, current.session.account != nil else { return [] }
        return sshIdentityList
    }

    /// Signs for an SSH client: a locked vault is waited for, the user is asked as the settings
    /// say, and the crypto port signs. nil is a refusal; the client learns no reason.
    func sshSignature(for request: SSHSignRequest) async -> Data? {
        guard !current.isPreparingAppUpdate else { return nil }
        let id = UUID()
        sshActiveRequests.insert(id)
        defer {
            cancelSSHRequest(id: id)
            sshActiveRequests.remove(id)
            sshCancelledRequests.remove(id)
        }
        return await withTaskCancellationHandler {
            await makeSSHSignature(for: request, id: id)
        } onCancel: {
            Task { await self.cancelSSHRequest(id: id) }
        }
    }

    private func makeSSHSignature(for request: SSHSignRequest, id: UUID) async -> Data? {
        guard !Task.isCancelled, !sshCancelledRequests.contains(id) else { return nil }
        guard current.settings.sshAgent.isEnabled, let accountID = current.session.account?.id else { return nil }
        if !current.session.isUnlocked {
            note(.sshAgentUnlockRequired)
            guard await waitForSSHUnlock(id: id, processName: request.processName,
                                        requesterApplicationURL: request.requesterApplicationURL) else { return nil }
            // The keys of the vault that has just opened.
            await refreshSSHIdentities()
        }
        guard !Task.isCancelled, !sshCancelledRequests.contains(id), current.settings.sshAgent.isEnabled,
              current.session.isUnlocked, current.session.account?.id == accountID,
              let identity = sshIdentityList.first(where: { $0.publicKeyBlob == request.publicKeyBlob }),
              let item = current.vault.items.first(where: { $0.id == identity.itemID }),
              item.type == .sshKey, !item.isInTrash, !item.isArchived else { return nil }
        let authorization = SSHAuthorization(itemID: item.id, request: request)
        let prompt = current.settings.sshAgent.prompt
        let token = epoch
        let generation = sshAuthorizationGeneration
        func isCurrent() -> Bool {
            !Task.isCancelled && !sshCancelledRequests.contains(id) && token == epoch
                && generation == sshAuthorizationGeneration && current.session.isUnlocked
                && current.session.account?.id == accountID && current.settings.sshAgent.isEnabled
                && current.settings.sshAgent.prompt == prompt
                && sshIdentityList.contains(identity)
                && current.vault.items.contains { $0.id == item.id && $0.type == .sshKey && !$0.isInTrash && !$0.isArchived }
        }
        let asks: Bool = switch prompt {
        case .never: false
        case .always: true
        case .rememberUntilLock: authorization.map { !sshAuthorized.contains($0) } ?? true
        }
        if asks {
            let action: SSHApproval.Action = switch request.namespace {
            case nil, "": .logIn
            case "git": .signGit
            default: .sign
            }
            let approval = SSHApproval(id: id, itemID: item.id, keyName: item.name, processName: request.processName, action: action,
                                       isForwarding: request.isForwarding, publicKeyFingerprint: identity.publicKeyFingerprint,
                                       verifiedHostFingerprint: authorization?.hostFingerprint,
                                       requesterApplicationURL: request.requesterApplicationURL)
            guard await ask(approval), isCurrent() else { return nil }
            if prompt == .rememberUntilLock, let authorization { sshAuthorized.insert(authorization) }
        }
        guard isCurrent(), let crypto else { return nil }
        let signature = try? await crypto.sshSignature(itemID: item.id, publicKeyBlob: request.publicKeyBlob, data: request.data,
                                                       flags: request.flags)
        // A lock while the port signed: nothing leaves a locked vault.
        guard isCurrent() else { return nil }
        return signature
    }

    /// The answer of the user to the question that is on screen.
    public func answerSSHApproval(id: UUID, isAllowed: Bool) {
        guard let waiter = sshApprovalWaiters.removeValue(forKey: id) else { return }
        sshApprovals.removeAll { $0.id == id }
        showNextSSHApproval()
        waiter.resume(returning: isAllowed)
    }

    private func ask(_ approval: SSHApproval) async -> Bool {
        let clock = clock
        let timer = Task { [weak self] in
            try? await clock.sleep(for: Engine.sshApprovalPatience)
            guard !Task.isCancelled else { return }
            await self?.cancelSSHRequest(id: approval.id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled, !sshCancelledRequests.contains(approval.id) else {
                continuation.resume(returning: false); return
            }
            sshUnlockRequests.removeAll { $0.id == approval.id }
            sshApprovalWaiters[approval.id] = continuation
            sshApprovals.append(approval)
            showNextSSHApproval()
        }
    }

    private func showNextSSHApproval() {
        update {
            $0.sshApproval = sshApprovals.first
            $0.sshUnlockRequest = sshUnlockRequests.first
            let count = sshApprovals.count + sshUnlockRequests.count
            $0.sshPendingRequestCount = count > 0 ? count : nil
        }
    }

    /// Cancels only this request. A stale window cannot answer the next queued request.
    public func cancelSSHRequest(id: UUID) {
        guard sshActiveRequests.contains(id) else { return }
        sshCancelledRequests.insert(id)
        sshUnlockRequests.removeAll { $0.id == id }
        sshUnlockWaiters.removeValue(forKey: id)?.resume(returning: false)
        answerSSHApproval(id: id, isAllowed: false)
        showNextSSHApproval()
    }

    /// Whether the vault was unlocked before the patience of the agent ran out.
    private func waitForSSHUnlock(id: UUID, processName: String, requesterApplicationURL: URL?) async -> Bool {
        let clock = clock
        let timer = Task { [weak self] in
            try? await clock.sleep(for: Engine.sshUnlockPatience)
            guard !Task.isCancelled else { return }
            await self?.sshUnlockTimedOut(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if Task.isCancelled || sshCancelledRequests.contains(id) {
                continuation.resume(returning: false)
            } else if current.session.isUnlocked {
                continuation.resume(returning: true)
            } else {
                sshUnlockWaiters[id] = continuation
                sshUnlockRequests.append(SSHUnlockRequest(id: id, processName: processName,
                                                          requesterApplicationURL: requesterApplicationURL))
                showNextSSHApproval()
            }
        }
    }

    private func sshUnlockTimedOut(_ id: UUID) {
        guard sshUnlockWaiters[id] != nil else { return }
        cancelSSHRequest(id: id)
        note(.sshAgentUnlockTimedOut)
    }

    // MARK: Sends

    /// One Send with what it carries. Nothing of it is kept by the engine.
    public func send(id: String) async throws -> VaultSend {
        guard current.session.isUnlocked, let crypto else { throw EngineError.invalidState }
        guard current.vault.sends.contains(where: { $0.id == id }) else { throw EngineError.notFound }
        do {
            return try await crypto.send(id: id)
        } catch {
            throw EngineError(error)
        }
    }

    /// The link that opens a Send in the web vault of the account's server. It holds the key of
    /// the Send, which the server never gets.
    public func sendLink(of id: String) async throws -> String {
        guard case .unlocked(let account) = current.session else { throw EngineError.invalidState }
        guard let link = try await send(id: id).link(server: account.serverURL) else { throw EngineError.notFound }
        return link
    }

    /// Puts the link of a Send on the clipboard. The user passes it on, so it stays there.
    public func copySendLink(of id: String) async throws {
        let link = try await sendLink(of: id)
        guard current.session.isUnlocked else { throw EngineError.cancelled }
        await ports.clipboard.copy(link, isSensitive: false)
    }

    /// Saves the form of a Send: a new Send for a draft without an identifier, else the change
    /// of the Send it was made from. Returns the identifier of the Send.
    ///
    /// A Send needs a name and a text or a file (`invalidState`); its type and its file do not
    /// change. A file is as large as a file of an item may be (`attachmentTooLarge`).
    @discardableResult
    public func saveSend(_ draft: SendDraft, session: VaultSessionToken? = nil) async throws -> String {
        let requestedEpoch = session?.epoch ?? epoch
        await whenIdle()
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else {
            throw EngineError.invalidState
        }
        guard draft.isComplete, draft.maxAccessCount.map({ $0 >= 1 }) ?? true, draft.newPassword != "" else {
            throw EngineError.invalidState
        }
        if let id = draft.id {
            guard let send = current.vault.sends.first(where: { $0.id == id }) else { throw EngineError.notFound }
            guard send.type == draft.type, draft.file == nil else { throw EngineError.invalidState }
        } else if draft.type == .file {
            guard let file = draft.file, !file.name.isEmpty else { throw EngineError.invalidState }
            guard !file.data.isEmpty, file.data.count <= Engine.maximumAttachmentBytes else { throw EngineError.attachmentTooLarge }
        } else if draft.file != nil {
            throw EngineError.invalidState
        }
        // Encrypted once, also when the request is sent again with a new access token: a second
        // encryption of a new Send would make a second key.
        var encrypted: EncryptedSend?
        return try await write(account: account) { accessToken in
            let send: EncryptedSend
            if let encrypted {
                send = encrypted
            } else {
                send = try await crypto.encryptSend(draft)
                encrypted = send
            }
            if Task.isCancelled { throw EngineError.cancelled }
            try check(requestedEpoch)
            if let file = send.file {
                return try await ports.server.saveFileSend(request: send.request, file: file, server: account.serverURL,
                                                           accessToken: accessToken)
            }
            return try await ports.server.saveSend(request: send.request, sendID: draft.id, server: account.serverURL,
                                                   accessToken: accessToken)
        }
    }

    public func deleteSend(id: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        guard current.vault.sends.contains(where: { $0.id == id }) else { throw EngineError.notFound }
        try await write(account: account) { accessToken in
            try await ports.server.deleteSend(id: id, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            vault.sends.removeAll { $0.id == id }
        }
    }

    /// Takes the password from a Send. A Send without one is `invalidState`.
    public func removeSendPassword(of id: String) async throws {
        await whenIdle()
        guard case .unlocked(let account) = current.session, stored != nil, crypto != nil else {
            throw EngineError.invalidState
        }
        guard let send = current.vault.sends.first(where: { $0.id == id }) else { throw EngineError.notFound }
        guard send.hasPassword else { throw EngineError.invalidState }
        try await write(account: account) { accessToken in
            try await ports.server.removeSendPassword(id: id, server: account.serverURL, accessToken: accessToken)
        } show: { vault, _ in
            if let index = vault.sends.firstIndex(where: { $0.id == id }) { vault.sends[index].hasPassword = false }
        }
    }

    // MARK: Export and import

    /// File preparation can outlive a window or a lock. The client carries this token back
    /// with its prepared input; the command checks it on the engine actor before use.
    public func vaultSession() throws -> VaultSessionToken {
        guard current.session.isUnlocked, stored != nil, crypto != nil else { throw EngineError.invalidState }
        return VaultSessionToken(epoch: epoch)
    }

    public func checkVaultSession(_ session: VaultSessionToken) throws {
        if Task.isCancelled { throw EngineError.cancelled }
        try check(session.epoch)
        guard current.session.isUnlocked, !current.isPreparingAppUpdate else { throw EngineError.cancelled }
    }

    /// The vault of the user as an export file. The master password is asked for again, as the
    /// reference asks before it lets a whole vault out: `wrongMasterPassword` for another one.
    public func exportVault(format: VaultExportFormat, masterPassword: String, session: VaultSessionToken? = nil) async throws -> Data {
        let requestedEpoch = session?.epoch ?? epoch
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        guard current.session.isUnlocked, let crypto, let stored else { throw EngineError.invalidState }
        guard await crypto.isMasterPassword(masterPassword, material: stored.crypto) else { throw EngineError.wrongMasterPassword }
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        let file = try await crypto.exportVault(format: format)
        if Task.isCancelled { throw EngineError.cancelled }
        // A lock while the file was written must not let it out.
        try check(requestedEpoch)
        guard current.session.isUnlocked else { throw EngineError.cancelled }
        return file
    }

    /// Adds the folders and the items of a file to the vault, in one call to the server.
    public func importVault(_ file: VaultImport, session: VaultSessionToken? = nil) async throws {
        let requestedEpoch = session?.epoch ?? epoch
        await whenIdle()
        if Task.isCancelled { throw EngineError.cancelled }
        try check(requestedEpoch)
        guard case .unlocked(let account) = current.session, stored != nil, let crypto else { throw EngineError.invalidState }
        guard !file.items.isEmpty else { throw EngineError.invalidState }
        // Encrypted once, also when the request is sent again with a new access token.
        var request: Data?
        try await write(account: account) { accessToken in
            let body: Data
            if let request {
                body = request
            } else {
                body = try await crypto.encryptImport(file)
                request = body
            }
            if Task.isCancelled { throw EngineError.cancelled }
            try check(requestedEpoch)
            try await ports.server.importVault(request: body, server: account.serverURL, accessToken: accessToken)
        }
    }

    /// The fingerprint phrase of the unlocked account, in its words.
    public func fingerprintPhrase() async throws -> [String] {
        guard case .unlocked(let account) = current.session, let crypto else { throw EngineError.invalidState }
        return try await crypto.fingerprintPhrase(userID: account.id)
    }

    /// Asks a server to send the hint of the master password to the address of an account. It
    /// needs no session: the user asks from the log-in screen.
    public func requestPasswordHint(server: URL, email: String) async throws {
        do {
            try await ports.server.requestPasswordHint(server: server, email: email)
        } catch {
            throw EngineError(error)
        }
    }

    /// Whether the server of an account knows this device: the user logged in from it
    /// before. The log-in screen asks, since the reference offers "log in with device" only
    /// then. An empty address and a server that does not answer count as "no"
    /// (`getKnownDevice` of login.component.ts).
    public func isKnownDevice(server: URL, email: String) async -> Bool {
        guard !email.isEmpty, let device = try? await ports.store.deviceIdentifier() else { return false }
        return (try? await ports.server.isKnownDevice(server: server, email: email, deviceIdentifier: device)) ?? false
    }

    /// Reserve the session for installation before Sparkle stages an update.
    /// No in-flight write is cancelled. Abort releases the hold but leaves the vault locked.
    public func prepareForAppUpdate() throws {
        guard !current.isPreparingAppUpdate else { return }
        guard sessionChanges == 0, idleWaiters.isEmpty, !isAskingForBiometrics,
              current.activity == nil, current.upload == nil, current.twoStep == nil,
              sshActiveRequests.isEmpty, current.sshApproval == nil,
              current.sshUnlockRequest == nil else { throw EngineError.busy }
        lock()
        update { $0.isPreparingAppUpdate = true }
    }

    public func resumeAfterAppUpdate() {
        update { $0.isPreparingAppUpdate = false }
    }

    // MARK: Session end

    /// Removes the keys and the decrypted data from memory. It also stops a login or unlock in progress.
    public func lock() {
        guard current.activity != .starting else { return }
        interrupt()
        update { state in
            if let account = state.session.account { state.session = .locked(account) }
            state.vault = .empty
            state.activity = nil
        }
    }

    public func logOut() async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard current.activity != .starting else { return }
        interrupt()
        let accountID = stored?.account.id
        stored = nil
        storedPin = nil
        pinEnvelope = nil
        biometricKeyKept = false
        websiteIcons = [:]
        update { state in
            state.session = .loggedOut
            state.vault = .empty
            state.activity = nil
            state.settings = .default
            state.pin = .none
            state.biometrics = biometricState
        }
        do {
            // The PIN opens the keys of the stored account and goes with it.
            if let accountID { try await ports.store.savePin(nil, accountID: accountID) }
            try await ports.store.clear()
        } catch {
            if let accountID { try? await ports.biometrics.remove(accountID: accountID) }
            throw EngineError(error)
        }
        // The key behind Touch ID opens the keys of the account too and goes with it,
        // whether the store could be cleared or not.
        if let accountID { try? await ports.biometrics.remove(accountID: accountID) }
        // The next of the other accounts takes its place, locked, as in the reference.
        if accountID != nil, let next = current.otherAccounts.first { try? await activateAccount(next.id) }
    }

    /// Clients call this when the user does something. It restarts the inactivity timeout.
    public func noteUserActivity() {
        if case .afterInactivity = current.lockPolicy.timeout { restartInactivityTimer() }
    }

    /// Saves the settings of the logged-in account and acts on them from now on. When they cannot
    /// be saved, nothing changes and the command throws.
    public func setSettings(_ settings: EngineSettings) async throws {
        try beginSessionChange()
        defer { sessionChanges -= 1 }
        guard let account = current.session.account else { throw EngineError.invalidState }
        guard settings != current.settings else { return }
        do {
            try await ports.store.saveSettings(settings, accountID: account.id)
        } catch {
            throw EngineError(error)
        }
        // A logout or another account while the store was busy: these settings are not theirs.
        guard current.session.account?.id == account.id else { throw EngineError.cancelled }
        let policyChanged = settings.lockPolicy != current.settings.lockPolicy
        if !settings.showsWebsiteIcons { websiteIcons = [:] }
        update { $0.settings = settings }
        if policyChanged { restartInactivityTimer() }
    }

    // MARK: Command bookkeeping

    /// An optional avatar is fetched independently of authentication and cached for this session.
    public func accountAvatar() async -> Data? {
        guard case .unlocked(let account) = current.session else { return nil }
        if let cached = accountAvatars[account.email] { return cached }
        let token = epoch
        let image = await ports.avatars.image(email: account.email)
        guard token == epoch, current.session == .unlocked(account) else { return nil }
        accountAvatars[account.email] = .some(image)
        return image
    }

    private func beginSessionChange() throws {
        guard !current.isPreparingAppUpdate else { throw EngineError.busy }
        sessionChanges += 1
    }

    private func begin(_ activity: EngineActivity) throws -> Int {
        guard current.activity == nil, !current.isPreparingAppUpdate else { throw EngineError.busy }
        update {
            $0.activity = activity
            $0.authenticationPhase = activity == .unlocking || activity == .loggingIn ? .authenticating : nil
        }
        return epoch
    }

    private func finish(_ token: Int) {
        if token == epoch { update { $0.activity = nil; $0.authenticationPhase = nil } }
    }

    private func check(_ token: Int) throws {
        if token != epoch { throw EngineError.cancelled }
    }

    private func authenticationPhase(_ phase: AuthenticationPhase, token: Int) throws {
        try check(token)
        update { $0.authenticationPhase = phase }
    }

    private func interrupt() {
        epoch += 1
        capturedFillTarget = nil
        update { $0.authenticationPhase = nil }
        accountAvatars = [:]
        crypto = nil
        generated = []
        hasLoadedGenerated = false
        timerGeneration += 1
        inactivityTimer?.cancel()
        inactivityTimer = nil
        forgetPendingLogin()
    }

    // MARK: Timeouts

    private func handle(_ event: SystemEvent) async {
        if current.lockPolicy.timesOut(on: event) { await applyTimeoutAction() }
    }

    private func applyTimeoutAction() async {
        switch current.lockPolicy.action {
        case .lock: lock()
        case .logOut: try? await logOut()
        }
    }

    private func restartInactivityTimer() {
        timerGeneration += 1
        inactivityTimer?.cancel()
        inactivityTimer = nil
        guard current.session.isUnlocked, case .afterInactivity(let minutes) = current.lockPolicy.timeout else { return }
        let generation = timerGeneration
        let clock = self.clock
        inactivityTimer = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(minutes * 60)) } catch { return }
            await self?.inactivityTimerFired(generation)
        }
    }

    private func inactivityTimerFired(_ generation: Int) async {
        guard generation == timerGeneration else { return }
        await applyTimeoutAction()
    }
}
