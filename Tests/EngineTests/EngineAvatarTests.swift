import Engine
import EngineFakes
import Foundation
import Testing

private actor TestAvatars: AccountAvatarPort {
    var requests = 0
    var waits = false
    var continuation: CheckedContinuation<Data?, Never>?
    func hold() { waits = true }
    func release() { continuation?.resume(returning: Data([1, 2, 3])); continuation = nil }
    func image(email: String) async -> Data? {
        requests += 1
        if waits { return await withCheckedContinuation { continuation = $0 } }
        return nil
    }
}

@Suite struct EngineAvatarTests {
    @Test func avatarIsOptionalCachedAndNeverPartOfLogin() async throws {
        var (ports, _) = EnginePorts.fake()
        let avatars = TestAvatars()
        ports.avatars = avatars
        let engine = Engine(ports: ports)
        await engine.start()
        #expect(await engine.accountAvatar() == nil)
        #expect(await avatars.requests == 0)
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await avatars.requests == 0)
        #expect(await engine.accountAvatar() == nil)
        #expect(await engine.accountAvatar() == nil)
        #expect(await avatars.requests == 1)
        await engine.lock()
        #expect(await engine.accountAvatar() == nil)
        #expect(await avatars.requests == 1)
    }

    @Test func lockDiscardsAnAvatarThatArrivesLate() async throws {
        var (ports, _) = EnginePorts.fake()
        let avatars = TestAvatars()
        await avatars.hold()
        ports.avatars = avatars
        let engine = Engine(ports: ports)
        await engine.start()
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        let request = Task { await engine.accountAvatar() }
        while await avatars.requests == 0 { await Task.yield() }
        await engine.lock()
        await avatars.release()
        #expect(await request.value == nil)
    }
}
