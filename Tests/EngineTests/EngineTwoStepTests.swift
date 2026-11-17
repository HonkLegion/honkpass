@testable import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineTwoStepTests {
    let account = FakeAccount.demoWithTwoStep

    @Test func initialSyncKeepsChallengeUntilUnlockedStateIsPublished() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        let stream = await engine.states()
        await handles.server.holdNextSync()
        let login = Task { try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false) }
        await handles.server.syncIsHeld()
        let loading = await engine.state
        #expect(loading.activity == .loadingVault)
        #expect(loading.authenticationPhase == .syncing)
        #expect(loading.session == .loggedOut)
        #expect(loading.twoStep != nil)
        await handles.server.releaseSync()
        try await login.value
        for await state in stream {
            // There must be no transient email screen or false two-step timeout.
            #expect(state.twoStep != nil || state.session.isUnlocked)
            if state.session.isUnlocked { break }
        }
    }

    /// A started engine whose log-in waits for the second step.
    private func makeWaitingEngine(clock: any Clock<Duration> = ContinuousClock()) async throws -> (engine: Engine, handles: FakeHandles) {
        let result = await makeEngine(account: account, clock: clock)
        #expect(await engineError { try await logIn(result.engine) } == .twoStepLoginRequired)
        return result
    }

    private func logIn(_ engine: Engine) async throws {
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    }

    @Test func theRightMasterPasswordAsksForTheSecondStep() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.activity == nil)
        #expect(state.twoStep == TwoStepChallenge(methods: [.authenticator, .email], emailHint: "de**@passvault.test"))
        #expect(state.vault == .empty)
        #expect(await handles.store.stored == nil)
    }

    @Test func aWrongMasterPasswordDoesNotReachTheSecondStep() async {
        let (engine, _) = await makeEngine(account: account)
        let error = await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: "wrong")
        }
        #expect(error == .invalidCredentials)
        #expect(await engine.state.twoStep == nil)
    }

    @Test func theRightCodeFinishesTheLogIn() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false)

        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.twoStep == nil)
        #expect(state.vault.items == account.contents.items)
        #expect(await handles.store.stored?.account.email == account.email)
        #expect(await handles.store.rememberTokens.isEmpty)
    }

    @Test func aCodeIsTakenWithTheSpacesOfAnAuthenticatorApp() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        try await engine.submitTwoStepCode(" 123 456\n", method: .email, rememberDevice: false)
        #expect(await engine.state.session.isUnlocked)
        #expect(await handles.server.logInProofs.last == TwoStepProof(kind: .method(.email), token: "123456", remember: false))
    }

    @Test func aWrongCodeKeepsTheLogInWaiting() async throws {
        let (engine, _) = try await makeWaitingEngine()
        #expect(await engineError { try await engine.submitTwoStepCode("000000", method: .authenticator, rememberDevice: false) }
            == .invalidTwoStepCode)
        #expect(await engineError { try await engine.submitTwoStepCode("  ", method: .authenticator, rememberDevice: false) }
            == .invalidTwoStepCode)
        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.activity == nil)
        #expect(state.twoStep != nil)

        try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aCodeNeedsAWaitingLogInAndAMethodOfTheAccount() async throws {
        let (plain, _) = await makeEngine()
        #expect(await engineError { try await plain.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false) }
            == .invalidState)
        #expect(await engineError { try await plain.sendTwoStepEmail() } == .invalidState)

        var onlyApp = account
        onlyApp.twoStep = FakeAccount.TwoStep(methods: [.authenticator])
        let (engine, _) = await makeEngine(account: onlyApp)
        _ = await engineError { try await logIn(engine) }
        #expect(await engineError { try await engine.submitTwoStepCode("123456", method: .email, rememberDevice: false) } == .invalidState)
        #expect(await engineError { try await engine.sendTwoStepEmail() } == .invalidState)
    }

    @Test func theServerSendsACodeByEmailWhenAsked() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        try await engine.sendTwoStepEmail()
        try await engine.sendTwoStepEmail()
        #expect(await handles.server.twoStepEmailCount == 2)
        #expect(await engine.state.twoStep != nil)
    }

    @Test func aRememberedDeviceIsNotAskedAgain() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: true)
        let saved = await handles.store.rememberTokens
        #expect(saved.count == 1)

        // The token survives the logout and replaces the second step of the next log-in.
        try await engine.logOut()
        #expect(await handles.store.rememberTokens == saved)
        try await logIn(engine)
        #expect(await engine.state.session.isUnlocked)
        #expect(await handles.server.logInProofs.last??.kind == .rememberedDevice)
    }

    @Test func aTokenTheServerNoLongerTakesIsForgottenAndTheCodeIsAskedAgain() async throws {
        let (engine, handles) = try await makeWaitingEngine()
        try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: true)
        try await engine.logOut()
        await handles.server.forgetRememberedDevice()

        #expect(await engineError { try await logIn(engine) } == .twoStepLoginRequired)
        #expect(await handles.store.rememberTokens.isEmpty)
        #expect(await engine.state.twoStep != nil)
    }

    @Test func aSecurityKeyAnswersThroughTheConnectorPageOfTheServer() async throws {
        var withKey = account
        withKey.twoStep = FakeAccount.TwoStep(methods: [.webAuthn, .authenticator])
        let (engine, handles) = await makeEngine(account: withKey)
        #expect(await engineError {
            try await engine.logIn(server: withKey.server, email: withKey.email, masterPassword: withKey.masterPassword)
        } == .twoStepLoginRequired)
        let challenge = try #require(await engine.state.twoStep)
        #expect(challenge.methods == [.webAuthn, .authenticator])
        let request = try #require(challenge.webAuthnRequest)

        // The page of the server, with the request and the texts inside its "data".
        let page = try #require(WebAuthnConnector.url(server: URL(string: "https://vault.example/base/")!, request: request,
                                                      header: "Read the key", button: "Read security key", returnButton: "Back"))
        let parts = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false))
        #expect(parts.host == "vault.example" && parts.path == "/base/webauthn-mobile-connector.html")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["v"] == "2" && query["parent"] == "bitwarden://webauthn-callback")
        let encoded = try #require(query["data"])
        let data = try #require(Data(base64Encoded: encoded))
        let inside = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(inside["data"] == request && inside["callbackUri"] == "bitwarden://webauthn-callback")
        #expect(inside["btnText"] == "Read%20security%20key" && inside["headerText"] == "Read%20the%20key")
        #expect(WebAuthnConnector.url(server: URL(string: "file:///tmp")!, request: request, header: "", button: "", returnButton: "") == nil)

        // What the page ends with: the answer of the key, or anything else, which is a failure.
        var answer = URLComponents(string: "bitwarden://webauthn-callback")!
        answer.queryItems = [URLQueryItem(name: "data", value: FakeAccount.TwoStep.webAuthnAnswer)]
        #expect(WebAuthnConnector.outcome(ofCallback: try #require(answer.url)) == .token(FakeAccount.TwoStep.webAuthnAnswer))
        for other in ["bitwarden://webauthn-callback?error=NotAllowedError", "bitwarden://webauthn-callback?data=not-json",
                      "bitwarden://webauthn-callback?data=%7B%22id%22%3A%22x%22%7D", "bitwarden://sso-callback?data=%7B%7D",
                      "https://vault.example/webauthn-callback?data=%7B%7D"] {
            #expect(WebAuthnConnector.outcome(ofCallback: try #require(URL(string: other))) == .failed)
        }

        // Another answer than the one the server asked for is a wrong code; the right one logs in, as it came.
        #expect(await engineError { try await engine.submitTwoStepCode("{}", method: .webAuthn, rememberDevice: false) }
            == .invalidTwoStepCode)
        try await engine.submitTwoStepCode(FakeAccount.TwoStep.webAuthnAnswer, method: .webAuthn, rememberDevice: true)
        #expect(await engine.state.session.isUnlocked)
        let proof = try #require(await handles.server.logInProofs.last ?? nil)
        #expect(proof.kind == .method(.webAuthn) && proof.token == FakeAccount.TwoStep.webAuthnAnswer && proof.remember)
    }

    @Test func anAccountWithOtherMethodsOnlyCannotLogIn() async {
        var unsupported = account
        unsupported.twoStep = FakeAccount.TwoStep(methods: [])
        let (engine, _) = await makeEngine(account: unsupported)
        #expect(await engineError { try await logIn(engine) } == .twoStepMethodsUnsupported)
        let state = await engine.state
        #expect(state.twoStep == nil)
        #expect(state.session == .loggedOut)
    }

    @Test func cancelForgetsTheWaitingLogIn() async throws {
        let (engine, _) = try await makeWaitingEngine()
        await engine.cancelTwoStepLogin()
        #expect(await engine.state.twoStep == nil)
        #expect(await engineError { try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false) }
            == .invalidState)
        // The engine is ready for a new log-in.
        #expect(await engineError { try await logIn(engine) } == .twoStepLoginRequired)
    }

    @Test func aNewLogInReplacesTheWaitingOne() async throws {
        let (engine, _) = try await makeWaitingEngine()
        let error = await engineError {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: "wrong")
        }
        #expect(error == .invalidCredentials)
        #expect(await engine.state.twoStep == nil)
    }

    @Test func aLogInThatWaitsTooLongIsGivenUp() async throws {
        let clock = ManualClock()
        let (engine, _) = try await makeWaitingEngine(clock: clock)
        await clock.waitForSleeper()
        clock.advance(by: Engine.twoStepPatience - .seconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(await engine.state.twoStep != nil)

        clock.advance(by: .seconds(1))
        _ = try await nextState(of: engine) { $0.twoStep == nil }
        #expect(await engineError { try await engine.submitTwoStepCode("123456", method: .authenticator, rememberDevice: false) }
            == .invalidState)
    }
}
