@testable import AutoFillBridge
import Foundation
import Testing

@Suite @MainActor struct AutoFillServiceLifecycleTests {
    @MainActor private final class Fixture {
        enum Failure: Error { case registration }
        var state = AutoFillServiceLifecycle.State.enabled
        var saved: Data? = Data("old-helper".utf8)
        var events: [String] = []
        var failsRegistration = false
        var pausesUnregister = false
        var resumeUnregister: CheckedContinuation<Void, Never>?
        let identity = Data("installed-helper".utf8)

        func lifecycle() -> AutoFillServiceLifecycle {
            AutoFillServiceLifecycle(identity: identity, actions: .init(
                state: { self.state }, savedIdentity: { self.saved }, saveIdentity: { self.saved = $0 },
                register: {
                    self.events.append("register")
                    if self.failsRegistration { throw Failure.registration }
                    self.state = .enabled
                },
                unregister: {
                    self.events.append("unregister")
                    if self.pausesUnregister {
                        await withCheckedContinuation { self.resumeUnregister = $0 }
                    }
                    self.state = .notRegistered
                },
                startHost: { self.events.append("start") }, stopHost: { self.events.append("stop") }
            ))
        }
    }

    @Test func updatedHelperIsRegisteredBeforeTheConnectionStarts() async throws {
        let fixture = Fixture()
        let lifecycle = fixture.lifecycle()
        try await lifecycle.start()
        #expect(fixture.events == ["stop", "unregister", "register", "start"])
        #expect(fixture.saved == fixture.identity)
        fixture.events = []
        try await lifecycle.start()
        #expect(fixture.events == ["start"])
    }

    @Test func startupPreservesDisabledAndUnregisteredServices() async throws {
        for state in [AutoFillServiceLifecycle.State.requiresApproval, .notRegistered, .notFound] {
            let fixture = Fixture()
            fixture.state = state
            try await fixture.lifecycle().start()
            #expect(fixture.state == state)
            #expect(fixture.events == ["start"])
            #expect(fixture.saved != fixture.identity)
        }
    }

    @Test func failedRefreshDoesNotClaimTheCurrentHelperIsRegistered() async throws {
        let fixture = Fixture()
        fixture.failsRegistration = true
        let lifecycle = fixture.lifecycle()
        await #expect(throws: Fixture.Failure.self) { try await lifecycle.start() }
        #expect(fixture.saved == nil)
        #expect(!fixture.events.contains("start"))
        fixture.failsRegistration = false
        try await lifecycle.setEnabled(true)
        #expect(fixture.saved == fixture.identity)
        #expect(fixture.state == .enabled)
    }

    @Test func disableDuringRefreshWaitsAndWins() async throws {
        let fixture = Fixture()
        fixture.pausesUnregister = true
        let lifecycle = fixture.lifecycle()
        let startup = Task { try await lifecycle.start() }
        for _ in 0..<100 where fixture.resumeUnregister == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let resume = try #require(fixture.resumeUnregister)
        let disable = Task { try await lifecycle.setEnabled(false) }
        #expect(fixture.events == ["stop", "unregister"])
        fixture.pausesUnregister = false
        resume.resume()
        try await startup.value
        try await disable.value
        #expect(fixture.state == .notRegistered)
        #expect(fixture.saved == nil)
        #expect(fixture.events == ["stop", "unregister", "register", "start", "stop", "unregister"])
    }
}
