@testable import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EnginePinTests {
    let account = FakeAccount.demo

    private func lockedEngineWithPin(_ pin: String = "4812", asksForMasterPassword: Bool = false) async throws
        -> (engine: Engine, handles: FakeHandles) {
        let result = try await makeUnlockedEngine()
        try await result.engine.setPin(pin, asksForMasterPasswordAfterRestart: asksForMasterPassword)
        await result.engine.lock()
        return result
    }

    @Test func withoutAPinThereIsNothingToUnlockWith() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        #expect(await engine.state.pin == .none)
        await engine.lock()
        #expect(await engineError { try await engine.unlock(pin: "4812") } == .invalidState)
    }

    @Test func aPinNeedsAnUnlockedVault() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await engine.lock()
        #expect(await engineError { try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false) } == .invalidState)
        #expect(await handles.store.pins.isEmpty)
    }

    @Test func aSetPinUnlocksTheLockedVault() async throws {
        let (engine, handles) = try await lockedEngineWithPin()
        #expect(await engine.state.pin == PinState(isSet: true, asksForMasterPasswordAfterRestart: false, canUnlock: true))
        #expect(await handles.store.pins[account.userID]?.envelope != nil)

        try await engine.unlock(pin: "4812")
        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.vault.items == account.contents.items)
    }

    @Test func aWrongPinIsCountedAndTheRightOneStartsTheCountAgain() async throws {
        let (engine, handles) = try await lockedEngineWithPin()
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .wrongPin)
        #expect(await engineError { try await engine.unlock(pin: "1111") } == .wrongPin)
        #expect(await handles.store.pins[account.userID]?.failedAttempts == 2)
        #expect(await !engine.state.session.isUnlocked)

        try await engine.unlock(pin: "4812")
        #expect(await handles.store.pins[account.userID]?.failedAttempts == 0)
    }

    @Test func theMasterPasswordAlsoStartsTheCountAgain() async throws {
        let (engine, handles) = try await lockedEngineWithPin()
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .wrongPin)
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await handles.store.pins[account.userID]?.failedAttempts == 0)
        #expect(await engine.state.pin.canUnlock)
    }

    @Test func theFifthWrongPinLogsTheAccountOut() async throws {
        let (engine, handles) = try await lockedEngineWithPin()
        for _ in 1..<Engine.pinAttemptLimit {
            #expect(await engineError { try await engine.unlock(pin: "0000") } == .wrongPin)
        }
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .tooManyPinAttempts)

        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.pin == .none)
        #expect(await handles.store.stored == nil)
        #expect(await handles.store.pins.isEmpty)
    }

    @Test func theCountOfWrongPinsSurvivesARestart() async throws {
        let (first, handles) = try await lockedEngineWithPin()
        for _ in 0..<3 { _ = await engineError { try await first.unlock(pin: "0000") } }
        let stored = await handles.store.stored
        let pins = await handles.store.pins

        let (engine, restarted) = await makeEngine(stored: stored, pins: pins)
        #expect(await engine.state.pin.canUnlock)
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .wrongPin)
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .tooManyPinAttempts)
        #expect(await restarted.store.stored == nil)
    }

    @Test func aWrongPinThatCannotBeCountedTurnsThePinOff() async throws {
        let (engine, handles) = try await lockedEngineWithPin()
        await handles.store.failNextPinSave()
        #expect(await engineError { try await engine.unlock(pin: "0000") } == .wrongPin)
        #expect(await !engine.state.pin.canUnlock)
        #expect(await engineError { try await engine.unlock(pin: "4812") } == .invalidState)

        // The master password still opens the vault, and the PIN works again after it.
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.pin.canUnlock)
    }

    @Test func aPinThatAsksForTheMasterPasswordIsNotStoredInAFormThatUnlocks() async throws {
        let (first, handles) = try await lockedEngineWithPin(asksForMasterPassword: true)
        #expect(await first.state.pin == PinState(isSet: true, asksForMasterPasswordAfterRestart: true, canUnlock: true))
        let record = try #require(await handles.store.pins[account.userID])
        #expect(record.envelope == nil)
        // In the same run the PIN unlocks.
        try await first.unlock(pin: "4812")

        // After a restart it does not, until the master password was given.
        let stored = await handles.store.stored
        let (engine, _) = await makeEngine(stored: stored, pins: [account.userID: record])
        #expect(await engine.state.pin == PinState(isSet: true, asksForMasterPasswordAfterRestart: true, canUnlock: false))
        #expect(await engineError { try await engine.unlock(pin: "4812") } == .invalidState)

        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.pin.canUnlock)
        await engine.lock()
        try await engine.unlock(pin: "4812")
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func aStoredPinUnlocksAfterARestart() async throws {
        let (first, handles) = try await lockedEngineWithPin()
        _ = first
        let (engine, _) = await makeEngine(stored: await handles.store.stored, pins: await handles.store.pins)
        #expect(await engine.state.session == .locked(try #require(await handles.store.stored).account))
        try await engine.unlock(pin: "4812")
        #expect(await engine.state.vault.items == account.contents.items)
    }

    @Test func aNewPinReplacesTheOldOne() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        try await engine.setPin("7391", asksForMasterPasswordAfterRestart: false)
        await engine.lock()
        #expect(await engineError { try await engine.unlock(pin: "4812") } == .wrongPin)
        try await engine.unlock(pin: "7391")
    }

    @Test func removingThePinLeavesTheMasterPassword() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        try await engine.removePin()
        #expect(await engine.state.pin == .none)
        #expect(await handles.store.pins.isEmpty)
        await engine.lock()
        #expect(await engineError { try await engine.unlock(pin: "4812") } == .invalidState)
        try await engine.unlock(masterPassword: account.masterPassword)
    }

    @Test func aLogOutRemovesThePin() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        try await engine.logOut()
        #expect(await engine.state.pin == .none)
        #expect(await handles.store.pins.isEmpty)

        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await engine.state.pin == .none)
    }

    @Test func aPinThatCannotBeSavedIsNotSet() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.store.failNextPinSave()
        #expect(await engineError { try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false) }
            == .storage("The PIN could not be saved."))
        #expect(await engine.state.pin == .none)
        #expect(await engineError { try await engine.setPin("", asksForMasterPasswordAfterRestart: false) } == .wrongPin)
        #expect(await engineError { try await engine.setPin("481", asksForMasterPasswordAfterRestart: false) } == .wrongPin)
        #expect(await handles.store.pins.isEmpty)
    }
}
