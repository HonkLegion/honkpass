import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineSessionTests {
    let account = FakeAccount.demo

    @Test func startsLoggedOutWithoutAStoredAccount() async {
        let (engine, _) = await makeEngine()
        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.activity == nil)
        #expect(state.vault == .empty)
    }

    @Test func logInUnlocksTheVaultAndStoresTheAccount() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let state = await engine.state
        #expect(state.session == .unlocked(Account(id: account.userID, email: account.email, serverURL: account.server)))
        #expect(state.vault.items == account.contents.items)
        #expect(state.vault.folders == account.contents.folders)
        #expect(state.vault.lastSync == fixedDate)
        #expect(state.activity == nil)

        let stored = await handles.store.stored
        #expect(stored?.account.email == account.email)
        #expect(stored?.vaultPayload != nil)
        #expect(stored?.accessTokenExpiry == fixedDate.addingTimeInterval(3_600))
    }

    @Test func logInWithAWrongPasswordFails() async {
        let (engine, handles) = await makeEngine()
        let error = await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: "wrong")
        }
        #expect(error == .invalidCredentials)
        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.activity == nil)
        #expect(await handles.store.stored == nil)
    }

    @Test func aServerFailureDuringLogInLeavesTheEngineLoggedOut() async {
        let (engine, handles) = await makeEngine()
        await handles.server.failNext(.serverUnreachable)
        let error = await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        }
        #expect(error == .serverUnreachable)
        #expect(await engine.state.session == .loggedOut)
    }

    @Test func lockRemovesTheVaultData() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        await engine.lock()
        let state = await engine.state
        #expect(state.session == .locked(Account(id: account.userID, email: account.email, serverURL: account.server)))
        #expect(state.vault == .empty)
    }

    @Test func unlockOpensTheStoredCopyWithoutTheServer() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await engine.lock()
        await handles.server.failNext(.serverUnreachable)

        try await engine.unlock(masterPassword: account.masterPassword)
        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.vault.items == account.contents.items)
        #expect(state.vault.lastSync == fixedDate)
        #expect(await handles.server.syncCount == 1)
    }

    @Test func unlockWithAWrongMasterPasswordFails() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        await engine.lock()
        let error = await engineError { try await engine.unlock(masterPassword: "wrong") }
        #expect(error == .wrongMasterPassword)
        let state = await engine.state
        #expect(!state.session.isUnlocked)
        #expect(state.vault == .empty)
        #expect(state.activity == nil)
    }

    @Test func startsLockedWithAStoredAccount() async throws {
        let (first, handles) = try await makeUnlockedEngine()
        let stored = await handles.store.stored
        _ = first

        // A new engine on the same stored data is what a restart of the app looks like.
        let (engine, _) = await makeEngine(stored: stored)
        #expect(await engine.state.session == .locked(try #require(stored).account))
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.vault.items == account.contents.items)
    }

    @Test func logOutRemovesTheAccountFromMemoryAndStore() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.logOut()
        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.vault == .empty)
        #expect(await handles.store.stored == nil)
    }

    @Test func anInterruptedLogoutRevokesTheSessionAndCanFinishLater() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setPin("1234", asksForMasterPasswordAfterRestart: false)
        await handles.store.failNextPinSave()
        await #expect(throws: EngineError.self) { try await engine.logOut() }
        #expect(await engine.state.session.account?.id == account.userID)
        #expect(await engine.state.vault == .empty)
        #expect(await handles.store.stored == nil)
        #expect(try await handles.store.pendingLogout() == account.userID)
        #expect(await engineError { try await engine.unlock(masterPassword: account.masterPassword) } != nil)
        try await engine.logOut()
        #expect(try await handles.store.pendingLogout() == nil)
        #expect(try await handles.store.loadPin(accountID: account.userID) == nil)
        #expect(await engine.state.session == .loggedOut)
    }

    @Test func commandsThatDoNotFitTheStateAreRejected() async throws {
        let (engine, _) = await makeEngine()
        #expect(await engineError { try await engine.unlock(masterPassword: "x") } == .invalidState)
        #expect(await engineError { try await engine.sync() } == .invalidState)
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        let again = await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        }
        #expect(again == .invalidState)
    }

    @Test func syncReplacesTheVaultContents() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let changed = VaultContents(items: [VaultItemSummary(id: "new", type: .login, name: "New Login")], folders: [])
        await handles.server.setContents(changed)

        try await engine.sync()
        #expect(await engine.state.vault.items == changed.items)
        #expect(await handles.server.syncCount == 2)
    }

    @Test func aSecondCommandIsRejectedWhileOneIsInProgress() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.holdNextSync()
        let sync = Task { try await engine.sync() }
        await handles.server.syncIsHeld()

        #expect(await engine.state.activity == .syncing)
        #expect(await engineError { try await engine.sync() } == .busy)

        await handles.server.releaseSync()
        try await sync.value
        #expect(await engine.state.activity == nil)
    }

    @Test func lockInterruptsACommandInProgress() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.holdNextSync()
        let sync = Task { await engineError { try await engine.sync() } }
        await handles.server.syncIsHeld()

        await engine.lock()
        await handles.server.releaseSync()

        #expect(await sync.value == .cancelled)
        let state = await engine.state
        #expect(!state.session.isUnlocked)
        #expect(state.vault == .empty)
        #expect(state.activity == nil)
    }
}

@Suite struct EngineClientTests {
    let account = FakeAccount.demo

    /// The main window and the menu bar are two such clients: a lock from one reaches the other.
    @Test func everyClientSeesTheSameState() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let window = Task { try await nextState(of: engine) { !$0.session.isUnlocked } }
        let menuBar = Task { try await nextState(of: engine) { !$0.session.isUnlocked } }

        await engine.lock()

        let seenByWindow = try await window.value
        let seenByMenuBar = try await menuBar.value
        #expect(seenByWindow == seenByMenuBar)
        #expect(seenByWindow.vault == .empty)
    }

    @Test func aNewClientGetsTheCurrentStateFirst() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        var iterator = await engine.states().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == (await engine.state))
        #expect(first?.session.isUnlocked == true)
    }

    @Test func noStateCarriesVaultDataUnlessUnlocked() async throws {
        let (engine, _) = await makeEngine()
        let stream = await engine.states()
        let collector = Task {
            var states: [EngineState] = []
            for await state in stream {
                states.append(state)
                if states.count > 1, state.session == .loggedOut, state.activity == nil { break }
            }
            return states
        }

        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        await engine.lock()
        try await engine.unlock(masterPassword: account.masterPassword)
        try await engine.logOut()

        let states = await collector.value
        #expect(states.contains { $0.session.isUnlocked && !$0.vault.items.isEmpty })
        for state in states where !state.session.isUnlocked {
            #expect(state.vault == .empty)
        }
    }
}
