import Engine
import EngineFakes
import Foundation
import VaultModel

struct TimedOut: Error {}

let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A started engine on fake ports.
func makeEngine(account: FakeAccount = .demo, stored: StoredAccount? = nil, settings: [String: EngineSettings] = [:],
                pins: [String: StoredPin] = [:], clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = { fixedDate }) async -> (engine: Engine, handles: FakeHandles) {
    let (ports, handles) = EnginePorts.fake(account, stored: stored, settings: settings, pins: pins)
    let engine = Engine(ports: ports, clock: clock, now: now)
    await engine.start()
    return (engine, handles)
}

/// A started engine that is logged in to the demo account and unlocked.
func makeUnlockedEngine(clock: any Clock<Duration> = ContinuousClock()) async throws -> (engine: Engine, handles: FakeHandles) {
    let account = FakeAccount.demo
    // Timer-specific tests wait for a single simulated sleeper (clipboard, lock, or SSH).
    var settings = EngineSettings.default
    if clock is ManualClock { settings.syncInterval = .disabled }
    let result = await makeEngine(settings: clock is ManualClock ? [account.userID: settings] : [:], clock: clock)
    try await result.engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    return result
}

/// The first state that satisfies the condition. Fails after five seconds.
func nextState(of engine: Engine, where condition: @escaping @Sendable (EngineState) -> Bool) async throws -> EngineState {
    let stream = await engine.states()
    return try await withThrowingTaskGroup(of: EngineState.self) { group in
        group.addTask {
            for await state in stream where condition(state) { return state }
            throw TimedOut()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw TimedOut()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// The error a command throws, or nil when it succeeds.
func engineError(_ command: () async throws -> Void) async -> EngineError? {
    do {
        try await command()
        return nil
    } catch {
        return error as? EngineError ?? .unexpected("not an EngineError")
    }
}

extension Engine {
    /// Changes only the lock policy of the settings.
    func setLockPolicy(_ policy: LockPolicy) async throws {
        var settings = state.settings
        settings.lockPolicy = policy
        try await setSettings(settings)
    }
}
