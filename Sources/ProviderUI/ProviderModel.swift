import AutoFillBridge
import Foundation
import Observation
import VaultModel

/// What the AutoFill extension shows and does for one request of the system. It is a client
/// of the engine like a window of the app, but in another process: it asks through the
/// bridge and holds nothing. A password it gets goes to the system at once.
@MainActor @Observable
public final class ProviderModel {
    /// What the system asked for.
    public enum Request: Equatable, Sendable {
        /// A login for these websites, which the user chooses.
        case chooseLogin(services: [String])
        /// The login of an entry that the user took from the list of the system.
        case login(itemID: String)
        /// A passkey for a website, which the user chooses.
        case choosePasskey(PasskeyQuestion)
        /// The passkey of an entry that the user took from the list of the system.
        case passkey(itemID: String, PasskeyQuestion)
        /// A new passkey. The request names no login yet, and no verified user.
        case newPasskey(PasskeyRegistrationRequest)
    }

    /// What a website asks to be signed with a passkey.
    public struct PasskeyQuestion: Equatable, Sendable {
        public var rpID: String
        public var clientDataHash: Data
        public var allowedCredentialIDs: [Data]
        public var userVerification: PasskeyUserVerification

        public init(rpID: String, clientDataHash: Data, allowedCredentialIDs: [Data] = [], userVerification: PasskeyUserVerification) {
            self.rpID = rpID
            self.clientDataHash = clientDataHash
            self.allowedCredentialIDs = allowedCredentialIDs
            self.userVerification = userVerification
        }
    }

    /// Why the system is asked to verify the user: the text of its question says it.
    public enum Verification: Equatable, Sendable {
        case assertion(rpID: String, username: String)
        case registration(rpID: String, username: String)
        case overwrite(rpID: String, username: String)
    }

    public enum Screen: Equatable, Sendable {
        /// Nothing to show yet: the app is asked, or is starting.
        case loading
        /// The app did not answer. This says nothing about whether its vault is locked.
        case unavailable
        case loggedOut
        case locked(account: String?, withPin: Bool, withTouchID: Bool = false)
        case list
        /// The passkeys of the website, to choose one.
        case passkeys
        /// The vault has no passkey for the website.
        case noPasskeys
        /// The logins a new passkey can be saved to, and "save as new login".
        case passkeyTargets
        /// The vault has a passkey that the website excludes.
        case passkeyExists
    }

    public enum Outcome: Equatable, Sendable {
        case password(AutoFillPassword)
        case cancelled
        /// The login the system named is not in the vault, or cannot be given from here.
        case notFound
        case assertion(PasskeyAssertion)
        case registration(PasskeyRegistration)
        /// No passkey was made: the vault has one that the website excludes.
        case passkeyExists
        /// The request cannot be answered: the user was not verified, or the passkey could not be made.
        case failed
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable {
            case suggestions, allItems, searchResults
        }

        public let kind: Kind
        public let logins: [AutoFillLogin]
        public var id: Kind { kind }
    }

    public enum Problem: Equatable, Sendable {
        case pinRequired, wrongPin, tooManyWrongPins
        /// Touch ID did not open the vault.
        case touchIDFailed
    }

    public struct Actions: Sendable {
        /// Opens the app: in front of the other apps when the user asked for it, behind them
        /// when the extension starts an app that is not running.
        public var openApp: @MainActor @Sendable (_ inFront: Bool) -> Void
        /// The end of the request. It is called once.
        public var finish: @MainActor @Sendable (Outcome) -> Void
        /// Has the system verify the user, with Touch ID or the password of the Mac: true for a
        /// verified user, false when it could not be done, nil when the user closed the question.
        public var verifyUser: @MainActor @Sendable (Verification) async -> Bool?

        public init(openApp: @escaping @MainActor @Sendable (Bool) -> Void, finish: @escaping @MainActor @Sendable (Outcome) -> Void,
                    verifyUser: @escaping @MainActor @Sendable (Verification) async -> Bool? = { _ in false }) {
            self.openApp = openApp
            self.finish = finish
            self.verifyUser = verifyUser
        }
    }

    /// The request ends by itself after this many looks at the vault: ten minutes, as the
    /// extension of the reference waits.
    static let patience = 600
    /// An app that was started gets this many looks before the extension reports a connection problem.
    static let patienceWithStart = 10

    public private(set) var screen = Screen.loading
    public private(set) var problem: Problem?
    /// A question is on its way to the app.
    public private(set) var isBusy = false
    public var pin = ""
    public var search = "" {
        didSet { if search != oldValue { selectedID = nil } }
    }
    /// The login the keyboard is on. nil is the first one that can be filled.
    public var selectedID: String?

    public let request: Request
    private let asking: any AutoFillAsking
    private let pause: Duration
    private let actions: Actions
    private var suggestions: [AutoFillLogin] = []
    private var others: [AutoFillLogin] = []
    /// The passkeys of the website, and the logins a new passkey can be saved to.
    public private(set) var passkeys: [AutoFillPasskey] = []
    public private(set) var targets: [AutoFillLogin] = []
    /// The login whose passkey would be replaced: the user is asked first.
    public private(set) var overwriting: AutoFillLogin?
    /// The user typed the PIN of the vault for this request, or opened the vault with Touch
    /// ID from here, which verifies them as the question of the system would.
    private var hasUnlockedHere = false
    /// What the question of the system says the app wants to do when it asks for Touch ID.
    private let touchIDReason: String
    /// Touch ID was asked for from this window. The window asks by itself only once, and not
    /// after the user did.
    private var hasAskedForTouchID = false
    /// The last look found a locked vault whose account wants Touch ID asked for at once.
    private var wantsTouchIDAtOnce = false
    private var isFinished = false
    private var looks = 0
    /// A look at the vault is on its way. It never keeps the user from acting.
    private var isLooking = false
    /// Counts what the user did, so that the answer to an older look changes nothing.
    private var userActions = 0
    private var unanswered = 0
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// - Parameters:
    ///   - pause: the time between two looks at a vault that is not open yet.
    ///   - touchIDReason: the text for the question of the system when Touch ID unlocks.
    public init(request: Request, asking: any AutoFillAsking, pause: Duration = .seconds(1), touchIDReason: String = "",
                actions: Actions) {
        self.request = request
        self.asking = asking
        self.pause = pause
        self.touchIDReason = touchIDReason
        self.actions = actions
    }

    // MARK: The state of the vault

    /// Asks the app and goes on asking while there is nothing to choose from: the user may
    /// unlock the vault in the app, and the extension then goes on by itself.
    public func start() {
        guard watch == nil, !isFinished else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = await self?.look() else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// One look. nil when there is nothing more to look for.
    private func look() async -> Duration? {
        guard !isFinished else { return nil }
        looks += 1
        guard looks <= Self.patience else {
            finish(.cancelled)
            return nil
        }
        // Only a screen that waits for the vault looks again; one with something to choose stays.
        let waits = switch screen {
        case .loading, .unavailable, .loggedOut, .locked: true
        default: false
        }
        if waits, !isBusy, !isLooking {
            isLooking = true
            let before = userActions
            let answer = await asking.ask(.status)
            isLooking = false
            // The user typed the PIN meanwhile: this answer is of the vault before that.
            if before == userActions, !isBusy, !isFinished {
                isBusy = true
                await settle(answer)
                isBusy = false
                if wantsTouchIDAtOnce {
                    wantsTouchIDAtOnce = false
                    unlockWithTouchID()
                }
            }
        }
        return isFinished ? nil : pause
    }

    /// Shows what an answer says of the vault, and goes on when the vault is open.
    private func settle(_ answer: AutoFillResponse) async {
        guard case .status(let status) = answer else {
            // A connection failure is not a locked vault. Try starting the app once,
            // then keep watching so a repaired connection can resume this request.
            unanswered += 1
            if unanswered == 1 { actions.openApp(false) }
            if unanswered > Self.patienceWithStart { screen = .unavailable }
            return
        }
        unanswered = 0
        switch status.vault {
        case .unlocked: await proceed()
        case .locked:
            hasUnlockedHere = false
            screen = .locked(account: status.account, withPin: status.canUnlockWithPin, withTouchID: status.canUnlockWithTouchID)
            // "Ask for Touch ID on app start" of the account: the window asks once by itself.
            wantsTouchIDAtOnce = status.canUnlockWithTouchID && status.asksForTouchIDAtOnce && !hasAskedForTouchID
        case .loggedOut:
            hasUnlockedHere = false
            screen = .loggedOut
        }
    }

    /// The vault is open: the list is read, or the login the system named is given.
    private func proceed() async {
        problem = nil
        switch request {
        case .chooseLogin(let services):
            // An answer that is no list means the vault closed meanwhile; the next look says how.
            guard case .logins(let all) = await asking.ask(.logins(services: [])) else { return }
            var matching: [AutoFillLogin] = []
            if !services.isEmpty {
                guard case .logins(let found) = await asking.ask(.logins(services: services)) else { return }
                matching = found
            }
            suggestions = matching
            let matchingIDs = Set(matching.map(\.itemID))
            others = all.filter { !matchingIDs.contains($0.itemID) }
            screen = .list
        case .login(let itemID):
            await give(itemID, wasChosenHere: false)
        case .choosePasskey(let question):
            guard case .passkeys(let found) = await asking.ask(.passkeys(rpID: question.rpID,
                                                                         allowedCredentialIDs: question.allowedCredentialIDs)) else { return }
            passkeys = found
            if found.count == 1, !found[0].asksForMasterPassword,
               question.userVerification == .required || hasUnlockedHere {
                // Required verification or unlocking here collects consent. Otherwise the
                // user must select the passkey, even when there is only one.
                await sign(with: found[0].itemID, username: found[0].username, question, wasChosenHere: false)
            } else {
                screen = found.isEmpty ? .noPasskeys : .passkeys
            }
        case .passkey(let itemID, let question):
            await sign(with: itemID, username: "", question, wasChosenHere: false)
        case .newPasskey(let request):
            guard case .logins(let found) = await asking.ask(.passkeyTargets(rpID: request.rpID, userHandle: request.userHandle)) else {
                return
            }
            targets = found
            if found.isEmpty, request.userVerification == .required || hasUnlockedHere {
                await register(request, into: nil)
            } else {
                // Creating a credential still needs consent when verification is optional.
                screen = .passkeyTargets
            }
        }
    }

    // MARK: Passkeys

    /// Unlocking here verifies this request. Otherwise only required verification prompts.
    /// Selection gives consent, but never claims that the user was verified.
    /// nil means that the user cancelled the system prompt.
    private func isUserVerified(_ wanted: PasskeyUserVerification, for purpose: Verification) async -> Bool? {
        if hasUnlockedHere { return true }
        guard wanted == .required else { return false }
        return await actions.verifyUser(purpose)
    }

    private func sign(with itemID: String, username: String, _ question: PasskeyQuestion, wasChosenHere: Bool) async {
        guard let isVerified = await isUserVerified(question.userVerification,
                                                    for: .assertion(rpID: question.rpID, username: username)) else {
            return finish(.cancelled)
        }
        guard !isFinished else { return }
        guard isVerified || question.userVerification != .required else { return finish(.failed) }
        let request = PasskeyAssertionRequest(rpID: question.rpID, clientDataHash: question.clientDataHash,
                                              allowedCredentialIDs: question.allowedCredentialIDs, itemID: itemID,
                                              userVerification: question.userVerification, isUserVerified: isVerified)
        switch await asking.ask(.passkeyAssertion(request)) {
        case .passkeyAssertion(let assertion):
            finish(.assertion(assertion))
        case .failure(.notFound), .failure(.masterPasswordRequired):
            if wasChosenHere { await proceed() } else { finish(.notFound) }
        case .failure(.userNotVerified):
            finish(.failed)
        default:
            screen = .loading
        }
    }

    private func register(_ request: PasskeyRegistrationRequest, into login: AutoFillLogin?) async {
        let purpose: Verification = login?.hasPasskey == true ? .overwrite(rpID: request.rpID, username: request.userName)
            : .registration(rpID: request.rpID, username: request.userName)
        guard let isVerified = await isUserVerified(request.userVerification, for: purpose) else { return finish(.cancelled) }
        guard !isFinished else { return }
        guard isVerified || request.userVerification != .required else { return finish(.failed) }
        var request = request
        request.itemID = login?.itemID
        request.isUserVerified = isVerified
        switch await asking.ask(.registerPasskey(request)) {
        case .passkeyRegistration(let registration):
            finish(.registration(registration))
        case .failure(.passkeyExists):
            screen = .passkeyExists
        case .failure(.locked), .failure(.loggedOut):
            screen = .loading
        default:
            finish(.failed)
        }
    }

    public func choose(_ passkey: AutoFillPasskey) {
        guard !isBusy, !isFinished, screen == .passkeys, !passkey.asksForMasterPassword,
              case .choosePasskey(let question) = request else { return }
        isBusy = true
        userActions += 1
        Task {
            defer { isBusy = false }
            await sign(with: passkey.itemID, username: passkey.username, question, wasChosenHere: true)
        }
    }

    /// Saves the new passkey to a login, or to a new login (nil). A login that has a passkey
    /// is asked about first: the new one takes its place.
    public func save(into login: AutoFillLogin?) {
        guard !isBusy, !isFinished, screen == .passkeyTargets, login?.asksForMasterPassword != true,
              case .newPasskey(let request) = self.request else { return }
        if let login, login.hasPasskey, overwriting == nil {
            overwriting = login
            return
        }
        overwriting = nil
        isBusy = true
        userActions += 1
        Task {
            defer { isBusy = false }
            await register(request, into: login)
        }
    }

    /// The answer to "overwrite passkey?".
    public func answerOverwrite(_ accepts: Bool) {
        guard let login = overwriting else { return }
        if accepts { save(into: login) } else { overwriting = nil }
    }

    /// The user has read a notice that ends the request: no passkey for the website, or one
    /// that the website excludes.
    public func closeNotice() {
        switch screen {
        case .passkeyExists: finish(.passkeyExists)
        case .noPasskeys: finish(.notFound)
        default: break
        }
    }

    private func give(_ itemID: String, wasChosenHere: Bool) async {
        switch await asking.ask(.password(itemID: itemID)) {
        case .password(let password):
            finish(.password(password))
        case .failure(.notFound), .failure(.masterPasswordRequired):
            // A login of the list that is gone meanwhile: the list is read again.
            if wasChosenHere { await proceed() } else { finish(.notFound) }
        default:
            // The vault closed meanwhile, or the app is gone: the next look says which.
            screen = .loading
        }
    }

    // MARK: What the user does

    /// The PIN the user typed. A wrong one stays in the field, as on the lock screen of the app.
    public func submitPin() {
        guard !isBusy, !isFinished, case .locked(_, withPin: true, _) = screen else { return }
        guard !pin.trimmingCharacters(in: .whitespaces).isEmpty else {
            problem = .pinRequired
            return
        }
        problem = nil
        isBusy = true
        userActions += 1
        let typed = pin
        Task {
            defer { isBusy = false }
            switch await asking.ask(.unlock(pin: typed)) {
            case .failure(.wrongPin):
                problem = .wrongPin
            case .failure(.pinUnavailable):
                // The PIN opens nothing any more. After too many wrong ones the account is logged out.
                pin = ""
                let answer = await asking.ask(.status)
                await settle(answer)
                if screen == .loggedOut { problem = .tooManyWrongPins }
            case let answer:
                if case .status(let status) = answer, status.vault == .unlocked {
                    pin = ""
                    hasUnlockedHere = true
                }
                await settle(answer)
            }
        }
    }

    /// Touch ID opens the vault. The app has the system ask, and its question comes over this
    /// window; the answer comes when the user has answered. A question that the user closed
    /// leaves the window as it is.
    public func unlockWithTouchID() {
        guard !isBusy, !isFinished, case .locked(_, _, withTouchID: true) = screen else { return }
        hasAskedForTouchID = true
        problem = nil
        isBusy = true
        userActions += 1
        Task {
            defer { isBusy = false }
            switch await asking.ask(.unlockWithTouchID(reason: touchIDReason)) {
            case .failure(.touchIDFailed):
                // The key is gone or opens nothing any more: the next look says what is left.
                let answer = await asking.ask(.status)
                await settle(answer)
                if case .locked = screen { problem = .touchIDFailed }
            case let answer:
                if case .status(let status) = answer, status.vault == .unlocked { hasUnlockedHere = true }
                await settle(answer)
            }
        }
    }

    public func choose(_ login: AutoFillLogin) {
        guard !isBusy, !isFinished, screen == .list, !login.asksForMasterPassword else { return }
        isBusy = true
        userActions += 1
        Task {
            defer { isBusy = false }
            await give(login.itemID, wasChosenHere: true)
        }
    }

    /// Return: the row the keyboard is on.
    public func chooseSelected() {
        switch screen {
        case .list:
            if let selected { choose(selected) }
        case .passkeys:
            if let passkey = passkeys.first(where: { $0.id == selectedRowID }) { choose(passkey) }
        case .passkeyTargets:
            guard let row = selectedRowID else { return }
            save(into: targets.first { $0.itemID == row })
        default:
            break
        }
    }

    /// The user wants the app in front: to unlock it there, or to log in.
    public func openApp() {
        actions.openApp(true)
    }

    public func cancel() {
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        watch?.cancel()
        actions.finish(outcome)
    }

    // MARK: The list

    /// The logins of the websites the system named and the other logins; or, while the user
    /// searches, the logins whose name or user name contains what was typed.
    public var sections: [Section] {
        let typed = search.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            return [Section(kind: .suggestions, logins: suggestions), Section(kind: .allItems, logins: others)]
                .filter { !$0.logins.isEmpty }
        }
        let found = (suggestions + others).filter { login in
            [login.name, login.username].contains { $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return found.isEmpty ? [] : [Section(kind: .searchResults, logins: found)]
    }

    public var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The logins a key can be on: those the extension can give.
    private var reachable: [AutoFillLogin] {
        sections.flatMap(\.logins).filter { !$0.asksForMasterPassword }
    }

    public var selected: AutoFillLogin? {
        let reachable = reachable
        return reachable.first { $0.itemID == selectedID } ?? reachable.first
    }

    /// The row of "save as new login" among the logins a passkey can be saved to.
    public static let newLoginRow = "new-login"

    /// The rows a key can be on, on the screen that is shown.
    private var rows: [String] {
        switch screen {
        case .list: reachable.map(\.itemID)
        case .passkeys: passkeys.filter { !$0.asksForMasterPassword }.map(\.id)
        case .passkeyTargets: targets.filter { !$0.asksForMasterPassword }.map(\.itemID) + [Self.newLoginRow]
        default: []
        }
    }

    /// The row the keyboard is on: the chosen one while it is there, else the first.
    public var selectedRowID: String? {
        let rows = rows
        return rows.first { $0 == selectedID } ?? rows.first
    }

    /// Moves the keyboard by one row, and stays at the ends of the list.
    public func move(_ step: Int) {
        let rows = rows
        guard let selectedRowID, let index = rows.firstIndex(of: selectedRowID) else { return }
        selectedID = rows[min(max(index + step, 0), rows.count - 1)]
    }
}
