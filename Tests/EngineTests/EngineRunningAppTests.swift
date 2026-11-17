import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineRunningAppTests {
    private let editor = FakeAppSignatures.editorAddress!

    @Test func aRunningSelectionIsRevalidatedAndRejectedAfterExitOrSignerChange() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let apps = try await engine.runningApps()
        #expect(apps.map(\.id) == [FakeAppSignatures.editorID])
        #expect(try await engine.appAddress(ofRunningApp: apps[0].id) == editor)
        await handles.appSignatures.setRunningApps([])
        #expect(await engineError { _ = try await engine.appAddress(ofRunningApp: apps[0].id) } == .appNotAccepted)
        await handles.appSignatures.setRunningApps(apps)
        let other = try #require(AppAddress(bundleID: editor.bundleID, developer: "OTHERTEAM9"))
        await handles.appSignatures.set(SignedApp(address: other), at: FakeAppSignatures.editor)
        #expect(await engineError { _ = try await engine.appAddress(ofRunningApp: apps[0].id) } == .appNotAccepted)
        #expect(await engineError { _ = try await engine.appAddress(ofRunningApp: UUID()) } == .appNotAccepted)
        await engine.lock()
        #expect(await engineError { _ = try await engine.runningApps() } == .invalidState)
    }

    @Test func aRunningBrowserOrUnsignedAppCannotBeAssigned() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let browser = RunningApp(id: UUID(), name: "Synthetic browser", location: FakeAppSignatures.browser,
                                 address: AppAddress(bundleID: "test.fake.browser", developer: "FAKETEAM01")!)
        let unsigned = RunningApp(id: UUID(), name: "Synthetic unsigned", location: FakeAppSignatures.unsigned, address: editor)
        await handles.appSignatures.setRunningApps([browser, unsigned])
        #expect(await engineError { _ = try await engine.appAddress(ofRunningApp: browser.id) } == .appNotAccepted)
        #expect(await engineError { _ = try await engine.appAddress(ofRunningApp: unsigned.id) } == .appNotAccepted)
    }

    @Test func successfulFillingCanRememberExactlyTheCapturedApplication() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        #expect(try await engine.fillAndSaveApp(nil, of: "item-2", into: target))
        let item = try #require(await engine.state.vault.items.first { $0.id == "item-2" })
        #expect(item.websites.contains { $0.app == editor && $0.match == .never })
        #expect(await handles.activeField.writtenLogins.count == 1)
        let again = try #require(await engine.fillTarget())
        #expect(try await engine.fillAndSaveApp(.username, of: "item-2", into: again))
        #expect(await engine.state.vault.items.first { $0.id == "item-2" }?.websites.filter { $0.app == editor }.count == 1)
    }

    @Test func fillingWithoutRememberingDoesNotChangeTheLogin() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        try await engine.fillLogin(of: "item-2", into: target)
        #expect(await engine.state.vault.logins(ofApp: editor).isEmpty)
    }

    @Test func refusedFillingDoesNotRememberTheApplication() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        await handles.activeField.refuseNextWrite()
        #expect(await engineError { _ = try await engine.fillAndSaveApp(nil, of: "item-2", into: target) } == .fill(.refused))
        #expect(await engine.state.vault.logins(ofApp: editor).isEmpty)
        #expect(await handles.activeField.writtenLogins.isEmpty)
    }

    @Test func forgedMetadataAndOldSessionCapturesCannotBeRemembered() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        let forged = FillTarget(id: target.id, appName: target.appName, bundleID: editor.bundleID,
                                app: AppAddress(bundleID: editor.bundleID, developer: "OTHERTEAM9"), takesLogin: true)
        #expect(await engineError { _ = try await engine.fillAndSaveApp(nil, of: "item-2", into: forged) } == .appNotAccepted)
        await engine.lock()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(await engineError { _ = try await engine.fillAndSaveApp(nil, of: "item-2", into: target) } == .appNotAccepted)
        #expect(await handles.activeField.writtenLogins.isEmpty)
        #expect(await engine.state.vault.logins(ofApp: editor).isEmpty)
    }

    @Test func persistenceFailureNeverRepeatsTheCredentialWrite() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        await handles.server.failNext(.server("Synthetic save failure"))
        #expect(try await engine.fillAndSaveApp(nil, of: "item-2", into: target) == false)
        #expect(await handles.activeField.writtenLogins.count == 1)
        #expect(await engine.state.vault.logins(ofApp: editor).isEmpty)
        #expect(await engineError { _ = try await engine.fillAndSaveApp(nil, of: "item-2", into: target) } == .appNotAccepted)
        #expect(await handles.activeField.writtenLogins.count == 1)
    }

    @Test func aReadOnlyLoginCannotBeRemembered() async throws {
        var account = FakeAccount.demo
        let index = try #require(account.contents.items.firstIndex { $0.id == "item-2" })
        account.contents.items[index].isReadOnly = true
        let (engine, handles) = await makeEngine(account: account)
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        #expect(await engineError { _ = try await engine.fillAndSaveApp(nil, of: "item-2", into: target) } == .appNotAccepted)
        #expect(await handles.activeField.writtenLogins.isEmpty)
    }

    @Test func aLateSignatureResultCannotCrossALockAndUnlock() async throws {
        var (ports, _) = EnginePorts.fake()
        let signatures = HeldAppSignatures()
        ports.appSignatures = signatures
        let engine = Engine(ports: ports)
        await engine.start()
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        let pending = Task { await engineError { _ = try await engine.appAddress(ofRunningApp: FakeAppSignatures.editorID) } }
        await signatures.waitUntilAsked()
        await engine.lock()
        try await engine.unlock(masterPassword: account.masterPassword)
        await signatures.release()
        #expect(await pending.value == .cancelled)
    }
}

private actor HeldAppSignatures: AppSignaturesPort {
    private var asked = false
    private var continuation: CheckedContinuation<SignedApp?, Never>?
    func app(at location: URL) async -> SignedApp? { nil }
    func app(runningID: UUID) async -> SignedApp? {
        asked = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilAsked() async { while !asked { await Task.yield() } }
    func release() {
        continuation?.resume(returning: FakeAppSignatures.editorAddress.map { SignedApp(address: $0) })
        continuation = nil
    }
}
