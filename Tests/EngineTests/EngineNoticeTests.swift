import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineNoticeTests {
    let account = FakeAccount.demo

    /// What an engine left behind: the stored account and its settings and PIN.
    private func leftovers() async throws -> (stored: StoredAccount, settings: [String: EngineSettings], pins: [String: StoredPin]) {
        let (engine, handles) = try await makeUnlockedEngine()
        var settings = await engine.state.settings
        settings.lockPolicy = LockPolicy(timeout: .afterInactivity(minutes: 5), action: .lock)
        try await engine.setSettings(settings)
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        return (try #require(await handles.store.stored), await handles.store.settings, await handles.store.pins)
    }

    @Test func aNormalStartHasNothingToTell() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(await engine.state.notices.isEmpty)
    }

    @Test func anUnreadableAccountStartsLoggedOutAndIsReported() async throws {
        let left = try await leftovers()
        let (ports, handles) = EnginePorts.fake(account, stored: left.stored, settings: left.settings, pins: left.pins)
        await handles.store.makeUnreadable(account: true)
        let engine = Engine(ports: ports)
        await engine.start()

        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.activity == nil)
        #expect(state.notices == [.storedAccountUnreadable])
        // Nothing was removed: a later version or a repaired file can still read it.
        #expect(await handles.store.pins == left.pins)

        await engine.dismiss(.storedAccountUnreadable)
        #expect(await engine.state.notices.isEmpty)
    }

    @Test func unreadableSettingsFallBackToTheDefaultsAndAreReported() async throws {
        let left = try await leftovers()
        let (ports, handles) = EnginePorts.fake(account, stored: left.stored, settings: left.settings, pins: left.pins)
        await handles.store.makeUnreadable(settings: true)
        let engine = Engine(ports: ports)
        await engine.start()

        let state = await engine.state
        #expect(state.session == .locked(left.stored.account))
        #expect(state.settings == .default)
        #expect(state.pin == .none)
        #expect(state.notices == [.storedSettingsUnreadable])

        // The master password still opens the vault.
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func unreadableSettingsAtLogInAreReportedToo() async throws {
        let (ports, handles) = EnginePorts.fake(account)
        await handles.store.makeUnreadable(settings: true)
        let engine = Engine(ports: ports)
        await engine.start()
        #expect(await engine.state.notices.isEmpty)

        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.settings == .default)
        #expect(state.notices == [.storedSettingsUnreadable])
    }

    @Test func theCompositionRootCanHandOverANotice() async {
        let (ports, _) = EnginePorts.fake(account)
        let engine = Engine(ports: ports, notices: [.storeUnavailable])
        #expect(await engine.state.notices == [.storeUnavailable])
        await engine.start()
        #expect(await engine.state.notices == [.storeUnavailable])
    }

    @Test func aNoticeIsListedOnce() async throws {
        let (ports, handles) = EnginePorts.fake(account)
        await handles.store.makeUnreadable(settings: true)
        let engine = Engine(ports: ports)
        await engine.start()
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        try await engine.logOut()
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await engine.state.notices == [.storedSettingsUnreadable])
    }
}
