import Engine
import EngineFakes
import Testing

@Suite struct EngineAppUpdateTests {
    @Test func installationLocksWithoutRemovingTheStoredSession() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let before = await handles.store.stored
        try await engine.prepareForAppUpdate()
        #expect(await engine.state.isPreparingAppUpdate)
        #expect(await engine.state.session.isUnlocked == false)
        #expect(await engine.state.vault.items.isEmpty == true)
        #expect(await handles.store.stored == before)
        #expect(await engineError { try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword) } == .busy)
        #expect(await engineError { try await engine.logOut() } == .busy)
        #expect(await engineError { try await engine.removePin() } == .busy)
        #expect(await engineError { try await engine.setBiometricUnlock(false) } == .busy)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: "Synthetic update test") } == .busy)
        await engine.lock()
        #expect(await engineError { try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword) } == .busy)
        await engine.resumeAfterAppUpdate()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(await engine.state.session.isUnlocked)
        #expect(await handles.store.stored == before)
    }

    @Test func holdPreventsLoginAndResumesAfterCancellation() async throws {
        let (engine, _) = await makeEngine()
        let account = FakeAccount.demo
        try await engine.prepareForAppUpdate()
        #expect(await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        } == .busy)
        await engine.resumeAfterAppUpdate()
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func updateDoesNotInterruptSync() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.holdNextSync()
        let sync = Task { try await engine.sync() }
        await handles.server.syncIsHeld()
        #expect(await engineError { try await engine.prepareForAppUpdate() } == .busy)
        #expect(await engine.state.session.isUnlocked)
        #expect(await engine.state.isPreparingAppUpdate == false)
        await handles.server.releaseSync()
        try await sync.value
        try await engine.prepareForAppUpdate()
        #expect(await engine.state.isPreparingAppUpdate)
    }

    @Test func startupCannotBeInterruptedByAnUpdate() async {
        let fake = EnginePorts.fake()
        let engine = Engine(ports: fake.ports)
        #expect(await engineError { try await engine.prepareForAppUpdate() } == .busy)
        #expect(await engine.state.isPreparingAppUpdate == false)
    }
}
