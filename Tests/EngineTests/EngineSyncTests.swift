import Engine
import EngineFakes
import Foundation
import Synchronization
import Testing
import VaultModel

@Suite struct EngineSyncTests {
    let account = FakeAccount.demo

    private func logIn(_ engine: Engine) async throws {
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    }

    @Test func aRefusedAccessTokenIsRenewedAndTheSyncRepeated() async throws {
        let (engine, handles) = await makeEngine()
        try await logIn(engine)
        await handles.server.expireAccessToken()

        try await engine.sync()

        #expect(await handles.server.refreshCount == 1)
        #expect(await handles.server.syncCount == 2)
        #expect(await handles.store.stored?.accessToken == "fake-access-token-1")
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func anAccessTokenAtTheEndOfItsLifetimeIsRenewedBeforeTheSync() async throws {
        let time = Mutex(fixedDate)
        let (engine, handles) = await makeEngine(now: { time.withLock { $0 } })
        try await logIn(engine)

        // The token lives one hour.
        time.withLock { $0 = fixedDate.addingTimeInterval(3_590) }
        try await engine.sync()

        #expect(await handles.server.refreshCount == 1)
        #expect(await handles.store.stored?.accessTokenExpiry == fixedDate.addingTimeInterval(3_590 + 3_600))
    }

    @Test func theEndOfTheSessionLogsTheAccountOut() async throws {
        let (engine, handles) = await makeEngine()
        try await logIn(engine)
        await handles.server.endSession()

        #expect(await engineError { try await engine.sync() } == .sessionExpired)

        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.vault == .empty)
        #expect(await handles.store.stored == nil)
        // The user is told why the window is back at the log-in.
        #expect(state.notices == [.sessionExpired])
    }

    @Test func unlockShowsTheStoredCopyAndThenTheServersVersion() async throws {
        let (engine, handles) = await makeEngine()
        try await logIn(engine)
        await engine.lock()
        let changed = VaultContents(items: [VaultItemSummary(id: "new", type: .login, name: "New Login")], folders: [])
        await handles.server.setContents(changed)

        try await engine.unlock(masterPassword: account.masterPassword)

        let state = try await nextState(of: engine) { $0.vault.items == changed.items }
        #expect(state.session.isUnlocked)
    }

    @Test func aServerThatDoesNotAnswerLeavesTheStoredCopyAfterUnlock() async throws {
        let (engine, handles) = await makeEngine()
        try await logIn(engine)
        await engine.lock()
        await handles.server.failNext(.serverUnreachable)

        try await engine.unlock(masterPassword: account.masterPassword)
        _ = try await nextState(of: engine) { $0.session.isUnlocked && $0.activity == nil }

        #expect(await engine.state.vault.items == account.contents.items)
    }
}
