import Engine
import EngineFakes
import EngineLive
import Foundation
import Testing
import VaultModel

/// Two-step login against the local Vaultwarden: the account of test-account-two-step.json has an
/// authenticator app and email. The codes of the email come from the mail catcher of the server.
/// The tests run one after another, because they share one mailbox.
@Suite(.enabled("Needs the local Vaultwarden: make server") { await LocalServer.isReachable() }, .serialized)
struct TwoStepServerTests {
    let account = LocalServer.twoStepAccount!

    private var mail: MailCatcher { MailCatcher(base: account.mailCatcher!) }

    private func makeEngine(device: String) async throws -> (engine: Engine, store: InMemoryAccountStore) {
        _ = try await LocalServer.twoStepSeeded.value
        let store = InMemoryAccountStore(deviceIdentifier: device)
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                               systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(),
                                               leaks: FakePasswordLeaks()))
        await engine.start()
        return (engine, store)
    }

    private func error(_ command: () async throws -> Void) async -> EngineError? {
        do {
            try await command()
            return nil
        } catch {
            return error as? EngineError ?? .unexpected("not an EngineError")
        }
    }

    private func logIn(_ engine: Engine) async throws {
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    }

    @Test func theServerAsksForTheSecondStepAndNamesTheMethods() async throws {
        let (engine, store) = try await makeEngine(device: "7e570000-0000-4000-8000-000000000011")
        #expect(await error { try await logIn(engine) } == .twoStepLoginRequired)

        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.twoStep?.methods == [.authenticator, .email])
        // Vaultwarden shows the first two characters of the name and a star for each other one.
        let name = account.email.prefix { $0 != "@" }
        #expect(state.twoStep?.emailHint == "te" + String(repeating: "*", count: name.count - 2) + "@passvault.test")
        #expect(await store.stored == nil)

        let wrongPassword = await error {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: "not-the-master-password")
        }
        #expect(wrongPassword == .invalidCredentials)
        #expect(await engine.state.twoStep == nil)
    }

    @Test func aCodeSentByEmailLogsIn() async throws {
        let (engine, _) = try await makeEngine(device: "7e570000-0000-4000-8000-000000000012")
        #expect(await error { try await logIn(engine) } == .twoStepLoginRequired)

        try await mail.deleteMail(to: account.email)
        try await engine.sendTwoStepEmail()
        let code = try await mail.latestCode(to: account.email)

        // A wrong code is refused and the log-in keeps waiting.
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(await error { try await engine.submitTwoStepCode(wrong, method: .email, rememberDevice: false) } == .invalidTwoStepCode)
        #expect(await engine.state.twoStep != nil)

        try await engine.submitTwoStepCode(code, method: .email, rememberDevice: false)
        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.session.account?.email == account.email)
        #expect(state.twoStep == nil)
    }

    @Test func aCodeOfTheAuthenticatorAppLogsInAndTheDeviceIsRemembered() async throws {
        let (engine, store) = try await makeEngine(device: "7e570000-0000-4000-8000-000000000013")
        #expect(await error { try await logIn(engine) } == .twoStepLoginRequired)

        // The server takes each code of the authenticator app once. After a run shortly before
        // this one, the code of the same thirty seconds is refused: wait for the next one.
        var result = await error {
            try await engine.submitTwoStepCode(try await DevelopmentSeed.authenticatorCode(account), method: .authenticator,
                                               rememberDevice: true)
        }
        if result == .invalidTwoStepCode {
            let untilNextCode = 31 - Int(Date().timeIntervalSince1970) % 30
            try await Task.sleep(for: .seconds(untilNextCode))
            result = await error {
                try await engine.submitTwoStepCode(try await DevelopmentSeed.authenticatorCode(account), method: .authenticator,
                                                   rememberDevice: true)
            }
        }
        #expect(result == nil)
        #expect(await engine.state.session.isUnlocked)
        #expect(await store.rememberTokens.count == 1)

        // The remembered device logs in again without a second step.
        try await engine.logOut()
        try await logIn(engine)
        #expect(await engine.state.session.isUnlocked)

        // Without the token the same device is asked again.
        try await engine.logOut()
        try await store.saveTwoStepRememberToken(nil, server: account.server, email: account.email)
        #expect(await error { try await logIn(engine) } == .twoStepLoginRequired)
    }
}
