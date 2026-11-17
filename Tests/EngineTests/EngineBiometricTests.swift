@testable import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Touch ID opens the locked vault with the key that the Keychain of the system keeps.
@Suite struct EngineBiometricTests {
    let account = FakeAccount.demo
    let reason = "unlock your vault"

    /// An unlocked engine on a Mac that has a sensor in reach.
    private func engineWithSensor() async throws -> (engine: Engine, handles: FakeHandles) {
        let result = try await makeUnlockedEngine()
        await result.handles.biometrics.setSensorAvailable(true)
        await result.engine.refreshBiometrics()
        return result
    }

    private func lockedEngineWithTouchID() async throws -> (engine: Engine, handles: FakeHandles) {
        let result = try await engineWithSensor()
        try await result.engine.setBiometricUnlock(true)
        await result.engine.lock()
        return result
    }

    @Test func aMacWithoutASensorOffersNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await engine.state.biometrics == .none)
        #expect(await engineError { try await engine.setBiometricUnlock(true) } == .biometrics(.unavailable))
        #expect(await handles.biometrics.kept.isEmpty)
        await engine.lock()
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.notEnabled))
    }

    @Test func turningItOnKeepsTheKeyAndTurningItOffRemovesIt() async throws {
        let (engine, handles) = try await engineWithSensor()
        #expect(await engine.state.biometrics == BiometricState(isAvailable: true, isEnabled: false))

        try await engine.setBiometricUnlock(true)
        #expect(await engine.state.biometrics == BiometricState(isAvailable: true, isEnabled: true))
        #expect(await engine.state.biometrics.canUnlock)
        // The key of the account is with the Keychain, and it was asked nothing for it.
        #expect(await handles.biometrics.kept.keys.sorted() == [account.userID])
        #expect(await handles.biometrics.reasons.isEmpty)

        try await engine.setBiometricUnlock(false)
        #expect(await engine.state.biometrics == BiometricState(isAvailable: true, isEnabled: false))
        #expect(await handles.biometrics.kept.isEmpty)
        // It is turned on for an unlocked vault only: the key comes out of it.
        await engine.lock()
        #expect(await engineError { try await engine.setBiometricUnlock(true) } == .invalidState)
        #expect(await handles.biometrics.kept.isEmpty)
    }

    @Test func aKeyThatTheSystemDoesNotKeepLeavesItOff() async throws {
        let (engine, handles) = try await engineWithSensor()
        await handles.biometrics.failNextKeep()
        #expect(await engineError { try await engine.setBiometricUnlock(true) } == .biometrics(.failed))
        #expect(await !engine.state.biometrics.isEnabled)
        #expect(await handles.biometrics.kept.isEmpty)
    }

    @Test func touchIDOpensTheLockedVault() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        #expect(await engine.state.biometrics.canUnlock)

        try await engine.unlockWithBiometrics(reason: reason)

        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.vault.items == account.contents.items)
        #expect(state.activity == nil)
        // The question of the system said what the client gave it to say.
        #expect(await handles.biometrics.reasons == [reason])
        // The key stays for the next time, and the vault is open: nothing to unlock.
        #expect(await handles.biometrics.kept[account.userID] != nil)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .invalidState)
    }

    @Test func aCancelledOrFailedQuestionLeavesTheVaultLocked() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()

        await handles.biometrics.setAnswer(.cancel)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.cancelled))
        await handles.biometrics.setAnswer(.fail)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.failed))

        let state = await engine.state
        #expect(!state.session.isUnlocked && state.vault.items.isEmpty && state.activity == nil)
        // The key is kept, and the next finger opens the vault.
        #expect(state.biometrics.canUnlock)
        await handles.biometrics.setAnswer(.accept)
        try await engine.unlockWithBiometrics(reason: reason)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aSensorThatIsGoneIsNoWayToUnlock() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        // The keyboard with the sensor is taken away. The engine learns of it when it is asked.
        await handles.biometrics.setSensorAvailable(false)
        await engine.refreshBiometrics()
        #expect(await engine.state.biometrics == BiometricState(isAvailable: false, isEnabled: true))
        #expect(await !engine.state.biometrics.canUnlock)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.unavailable))
        // It comes back: the key was kept all the time.
        await handles.biometrics.setSensorAvailable(true)
        await engine.refreshBiometrics()
        try await engine.unlockWithBiometrics(reason: reason)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func theMasterPasswordOpensTheVaultWhileTheSystemAsks() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        await handles.biometrics.holdNextQuestion()
        let asking = Task { await engineError { try await engine.unlockWithBiometrics(reason: reason) } }
        for _ in 0..<200 where await !handles.biometrics.isAsking { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await handles.biometrics.isAsking)

        // The engine holds no command while a person answers; a second question is not asked.
        #expect(await engine.state.activity == nil)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .busy)
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.session.isUnlocked)

        // The finger comes late: the vault is open already, and the key opens nothing twice.
        await handles.biometrics.answerQuestion()
        #expect(await asking.value == .cancelled)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aKeyThatNoLongerOpensTheAccountIsRemoved() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        // As after a change of the keys of the account on another device.
        await handles.biometrics.setKept("fake-user-key:of-another-time", accountID: account.userID)

        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.keyRejected))

        #expect(await !engine.state.session.isUnlocked)
        #expect(await handles.biometrics.kept.isEmpty)
        #expect(await engine.state.biometrics == BiometricState(isAvailable: true, isEnabled: false))
        // The master password still opens the vault.
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aKeyThatIsGoneFromTheKeychainTurnsItOff() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        await handles.biometrics.setKept(nil, accountID: account.userID)
        // The engine still believes in the key until it asks for it.
        #expect(await engine.state.biometrics.isEnabled)
        #expect(await engineError { try await engine.unlockWithBiometrics(reason: reason) } == .biometrics(.notEnabled))
        #expect(await !engine.state.biometrics.isEnabled)
    }

    @Test func aPinThatWaitedForTheMasterPasswordWorksAgainAfterTouchID() async throws {
        let (engine, handles) = try await engineWithSensor()
        try await engine.setBiometricUnlock(true)
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: true)
        // A restart: the envelope of such a PIN is in no file.
        let stored = try #require(await handles.store.stored)
        let pins = await handles.store.pins
        let (ports, restarted) = EnginePorts.fake(account, stored: stored, pins: pins)
        await restarted.biometrics.setSensorAvailable(true)
        await restarted.biometrics.setKept(await handles.biometrics.kept[account.userID], accountID: account.userID)
        let next = Engine(ports: ports)
        await next.start()

        // The start finds the key without asking for it.
        #expect(await next.state.biometrics.canUnlock)
        #expect(await restarted.biometrics.reasons.isEmpty)
        #expect(await !next.state.pin.canUnlock)
        try await next.unlockWithBiometrics(reason: reason)
        #expect(await next.state.session.isUnlocked)
        #expect(await next.state.pin.canUnlock)
    }

    @Test func aLogOutRemovesTheKey() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        #expect(await handles.biometrics.kept[account.userID] != nil)
        try await engine.logOut()
        #expect(await handles.biometrics.kept.isEmpty)
        #expect(await engine.state.biometrics == BiometricState(isAvailable: true, isEnabled: false))
    }

    @Test func anAccountThatWaitsKeepsItsKey() async throws {
        let (engine, handles) = try await engineWithSensor()
        try await engine.setBiometricUnlock(true)

        // "Add account": the account waits, locked, and the log-in has no Touch ID.
        try await engine.addAccount()
        #expect(await !engine.state.biometrics.isEnabled)
        #expect(await handles.biometrics.kept[account.userID] != nil)

        // Back at the account, its key opens it.
        try await engine.switchAccount(to: account.userID)
        #expect(await engine.state.biometrics.canUnlock)
        try await engine.unlockWithBiometrics(reason: reason)
        #expect(await engine.state.session.isUnlocked)
    }

    // MARK: The AutoFill extension

    @Test func theAutoFillWindowLearnsOfTouchIDAndUnlocksWithIt() async throws {
        let (engine, handles) = try await lockedEngineWithTouchID()
        let locked = AutoFillResponse.status(AutoFillStatus(vault: .locked, canUnlockWithTouchID: true, account: account.email))
        #expect(await engine.autoFill(.status) == locked)

        // A question that the user closes leaves the vault locked and is no failure.
        await handles.biometrics.setAnswer(.cancel)
        #expect(await engine.autoFill(.unlockWithTouchID(reason: reason)) == locked)
        // One that fails is told as that.
        await handles.biometrics.setAnswer(.fail)
        #expect(await engine.autoFill(.unlockWithTouchID(reason: reason)) == .failure(.touchIDFailed))
        #expect(await !engine.state.session.isUnlocked)

        await handles.biometrics.setAnswer(.accept)
        let unlocked = AutoFillResponse.status(AutoFillStatus(vault: .unlocked, account: account.email))
        #expect(await engine.autoFill(.unlockWithTouchID(reason: reason)) == unlocked)
        #expect(await handles.biometrics.reasons.last == reason)
        // An open vault has nothing to unlock: the answer is its state.
        #expect(await engine.autoFill(.unlockWithTouchID(reason: reason)) == unlocked)
    }

    @Test func theStatusOfALockedVaultFollowsTheSensorAndTheSetting() async throws {
        let (engine, handles) = try await engineWithSensor()
        try await engine.setBiometricUnlock(true)
        var settings = await engine.state.settings
        settings.asksForBiometricsOnStart = true
        try await engine.setSettings(settings)
        await engine.lock()
        #expect(await engine.autoFill(.status) == .status(AutoFillStatus(
            vault: .locked, canUnlockWithTouchID: true, asksForTouchIDAtOnce: true, account: account.email)))

        // The keyboard with the sensor is taken away. Nobody tells the engine: the status looks.
        await handles.biometrics.setSensorAvailable(false)
        #expect(await engine.autoFill(.status) == .status(AutoFillStatus(
            vault: .locked, asksForTouchIDAtOnce: true, account: account.email)))
        #expect(await engine.autoFill(.unlockWithTouchID(reason: reason)) == .failure(.touchIDFailed))
    }

    @Test func aStatusOfAnOlderAppIsReadWithoutTheFieldsOfTouchID() throws {
        let old = Data(#"{"vault":"locked","canUnlockWithPin":true,"account":"user@example.com"}"#.utf8)
        #expect(try JSONDecoder().decode(AutoFillStatus.self, from: old)
            == AutoFillStatus(vault: .locked, canUnlockWithPin: true, account: "user@example.com"))
    }

    @Test func theChoiceToAskAtTheStartIsASettingOfTheAccount() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await !engine.state.settings.asksForBiometricsOnStart)
        var settings = await engine.state.settings
        settings.asksForBiometricsOnStart = true
        try await engine.setSettings(settings)
        #expect(await handles.store.settings[account.userID]?.asksForBiometricsOnStart == true)

        // A file of an older version has no such setting: it is off.
        let old = Data(#"{"showsWebsiteIcons":false}"#.utf8)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: old)
        #expect(!decoded.asksForBiometricsOnStart && !decoded.showsWebsiteIcons)
    }
}
