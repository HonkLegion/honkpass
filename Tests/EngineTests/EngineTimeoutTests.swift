@testable import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineTimeoutTests {
    @Test func theDefaultPolicyIgnoresSystemEvents() {
        for event in [SystemEvent.screenLocked, .willSleep, .systemIdle] {
            #expect(!LockPolicy.default.timesOut(on: event))
        }
    }

    @Test(arguments: [
        (VaultTimeout.onSystemLock, SystemEvent.screenLocked),
        (.onSleep, .willSleep),
        (.onSystemIdle, .systemIdle),
    ])
    func eachSystemTimeoutReactsToItsOwnEventOnly(timeout: VaultTimeout, event: SystemEvent) {
        let policy = LockPolicy(timeout: timeout, action: .lock)
        for other in [SystemEvent.screenLocked, .willSleep, .systemIdle] {
            #expect(policy.timesOut(on: other) == (other == event))
        }
    }

    @Test func aScreenLockLocksTheVaultWhenThePolicySaysSo() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setLockPolicy(LockPolicy(timeout: .onSystemLock, action: .lock))

        handles.systemEvents.send(.screenLocked)

        let state = try await nextState(of: engine) { !$0.session.isUnlocked }
        #expect(state.session.account?.email == FakeAccount.demo.email)
        #expect(state.vault == .empty)
    }

    @Test func theLogOutActionLogsOut() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setLockPolicy(LockPolicy(timeout: .onSleep, action: .logOut))

        handles.systemEvents.send(.willSleep)

        _ = try await nextState(of: engine) { $0.session == .loggedOut }
        #expect(await handles.store.stored == nil)
    }

    @Test func inactivityLocksTheVaultAfterTheTimeout() async throws {
        let clock = ManualClock()
        let (engine, _) = try await makeUnlockedEngine(clock: clock)
        try await engine.setLockPolicy(LockPolicy(timeout: .afterInactivity(minutes: 5), action: .lock))
        await clock.waitForSleeper()

        clock.advance(by: .seconds(5 * 60))

        _ = try await nextState(of: engine) { !$0.session.isUnlocked }
    }

    @Test func userActivityRestartsTheInactivityTimeout() async throws {
        let clock = ManualClock()
        let (engine, _) = try await makeUnlockedEngine(clock: clock)
        try await engine.setLockPolicy(LockPolicy(timeout: .afterInactivity(minutes: 5), action: .lock))
        await clock.waitForSleeper()

        clock.advance(by: .seconds(4 * 60))
        await engine.noteUserActivity()
        await clock.waitForSleeper()

        // Eight minutes after the unlock, four minutes after the last activity.
        clock.advance(by: .seconds(4 * 60))
        for _ in 0..<20 { await Task.yield() }
        #expect(await engine.state.session.isUnlocked)

        clock.advance(by: .seconds(60))
        _ = try await nextState(of: engine) { !$0.session.isUnlocked }
    }

    @Test func aLockedVaultHasNoInactivityTimer() async throws {
        let clock = ManualClock()
        let (engine, _) = try await makeUnlockedEngine(clock: clock)
        try await engine.setLockPolicy(LockPolicy(timeout: .afterInactivity(minutes: 5), action: .logOut))
        await clock.waitForSleeper()
        await engine.lock()

        clock.advance(by: .seconds(60 * 60))
        for _ in 0..<20 { await Task.yield() }
        #expect(await engine.state.session.account != nil)
    }
}
