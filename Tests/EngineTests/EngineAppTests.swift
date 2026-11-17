import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// A login is tied to an app of macOS by the address of the app, which names who signed it.
@Suite struct EngineAppTests {
    @Test func anAppOfTheDiskGivesTheAddressOfItsSignature() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let editor = try #require(FakeAppSignatures.editorAddress)

        #expect(try await engine.appAddress(ofAppAt: FakeAppSignatures.editor) == editor)
        #expect(editor.address == "osxapp://test.fake.editor:FAKETEAM01")
        // An app that nobody signed could be any app, and what is no app has no signature.
        #expect(await engineError { _ = try await engine.appAddress(ofAppAt: FakeAppSignatures.unsigned) } == .appNotAccepted)
        #expect(await engineError { _ = try await engine.appAddress(ofAppAt: URL(fileURLWithPath: "/tmp/notes.txt")) } == .appNotAccepted)
        // A login belongs to the pages of a browser, never to the browser.
        #expect(await engineError { _ = try await engine.appAddress(ofAppAt: FakeAppSignatures.browser) } == .appNotAccepted)

        // An app that Apple signed itself.
        let ofApple = try #require(AppAddress(bundleID: "com.apple.TextEdit", developer: AppAddress.apple))
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        await handles.appSignatures.set(SignedApp(address: ofApple), at: textEdit)
        #expect(try await engine.appAddress(ofAppAt: textEdit).address == "osxapp://com.apple.TextEdit:apple")

        // Nothing is read for a locked vault.
        await engine.lock()
        #expect(await engineError { _ = try await engine.appAddress(ofAppAt: FakeAppSignatures.editor) } == .invalidState)
    }

    @Test func aLoginWithTheAddressOfAnAppBelongsToThatApp() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let editor = try #require(FakeAppSignatures.editorAddress)
        #expect(await engine.state.vault.logins(ofApp: editor).isEmpty)

        // The form of the login adds the app after its websites.
        var draft = try await engine.draft(of: "item-2")
        guard case .login(var login) = draft.content else {
            Issue.record("item-2 is a login")
            return
        }
        login.websites.append(ItemDraft.Website(app: try await engine.appAddress(ofAppAt: FakeAppSignatures.editor)))
        draft.content = .login(login)
        _ = try await engine.save(draft)

        let summary = try #require(await engine.state.vault.items.first { $0.id == "item-2" })
        #expect(summary.websites == [ItemDraft.Website(address: "https://item-2.example"),
                                     ItemDraft.Website(address: editor.address, match: .never)])
        let item = try await engine.item(id: "item-2")
        guard case .login(let saved) = item.content else {
            Issue.record("item-2 is a login")
            return
        }
        #expect(saved.pages == ["https://item-2.example"] && saved.apps == [editor])
        // "Copy website" still copies the website.
        #expect(item.value(of: .website) == "https://item-2.example")

        // The login is one of the app now, and of no page that looks like the address.
        #expect(await engine.state.vault.logins(ofApp: editor).map(\.id) == ["item-2"])
        #expect(await engine.state.vault.logins(ofPage: editor.address).isEmpty)
        #expect(await engine.state.vault.quickAccessSections(search: "", app: editor).first?.kind == .suggestions)

        // The field that is captured names the app as its running code is signed.
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor", app: editor, takesLogin: true))
        let target = try #require(await engine.fillTarget())
        #expect(target.app == editor)
        #expect(await engine.state.vault.logins(ofPage: target.website, app: target.app).map(\.id) == ["item-2"])
        try await engine.fillLogin(of: "item-2", into: target)
        #expect(await handles.activeField.writtenLogins.map(\.username) == ["demo-shopper"])

        // The same identifier under another developer is another app: the login is not its own.
        let impostor = try #require(AppAddress(bundleID: "test.fake.editor", developer: "OTHERTEAM9"))
        #expect(await engine.state.vault.logins(ofApp: impostor).isEmpty)
    }

    @Test func aLoginOfAnAppAloneHasNoWebsite() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let editor = try #require(FakeAppSignatures.editorAddress)
        var draft = ItemDraft(new: .login)
        draft.name = "Example Temporary App Login"
        draft.content = .login(ItemDraft.Login(username: "app-user", password: "fake-password",
                                               websites: [ItemDraft.Website(address: ""), ItemDraft.Website(app: editor)]))
        let id = try await engine.save(draft)

        let summary = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(summary.websites == [ItemDraft.Website(app: editor)])
        // The list offers no "copy website" for it, and the AutoFill of the system does not get it.
        #expect(!summary.fields.contains(.website))
        #expect(summary.websiteHost == nil)
        #expect(await !engine.state.vault.passwordIdentities.contains { $0.itemID == id })
        #expect(await engine.state.vault.logins(ofApp: editor).map(\.id) == [id])
    }
}
