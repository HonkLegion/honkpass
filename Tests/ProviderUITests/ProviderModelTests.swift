import AutoFillBridge
import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel
@testable import ProviderUI

/// The app as the extension reaches it: an engine on fakes that answers as the real one does,
/// or an app that is not running and answers nothing.
private actor FakeApp: AutoFillAsking {
    let engine: Engine
    private var isRunning: Bool
    /// How long the answer to "status" takes: an app that is slow to say how its vault is.
    private var statusDelay: Duration?

    init(engine: Engine, isRunning: Bool = true) {
        self.engine = engine
        self.isRunning = isRunning
    }

    func setRunning(_ isRunning: Bool) {
        self.isRunning = isRunning
    }

    func setStatusDelay(_ delay: Duration?) {
        statusDelay = delay
    }

    func ask(_ request: AutoFillRequest) async -> AutoFillResponse {
        guard isRunning else { return .failure(.unavailable) }
        if request == .status, let statusDelay { try? await Task.sleep(for: statusDelay) }
        return await engine.autoFill(request)
    }
}

/// What the model asked of the system around it.
@MainActor private final class Recorder {
    var outcomes: [ProviderModel.Outcome] = []
    var opens: [Bool] = []
    /// What the system was asked to verify the user for, and what it answers.
    var verifications: [ProviderModel.Verification] = []
    var verdict: Bool? = true

    var actions: ProviderModel.Actions {
        ProviderModel.Actions(openApp: { [self] in opens.append($0) }, finish: { [self] in outcomes.append($0) },
                              verifyUser: { [self] purpose in
                                  verifications.append(purpose)
                                  return verdict
                              })
    }
}

@MainActor @Suite struct ProviderModelTests {
    private func unlockedApp() async throws -> FakeApp {
        let (ports, _) = EnginePorts.fake(.demo)
        let engine = Engine(ports: ports)
        await engine.start()
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        return FakeApp(engine: engine)
    }

    private func model(_ request: ProviderModel.Request, _ app: FakeApp, _ recorder: Recorder) -> ProviderModel {
        ProviderModel(request: request, asking: app, pause: .milliseconds(10), touchIDReason: "unlock your vault",
                      actions: recorder.actions)
    }

    /// An app whose vault is locked and can be opened with Touch ID.
    private func lockedAppWithTouchID(asksAtOnce: Bool = false) async throws -> (app: FakeApp, biometrics: FakeBiometricKeys) {
        let (ports, handles) = EnginePorts.fake(.demo)
        let engine = Engine(ports: ports)
        await engine.start()
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        await handles.biometrics.setSensorAvailable(true)
        await engine.refreshBiometrics()
        try await engine.setBiometricUnlock(true)
        if asksAtOnce {
            var settings = await engine.state.settings
            settings.asksForBiometricsOnStart = true
            try await engine.setSettings(settings)
        }
        await engine.lock()
        return (FakeApp(engine: engine), handles.biometrics)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func password(of id: String, in app: FakeApp) async throws -> AutoFillPassword {
        let item = try await app.engine.item(id: id)
        return AutoFillPassword(username: item.value(of: .username) ?? "", password: item.value(of: .password) ?? "")
    }

    @Test func theListHasTheLoginsOfTheWebsiteFirstAndASearchFindsByNameAndUserName() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: ["https://item-2.example/login"]), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .list })
        #expect(model.sections.map(\.kind) == [.suggestions, .allItems])
        #expect(model.sections.map { $0.logins.map(\.name) } == [["Example Shop"], ["Example Mail"]])
        // No login of the trash, and nothing that is no login.
        #expect(model.sections.flatMap(\.logins).count == 2)
        #expect(model.selected?.name == "Example Shop")

        model.search = "máil"
        #expect(model.isSearching)
        #expect(model.sections.map(\.kind) == [.searchResults])
        #expect(model.sections.first?.logins.map(\.name) == ["Example Mail"])
        model.search = "SHOPPER"
        #expect(model.sections.first?.logins.map(\.name) == ["Example Shop"])
        model.search = "no such login"
        #expect(model.sections.isEmpty && model.selected == nil)
        #expect(recorder.outcomes.isEmpty && recorder.opens.isEmpty)
    }

    @Test func withoutAWebsiteEveryLoginIsInOneList() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .list })
        #expect(model.sections.map(\.kind) == [.allItems])
        #expect(model.sections.first?.logins.count == 2)
    }

    @Test func theKeysMoveOverTheLoginsAndTheChosenOneGoesToTheSystem() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: ["item-2.example"]), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .list })

        model.move(-1)
        #expect(model.selected?.itemID == "item-2")
        model.move(1)
        #expect(model.selected?.itemID == "item-1")
        model.move(1)
        #expect(model.selected?.itemID == "item-1")
        model.chooseSelected()

        #expect(await eventually { !recorder.outcomes.isEmpty })
        #expect(recorder.outcomes == [.password(try await password(of: "item-1", in: app))])
        // The request has ended: nothing more is asked or told.
        model.cancel()
        #expect(recorder.outcomes.count == 1)
    }

    @Test func aLockedVaultAsksForThePinAndThenGivesTheLoginOfTheSystem() async throws {
        let app = try await unlockedApp()
        try await app.engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        let expected = try await password(of: "item-1", in: app)
        await app.engine.lock()
        let recorder = Recorder()
        let model = model(.login(itemID: "item-1"), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: true) })
        model.submitPin()
        #expect(model.problem == .pinRequired)
        model.pin = "0000"
        model.submitPin()
        #expect(await eventually { model.problem == .wrongPin })
        // A wrong PIN stays in the field.
        #expect(model.pin == "0000" && recorder.outcomes.isEmpty)

        model.pin = "4812"
        model.submitPin()
        #expect(await eventually { !recorder.outcomes.isEmpty })
        #expect(recorder.outcomes == [.password(expected)])
        #expect(model.pin.isEmpty)
    }

    @Test func aPinTypedWhileTheExtensionLooksAtTheVaultIsNotLost() async throws {
        let app = try await unlockedApp()
        try await app.engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        let expected = try await password(of: "item-1", in: app)
        await app.engine.lock()
        let recorder = Recorder()
        let model = model(.login(itemID: "item-1"), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: true) })

        // The app answers slowly from now on, so a look at the vault is always on its way,
        // and its answer, "locked", comes after the PIN has opened the vault.
        await app.setStatusDelay(.milliseconds(60))
        try? await Task.sleep(for: .milliseconds(40))
        model.pin = "4812"
        model.submitPin()
        #expect(await eventually { !recorder.outcomes.isEmpty })
        #expect(recorder.outcomes == [.password(expected)])
    }

    @Test func tooManyWrongPinsEndWithALoggedOutAccount() async throws {
        let app = try await unlockedApp()
        try await app.engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        await app.engine.lock()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: true) })

        for _ in 0..<10 where model.screen != .loggedOut {
            model.pin = "0000"
            model.submitPin()
            _ = await eventually { !model.isBusy }
        }
        #expect(model.screen == .loggedOut)
        #expect(model.problem == .tooManyWrongPins)
        #expect(recorder.outcomes.isEmpty)
    }

    @Test func touchIDOpensTheVaultFromTheWindow() async throws {
        let (app, biometrics) = try await lockedAppWithTouchID()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: false, withTouchID: true) })
        // The window does not ask by itself: the account has no "ask at the start".
        try await Task.sleep(for: .milliseconds(60))
        #expect(await biometrics.reasons.isEmpty)

        // A question that the user closes leaves the window as it is, without a problem.
        await biometrics.setAnswer(.cancel)
        model.unlockWithTouchID()
        #expect(await eventually { !model.isBusy })
        #expect(model.screen == .locked(account: "demo@passvault.test", withPin: false, withTouchID: true) && model.problem == nil)

        // One that fails is told.
        await biometrics.setAnswer(.fail)
        model.unlockWithTouchID()
        #expect(await eventually { model.problem == .touchIDFailed })

        await biometrics.setAnswer(.accept)
        model.unlockWithTouchID()
        #expect(await eventually { model.screen == .list })
        #expect(model.problem == nil)
        #expect(await biometrics.reasons.last == "unlock your vault")
    }

    @Test func theWindowAsksForTouchIDByItselfOnceWhenTheAccountWantsIt() async throws {
        let (app, biometrics) = try await lockedAppWithTouchID(asksAtOnce: true)
        await biometrics.setAnswer(.cancel)
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: false, withTouchID: true) })
        for _ in 0..<200 where await biometrics.reasons.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        // The user closed the question: the window goes on looking and does not ask again.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await biometrics.reasons.count == 1)
        #expect(model.screen == .locked(account: "demo@passvault.test", withPin: false, withTouchID: true))

        await biometrics.setAnswer(.accept)
        model.unlockWithTouchID()
        #expect(await eventually { model.screen == .list })
    }

    @Test func withoutAPinTheAppUnlocksAndTheExtensionGoesOnByItself() async throws {
        let app = try await unlockedApp()
        await app.engine.lock()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: false) })
        // A PIN that nobody set is not sent.
        model.pin = "4812"
        model.submitPin()
        #expect(!model.isBusy)
        model.openApp()
        #expect(recorder.opens == [true])

        try await app.engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(await eventually { model.screen == .list })
        #expect(recorder.outcomes.isEmpty)
    }

    @Test func anAppThatIsNotRunningIsStartedOnceBehindTheOtherApps() async throws {
        let app = try await unlockedApp()
        await app.setRunning(false)
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()

        // A connection failure cannot establish that the vault is locked.
        #expect(await eventually { recorder.opens == [false] })
        #expect(model.screen == .loading)
        #expect(await eventually { model.screen == .unavailable })
        #expect(recorder.opens == [false])
        model.pin = "4812"
        model.submitPin()
        #expect(!model.isBusy)

        await app.setRunning(true)
        #expect(await eventually { model.screen == .list })
    }

    @Test func aLoginThatAsksForTheMasterPasswordIsNotGivenFromTheExtension() async throws {
        let app = try await unlockedApp()
        var draft = try await app.engine.draft(of: "item-2")
        draft.asksForMasterPassword = true
        _ = try await app.engine.save(draft)

        let recorder = Recorder()
        let list = model(.chooseLogin(services: ["item-2.example"]), app, recorder)
        list.start()
        #expect(await eventually { list.screen == .list })
        let protected = try #require(list.sections.flatMap(\.logins).first { $0.itemID == "item-2" })
        #expect(protected.asksForMasterPassword)
        // The keyboard passes it over, and a click does nothing.
        #expect(list.selected?.itemID == "item-1")
        list.choose(protected)
        #expect(!list.isBusy && recorder.outcomes.isEmpty)

        // The system does not have it among its entries; an old entry finds nothing.
        #expect(await !app.engine.state.vault.passwordIdentities.contains { $0.itemID == "item-2" })
        let named = model(.login(itemID: "item-2"), app, recorder)
        named.start()
        #expect(await eventually { recorder.outcomes == [.notFound] })
    }

    @Test func cancelEndsTheRequestOnce() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.chooseLogin(services: []), app, recorder)
        model.start()
        #expect(await eventually { model.screen == .list })

        model.cancel()
        model.cancel()
        model.chooseSelected()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.outcomes == [.cancelled])
    }

    // MARK: Passkeys

    private let hash = Data("fake-client-data-hash".utf8)

    private func question(_ rpID: String = "passkey.example", _ verification: PasskeyUserVerification = .preferred) -> ProviderModel.PasskeyQuestion {
        ProviderModel.PasskeyQuestion(rpID: rpID, clientDataHash: hash, userVerification: verification)
    }

    private func newPasskey(_ rpID: String = "passkey.example", user: String = "user-1", excluded: [Data] = [],
                            verification: PasskeyUserVerification = .preferred) -> PasskeyRegistrationRequest {
        PasskeyRegistrationRequest(rpID: rpID, userName: "demo-passkey", userHandle: Data(user.utf8), clientDataHash: hash,
                                   algorithms: [-7], excludedCredentialIDs: excluded, userVerification: verification,
                                   isUserVerified: false)
    }

    /// Makes a passkey in the vault of the app, in a new login or in the login that is named.
    private func makePasskey(in app: FakeApp, _ rpID: String = "passkey.example", user: String = "user-1",
                             into itemID: String? = nil) async throws -> PasskeyRegistration {
        var request = newPasskey(rpID, user: user)
        request.itemID = itemID
        request.isUserVerified = true
        guard case .passkeyRegistration(let registration) = await app.engine.autoFill(.registerPasskey(request)) else {
            throw EngineError.notFound
        }
        return registration
    }

    @Test func theOnlyPasskeyOfAWebsiteSignsWithoutAListOnceTheSystemHasVerifiedTheUser() async throws {
        let app = try await unlockedApp()
        let registration = try await makePasskey(in: app)
        let recorder = Recorder()
        let model = model(.choosePasskey(question()), app, recorder)
        model.start()

        #expect(await eventually { !recorder.outcomes.isEmpty })
        #expect(recorder.verifications == [.assertion(rpID: "passkey.example", username: "demo-passkey")])
        guard case .assertion(let assertion) = recorder.outcomes.first else {
            Issue.record("expected a signature")
            return
        }
        #expect(assertion.credentialID == registration.credentialID && assertion.rpID == "passkey.example")
        #expect(assertion.authenticatorData == Data("fake-authenticator-data:verified".utf8))
        #expect(assertion.signature == Data("fake-signature:".utf8) + hash)
    }

    @Test func aWebsiteThatDoesNotCareGetsItsSignatureWithoutAQuestion() async throws {
        let app = try await unlockedApp()
        _ = try await makePasskey(in: app)
        let recorder = Recorder()
        let model = model(.choosePasskey(question("passkey.example", .discouraged)), app, recorder)
        model.start()

        #expect(await eventually { !recorder.outcomes.isEmpty })
        #expect(recorder.verifications.isEmpty)
        guard case .assertion(let assertion) = recorder.outcomes.first else {
            Issue.record("expected a signature")
            return
        }
        #expect(assertion.authenticatorData == Data("fake-authenticator-data:present".utf8))
    }

    @Test func aUserWhoIsNotVerifiedGetsNoSignatureWhereTheWebsiteAsksForOne() async throws {
        let app = try await unlockedApp()
        let registration = try await makePasskey(in: app)
        let login = try #require(await app.engine.state.vault.items.first { !$0.passkeys.isEmpty })

        // The user closes the question of the system: the request ends as cancelled.
        let closed = Recorder()
        closed.verdict = nil
        // A model lives as long as the window that shows it; here the test keeps it.
        let first = model(.passkey(itemID: login.id, question("passkey.example", .required)), app, closed)
        first.start()
        #expect(await eventually { closed.outcomes == [.cancelled] })

        // The system cannot verify: a website that asks for it gets nothing, one that would
        // only rather have it gets a signature of a user who is present.
        let refused = Recorder()
        refused.verdict = false
        let second = model(.passkey(itemID: login.id, question("passkey.example", .required)), app, refused)
        second.start()
        #expect(await eventually { refused.outcomes == [.failed] })
        let preferred = Recorder()
        preferred.verdict = false
        let third = model(.passkey(itemID: login.id, question("passkey.example", .preferred)), app, preferred)
        third.start()
        #expect(await eventually { !preferred.outcomes.isEmpty })
        guard case .assertion(let assertion) = preferred.outcomes.first else {
            Issue.record("expected a signature")
            return
        }
        #expect(assertion.credentialID == registration.credentialID)
        #expect(assertion.authenticatorData == Data("fake-authenticator-data:present".utf8))
    }

    @Test func thePinOfTheVaultVerifiesTheUserForAPasskey() async throws {
        let app = try await unlockedApp()
        _ = try await makePasskey(in: app)
        let login = try #require(await app.engine.state.vault.items.first { !$0.passkeys.isEmpty })
        try await app.engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        await app.engine.lock()
        let recorder = Recorder()
        let model = model(.passkey(itemID: login.id, question("passkey.example", .required)), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .locked(account: "demo@passvault.test", withPin: true) })
        model.pin = "4812"
        model.submitPin()
        #expect(await eventually { !recorder.outcomes.isEmpty })
        // The system is not asked a second time.
        #expect(recorder.verifications.isEmpty)
        guard case .assertion(let assertion) = recorder.outcomes.first else {
            Issue.record("expected a signature")
            return
        }
        #expect(assertion.authenticatorData == Data("fake-authenticator-data:verified".utf8))
    }

    @Test func severalPasskeysOfAWebsiteAreListedAndTheChosenOneSigns() async throws {
        let app = try await unlockedApp()
        let first = try await makePasskey(in: app, user: "user-1")
        let second = try await makePasskey(in: app, user: "user-2")
        let recorder = Recorder()
        let model = model(.choosePasskey(question()), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .passkeys })
        #expect(Set(model.passkeys.map(\.credentialID)) == [first.credentialID, second.credentialID])
        #expect(recorder.outcomes.isEmpty && recorder.verifications.isEmpty)
        #expect(model.selectedRowID == model.passkeys[0].id)
        model.move(1)
        #expect(model.selectedRowID == model.passkeys[1].id)
        model.chooseSelected()

        #expect(await eventually { !recorder.outcomes.isEmpty })
        guard case .assertion(let assertion) = recorder.outcomes.first else {
            Issue.record("expected a signature")
            return
        }
        #expect(assertion.credentialID == model.passkeys[1].credentialID)
    }

    @Test func aWebsiteWithoutAPasskeyInTheVaultGetsANotice() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.choosePasskey(question()), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .noPasskeys })
        model.closeNotice()
        #expect(recorder.outcomes == [.notFound])
    }

    @Test func aNewPasskeyOfAWebsiteWithoutALoginGetsANewLoginAtOnce() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let model = model(.newPasskey(newPasskey()), app, recorder)
        model.start()

        #expect(await eventually { !recorder.outcomes.isEmpty })
        guard case .registration(let registration) = recorder.outcomes.first else {
            Issue.record("expected a new passkey")
            return
        }
        #expect(recorder.verifications == [.registration(rpID: "passkey.example", username: "demo-passkey")])
        let login = try #require(await app.engine.state.vault.items.first { !$0.passkeys.isEmpty })
        #expect(login.name == "passkey.example" && login.passkeys.map(\.credentialID) == [registration.credentialID])
    }

    @Test func aNewPasskeyCanGoIntoALoginOfTheWebsiteAndAsksBeforeItReplacesOne() async throws {
        let app = try await unlockedApp()
        let recorder = Recorder()
        let first = model(.newPasskey(newPasskey("item-2.example")), app, recorder)
        first.start()

        #expect(await eventually { first.screen == .passkeyTargets })
        #expect(first.targets.map(\.itemID) == ["item-2"] && first.targets[0].hasPasskey == false)
        // The keys reach the login and the row "save as new login".
        #expect(first.selectedRowID == "item-2")
        first.move(1)
        #expect(first.selectedRowID == ProviderModel.newLoginRow)
        first.move(-1)
        first.chooseSelected()
        #expect(await eventually { !recorder.outcomes.isEmpty })
        guard case .registration(let made) = recorder.outcomes.first else {
            Issue.record("expected a new passkey")
            return
        }
        #expect(await app.engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.map(\.credentialID) == [made.credentialID])

        // The login has a passkey now: a second one asks first, and "no" leaves all as it is.
        let again = Recorder()
        let second = model(.newPasskey(newPasskey("item-2.example")), app, again)
        second.start()
        #expect(await eventually { second.screen == .passkeyTargets })
        let login = try #require(second.targets.first)
        #expect(login.hasPasskey)
        second.save(into: login)
        #expect(second.overwriting == login && !second.isBusy)
        second.answerOverwrite(false)
        #expect(second.overwriting == nil && again.outcomes.isEmpty)

        second.save(into: login)
        second.answerOverwrite(true)
        #expect(await eventually { !again.outcomes.isEmpty })
        #expect(again.verifications == [.overwrite(rpID: "item-2.example", username: "demo-passkey")])
        guard case .registration(let replaced) = again.outcomes.first else {
            Issue.record("expected a new passkey")
            return
        }
        #expect(replaced.credentialID != made.credentialID)
        #expect(await app.engine.state.vault.items.first { $0.id == "item-2" }?.passkeys.map(\.credentialID) == [replaced.credentialID])
    }

    @Test func aPasskeyThatTheWebsiteExcludesIsNotMadeTwice() async throws {
        let app = try await unlockedApp()
        let existing = try await makePasskey(in: app)
        let recorder = Recorder()
        let model = model(.newPasskey(newPasskey(user: "user-2", excluded: [existing.credentialID])), app, recorder)
        model.start()

        #expect(await eventually { model.screen == .passkeyExists })
        #expect(recorder.outcomes.isEmpty)
        model.closeNotice()
        #expect(recorder.outcomes == [.passkeyExists])
        #expect(await app.engine.state.vault.items.flatMap(\.passkeys).count == 1)
    }
}
