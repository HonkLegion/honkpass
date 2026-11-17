import Engine
import EngineFakes
import Testing

@Suite struct AuthenticationProgressTests {
    @Test func loginShowsRealStagesAndClearsThemAfterSuccess() async throws {
        let fake = EnginePorts.fake()
        let engine = Engine(ports: fake.ports)
        await engine.start()
        let states = await engine.states()
        await fake.handles.server.holdNextSync()
        let login = Task {
            let account = FakeAccount.demo
            try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        }
        await fake.handles.server.syncIsHeld()
        #expect(await engine.state.authenticationPhase == .syncing)
        #expect(await engine.state.session == .loggedOut)
        await fake.handles.server.releaseSync()
        try await login.value
        var phases: [AuthenticationPhase] = []
        for await state in states {
            if let phase = state.authenticationPhase, phases.last != phase { phases.append(phase) }
            if state.session.isUnlocked && state.activity == nil { break }
        }
        #expect(phases == [.authenticating, .syncing, .loadingVault, .saving])
        #expect(await engine.state.authenticationPhase == nil)

        await engine.lock()
        let unlockStates = await engine.states()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        var unlockPhases: [AuthenticationPhase] = []
        for await state in unlockStates {
            if let phase = state.authenticationPhase, unlockPhases.last != phase { unlockPhases.append(phase) }
            if state.session.isUnlocked { break }
        }
        #expect(unlockPhases == [.authenticating, .loadingVault])
    }

    @Test func failedAuthenticationRemovesProgress() async throws {
        let engine = Engine(ports: EnginePorts.fake().ports)
        await engine.start()
        do {
            try await engine.logIn(server: FakeAccount.demo.server, email: FakeAccount.demo.email, masterPassword: "wrong")
            Issue.record("The fake server accepted the wrong password")
        } catch {}
        #expect(await engine.state.authenticationPhase == nil)
        #expect(await engine.state.activity == nil)
        #expect(await engine.state.session == .loggedOut)
    }
}
