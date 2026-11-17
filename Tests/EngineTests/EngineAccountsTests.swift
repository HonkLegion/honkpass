import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// More than one account through the engine, on fakes: two fake servers, each with an account.
@Suite struct EngineAccountsTests {
    private let first = FakeAccount.demo
    private var second: FakeAccount {
        FakeAccount(server: URL(string: "https://second.example")!, email: "second@passvault.test",
                    masterPassword: "second-master-password", userID: "00000000-0000-4000-8000-000000000002",
                    contents: VaultContents(items: [VaultItemSummary(id: "second-1", type: .login, name: "Second Login")], folders: []))
    }

    /// An engine on two fake servers, logged in to the first account.
    private func makeTwoServerEngine() async throws -> (engine: Engine, handles: FakeHandles) {
        var (ports, handles) = EnginePorts.fake(first)
        ports.server = FakeServerRouter([first.server: handles.server, second.server: FakeServer(account: second)])
        let engine = Engine(ports: ports, now: { fixedDate })
        await engine.start()
        try await logIn(engine, first)
        return (engine, handles)
    }

    private func logIn(_ engine: Engine, _ account: FakeAccount) async throws {
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    }

    @Test func aSecondAccountIsAddedAndTheFirstWaitsLocked() async throws {
        let (engine, handles) = try await makeTwoServerEngine()
        #expect(await engine.state.otherAccounts.isEmpty)

        // "Add account" puts the account aside and shows the log-in.
        try await engine.addAccount()
        var state = await engine.state
        #expect(state.session == .loggedOut && state.vault == .empty)
        #expect(state.otherAccounts.map(\.email) == [first.email])
        #expect(await handles.store.stored == nil)
        #expect(await handles.store.parked.map(\.account.account.email) == [first.email])

        try await logIn(engine, second)
        state = await engine.state
        #expect(state.session.account?.email == second.email && state.session.isUnlocked)
        #expect(state.vault.items.map(\.name) == ["Second Login"])
        #expect(state.otherAccounts.map(\.email) == [first.email])

        // Back to the first one: it is locked, the second waits, and nothing of the second is on screen.
        let firstID = try #require(state.otherAccounts.first?.id)
        try await engine.switchAccount(to: firstID)
        state = await engine.state
        #expect(state.session == .locked(Account(id: first.userID, email: first.email, serverURL: first.server)))
        #expect(state.vault == .empty && state.otherAccounts.map(\.email) == [second.email])
        try await engine.unlock(masterPassword: first.masterPassword)
        #expect(await engine.state.vault.items.contains { $0.name == "Example Mail" })
        // The master password of one account does not open the other.
        try await engine.switchAccount(to: second.userID)
        await #expect(throws: EngineError.wrongMasterPassword) { try await engine.unlock(masterPassword: first.masterPassword) }
        try await engine.unlock(masterPassword: second.masterPassword)
        #expect(await engine.state.vault.items.map(\.name) == ["Second Login"])

        await #expect(throws: EngineError.notFound) { try await engine.switchAccount(to: "nobody") }
    }

    @Test func theOtherAccountsComeInTheOrderOfTheirLastUse() async throws {
        let third = FakeAccount(server: URL(string: "https://third.example")!, email: "third@passvault.test",
                                masterPassword: "third-master-password", userID: "00000000-0000-4000-8000-000000000003",
                                contents: VaultContents(items: [], folders: []))
        var (ports, handles) = EnginePorts.fake(first)
        ports.server = FakeServerRouter([first.server: handles.server, second.server: FakeServer(account: second),
                                         third.server: FakeServer(account: third)])
        let engine = Engine(ports: ports, now: { fixedDate })
        await engine.start()
        try await logIn(engine, first)
        try await engine.addAccount()
        try await logIn(engine, second)
        try await engine.addAccount()
        try await logIn(engine, third)
        // The account that was in use last is the first of the others, as in the reference.
        #expect(await engine.state.otherAccounts.map(\.email) == [second.email, first.email])
        try await engine.switchAccount(to: first.userID)
        #expect(await engine.state.otherAccounts.map(\.email) == [third.email, second.email])

        // A start finds them in the same order.
        let again = Engine(ports: ports, now: { fixedDate })
        await again.start()
        #expect(await again.state.otherAccounts.map(\.email) == [third.email, second.email])
    }

    @Test func eachAccountKeepsItsSettingsAndItsPin() async throws {
        let (engine, _) = try await makeTwoServerEngine()
        var settings = await engine.state.settings
        settings.clipboardClearing = .never
        try await engine.setSettings(settings)
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)

        try await engine.addAccount()
        #expect(await engine.state.settings == .default)
        #expect(await engine.state.pin == .none)
        try await logIn(engine, second)
        #expect(await engine.state.settings.clipboardClearing == .after(seconds: 300))
        #expect(await !engine.state.pin.isSet)

        // The first account comes back with its settings, and its PIN opens it.
        try await engine.switchAccount(to: first.userID)
        #expect(await engine.state.settings.clipboardClearing == .never)
        #expect(await engine.state.pin.canUnlock)
        try await engine.unlock(pin: "4812")
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aLogOutMakesTheNextAccountTheAccountAndTheLastOneLeavesNone() async throws {
        let (engine, handles) = try await makeTwoServerEngine()
        try await engine.addAccount()
        try await logIn(engine, second)

        try await engine.logOut()
        var state = await engine.state
        #expect(state.session == .locked(Account(id: first.userID, email: first.email, serverURL: first.server)))
        #expect(state.otherAccounts.isEmpty)
        #expect(await handles.store.parked.isEmpty)
        try await engine.unlock(masterPassword: first.masterPassword)

        try await engine.logOut()
        state = await engine.state
        #expect(state.session == .loggedOut && state.otherAccounts.isEmpty)
        #expect(await handles.store.stored == nil)
    }

    @Test func theLogInOfAnAccountThatWaitsReplacesItAndGivingUpGoesBack() async throws {
        let (engine, handles) = try await makeTwoServerEngine()
        try await engine.addAccount()
        // The same account again: it is the account, and it waits no longer.
        try await logIn(engine, first)
        #expect(await engine.state.otherAccounts.isEmpty)
        #expect(await engine.state.session.isUnlocked)
        #expect(await handles.store.parked.isEmpty)

        // The log-in of one more account is given up: the account that waits is switched to.
        try await engine.addAccount()
        await #expect(throws: EngineError.invalidCredentials) {
            try await engine.logIn(server: second.server, email: second.email, masterPassword: "wrong")
        }
        try await engine.switchAccount(to: first.userID)
        #expect(await engine.state.session.account?.email == first.email)
        // Nothing to add an account to while nobody is logged in.
        try await engine.logOut()
        await #expect(throws: EngineError.invalidState) { try await engine.addAccount() }
    }

    @Test func theAccountsThatWaitAreThereAfterARestart() async throws {
        let (engine, handles) = try await makeTwoServerEngine()
        try await engine.addAccount()
        try await logIn(engine, second)

        // Another engine on the same store, as after a restart of the app.
        var (ports, _) = EnginePorts.fake(first)
        ports.store = handles.store
        let restarted = Engine(ports: ports, now: { fixedDate })
        await restarted.start()
        let state = await restarted.state
        #expect(state.session == .locked(Account(id: second.userID, email: second.email, serverURL: second.server)))
        #expect(state.otherAccounts.map(\.email) == [first.email])

        // The app ended at the log-in of one more account: the first of those that wait is the account.
        try await engine.addAccount()
        let again = Engine(ports: ports, now: { fixedDate })
        await again.start()
        #expect(await again.state.session.account != nil)
        #expect(await again.state.otherAccounts.count == 1)
    }
}
