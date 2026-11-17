import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Small things of an account that are no part of its vault: the hint of the master password
/// and the fingerprint phrase.
@Suite struct EngineAccountTests {
    @Test func theHintOfTheMasterPasswordIsAskedForWithoutASession() async throws {
        let (engine, handles) = await makeEngine()
        let server = FakeAccount.demo.server

        try await engine.requestPasswordHint(server: server, email: "someone@example.com")
        #expect(await handles.server.hintRequests == ["someone@example.com"])
        #expect(await engine.state.session == .loggedOut)

        // What the server refuses is told as the server says it.
        await handles.server.failNext(.server("HTTP 400: This server sends no hints"))
        await #expect(throws: EngineError.server("HTTP 400: This server sends no hints")) {
            try await engine.requestPasswordHint(server: server, email: "someone@example.com")
        }
    }

    @Test func theServerKnowsADeviceOnceItHasLoggedIn() async throws {
        let (engine, handles) = await makeEngine()
        let account = FakeAccount.demo
        #expect(await engine.isKnownDevice(server: account.server, email: account.email) == false)

        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        try await engine.logOut()
        // The question needs no session, and the device is known for its own account only.
        #expect(await engine.state.session == .loggedOut)
        #expect(await engine.isKnownDevice(server: account.server, email: account.email))
        #expect(await engine.isKnownDevice(server: account.server, email: "someone@example.com") == false)
        #expect(await engine.isKnownDevice(server: account.server, email: "") == false)

        // A server that does not answer is a "no", not an error on the log-in screen.
        await handles.server.failNext(.serverUnreachable)
        #expect(await engine.isKnownDevice(server: account.server, email: account.email) == false)
        #expect(await engine.isKnownDevice(server: account.server, email: account.email))
    }

    @Test func theFingerprintPhraseBelongsToAnUnlockedAccount() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(try await engine.fingerprintPhrase().count == 5)

        await engine.lock()
        await #expect(throws: EngineError.invalidState) { _ = try await engine.fingerprintPhrase() }
    }
}
