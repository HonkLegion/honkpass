import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineSettingsTests {
    let account = FakeAccount.demo
    let changed = EngineSettings(lockPolicy: LockPolicy(timeout: .afterInactivity(minutes: 15), action: .logOut),
                                 clipboardClearing: .after(seconds: 10), showsWebsiteIcons: false)

    @Test func theDefaultsAreTheOnesOfTheReference() async {
        let (engine, _) = await makeEngine()
        let settings = await engine.state.settings
        #expect(settings.lockPolicy == LockPolicy(timeout: .onRestart, action: .lock))
        #expect(settings.clipboardClearing == .after(seconds: 300))
        #expect(settings.showsWebsiteIcons)
    }

    @Test func settingsNeedAnAccount() async {
        let (engine, handles) = await makeEngine()
        #expect(await engineError { try await engine.setSettings(changed) } == .invalidState)
        #expect(await handles.store.settings.isEmpty)
    }

    @Test func changedSettingsAreSavedForTheAccountAndPublished() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setSettings(changed)
        #expect(await engine.state.settings == changed)
        #expect(await handles.store.settings == [account.userID: changed])
    }

    @Test func settingsThatCannotBeSavedChangeNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.store.failNextSettingsSave()
        #expect(await engineError { try await engine.setSettings(changed) } == .storage("The settings could not be saved."))
        #expect(await engine.state.settings == .default)
    }

    @Test func aRestartLoadsTheSettingsOfTheStoredAccount() async throws {
        let (first, handles) = try await makeUnlockedEngine()
        try await first.setSettings(changed)
        let stored = await handles.store.stored
        let saved = await handles.store.settings

        let (engine, _) = await makeEngine(stored: stored, settings: saved)
        #expect(await engine.state.session == .locked(try #require(stored).account))
        #expect(await engine.state.settings == changed)
    }

    @Test func aLogOutShowsTheDefaultsAndTheNextLogInTheSavedSettings() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        try await engine.setSettings(changed)

        try await engine.logOut()
        #expect(await engine.state.settings == .default)
        #expect(await handles.store.settings == [account.userID: changed])

        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await engine.state.settings == changed)
    }

    @Test func aCopiedValueLeavesTheClipboardAfterTheChosenTime() async throws {
        let clock = ManualClock()
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)
        var settings = await engine.state.settings
        settings.clipboardClearing = .after(seconds: 10)
        try await engine.setSettings(settings)

        try await engine.copy(.password, of: "item-1")
        await clock.waitForSleeper()
        clock.advance(by: .seconds(9))
        for _ in 0..<20 { await Task.yield() }
        #expect(await handles.clipboard.text == "fake-password-item-1")
        clock.advance(by: .seconds(1))
        for _ in 0..<200 where await handles.clipboard.text != nil { await Task.yield() }
        #expect(await handles.clipboard.text == nil)
    }

    @Test func withNeverTheClipboardKeepsACopiedValue() async throws {
        let clock = ManualClock()
        let (engine, handles) = try await makeUnlockedEngine(clock: clock)
        var settings = await engine.state.settings
        settings.clipboardClearing = .never
        try await engine.setSettings(settings)

        try await engine.copy(.password, of: "item-1")
        for _ in 0..<20 { await Task.yield() }
        clock.advance(by: .seconds(3600))
        for _ in 0..<20 { await Task.yield() }
        #expect(await handles.clipboard.text == "fake-password-item-1")
    }

    @Test func withoutWebsiteIconsTheServerIsNotAsked() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await engine.websiteIcon(host: "mail.example") != nil)
        var settings = await engine.state.settings
        settings.showsWebsiteIcons = false
        try await engine.setSettings(settings)

        #expect(await engine.websiteIcon(host: "mail.example") == nil)
        #expect(await engine.websiteIcon(host: "shop.example") == nil)
        #expect(await handles.server.iconRequests == ["mail.example"])
    }

    @Test func aNewInactivityTimeoutCountsFromTheChange() async throws {
        let clock = ManualClock()
        let (engine, _) = try await makeUnlockedEngine(clock: clock)
        try await engine.setLockPolicy(LockPolicy(timeout: .afterInactivity(minutes: 1), action: .lock))
        await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        _ = try await nextState(of: engine) { !$0.session.isUnlocked }
    }

    @Test func settingsOfAnOlderFileGetTheDefaultsForWhatIsMissing() throws {
        let old = Data(#"{"showsWebsiteIcons":false}"#.utf8)
        let settings = try JSONDecoder().decode(EngineSettings.self, from: old)
        #expect(settings == EngineSettings(lockPolicy: .default, clipboardClearing: .after(seconds: 300), showsWebsiteIcons: false))
    }
}
