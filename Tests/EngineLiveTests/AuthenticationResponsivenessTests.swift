import Engine
import EngineFakes
import EngineLive
import Foundation
import Testing

@Suite(.enabled("Needs the local Vaultwarden: make server") { await LocalServer.isReachable() })
struct AuthenticationResponsivenessTests {
    /// Uses only the local synthetic vault. The heartbeat detects work that blocks the UI executor.
    @Test @MainActor func authenticationKeepsMainActorResponsive() async throws {
        _ = try await LocalServer.seeded.value
        let account = try #require(LocalServer.account)
        let fake = EnginePorts.fake()
        await fake.handles.biometrics.setSensorAvailable(true)
        var ports = fake.ports
        ports.server = VaultwardenServer()
        ports.crypto = BitwardenCrypto()
        let engine = Engine(ports: ports)
        await engine.start()
        var longestGap = Duration.zero
        var beats = 0
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                longestGap = max(longestGap, previous.duration(to: now))
                previous = now
                beats += 1
            }
        }
        defer { heartbeat.cancel() }
        let start = ContinuousClock.now
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        let login = start.duration(to: .now)
        let pinStart = ContinuousClock.now
        try await engine.setPin("123456", asksForMasterPasswordAfterRestart: false)
        let pin = pinStart.duration(to: .now)
        let biometricStart = ContinuousClock.now
        try await engine.setBiometricUnlock(true)
        let biometric = biometricStart.duration(to: .now)
        await engine.lock()
        let unlockStart = ContinuousClock.now
        try await engine.unlock(masterPassword: account.masterPassword)
        let unlock = unlockStart.duration(to: .now)
        #expect(beats > 0)
        #expect(await engine.state.session.isUnlocked)
        print("AUTH TIMING login=\(login) pin=\(pin) biometricSDK=\(biometric) unlock=\(unlock) mainActorMaxGap=\(longestGap)")
    }
}
