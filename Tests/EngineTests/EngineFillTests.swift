import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Quick access fills the field that has the cursor in the app the user works in.
@Suite struct EngineFillTests {
    @Test func ambiguousCodesRequireAnExplicitFieldChoice() {
        #expect(FillTarget(appName: "Synthetic form", isUnclassifiedCode: true).suggestedLoginField == nil)
        #expect(FillTarget(appName: "Synthetic form", isSecure: true, isUnclassifiedCode: true).suggestedLoginField == nil)
        #expect(FillTarget(appName: "Synthetic form").suggestedLoginField == .username)
        #expect(FillTarget(appName: "Synthetic form", isSecure: true).suggestedLoginField == .password)
    }

    @Test func aLockWhileTheAdapterWaitsPreventsCredentialDelivery() async throws {
        for isForm in [false, true] {
            let (engine, handles) = try await makeUnlockedEngine()
            await handles.activeField.setField(FillTarget(appName: "Synthetic form", takesLogin: isForm))
            let target = try #require(await engine.fillTarget())
            await handles.activeField.setBeforeWrite { await engine.lock() }
            if isForm {
                await #expect(throws: (any Error).self) { try await engine.fillLogin(of: "item-1", into: target) }
            } else {
                await #expect(throws: (any Error).self) { try await engine.fill(.password, of: "item-1", into: target) }
            }
            #expect(await handles.activeField.written.isEmpty)
            #expect(await handles.activeField.writtenLogins.isEmpty)
        }
    }

    @Test func aLoginIncludesTheCurrentCodeOnlyForAnIdentifiedCodeField() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        for acceptsCode in [false, true] {
            await handles.activeField.setField(FillTarget(appName: "Synthetic form", takesLogin: true,
                                                         takesVerificationCode: acceptsCode))
            let target = try #require(await engine.fillTarget())
            try await engine.fillLogin(of: "item-1", into: target)
            let expected = acceptsCode ? try await engine.verificationCode(for: "item-1").code : nil
            #expect(await handles.activeField.writtenLogins.last?.verificationCode == expected)
        }
        let target = try #require(await engine.fillTarget())
        try await engine.fillLogin(of: "item-2", into: target)
        #expect(await handles.activeField.writtenLogins.last?.verificationCode == nil)
        #expect(await handles.clipboard.text == nil)
        #expect(FillTarget(appName: "Synthetic form", isVerificationCode: true).suggestedLoginField == .verificationCode)
    }

    @Test func aFieldOfAnItemGoesIntoTheFieldThatHasTheCursor() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let target = try #require(await engine.fillTarget())
        #expect(target.appName == "Fake Editor")

        try await engine.fill(.password, of: "item-1", into: target)

        var written = await handles.activeField.written
        #expect(written.map(\.text) == ["fake-password-item-1"] && written.first?.target == target)
        // A fill is no copy: the clipboard stays as it was.
        #expect(await handles.clipboard.text == nil)

        // The verification code is the one of the moment of the fill.
        try await engine.fill(.verificationCode, of: "item-1", into: target)
        written = await handles.activeField.written
        let code = try await engine.verificationCode(for: "item-1").code
        #expect(written.count == 2 && written.last?.text == code)
        #expect(await engine.state.activity == nil)
    }

    @Test func nothingIsWrittenWhenTheCursorHasLeftTheField() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let target = try #require(await engine.fillTarget())

        // The cursor is in another field now.
        await handles.activeField.setField(FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor"))
        #expect(await engineError { try await engine.fill(.password, of: "item-1", into: target) } == .fill(.targetChanged))
        // No field at all.
        await handles.activeField.setField(nil)
        #expect(await engineError { try await engine.fill(.password, of: "item-1", into: target) } == .fill(.noField))
        #expect(await engine.fillTarget() == nil)
        // The app does not take the value: the engine does not try again.
        await handles.activeField.setField(target)
        await handles.activeField.refuseNextWrite()
        #expect(await engineError { try await engine.fill(.password, of: "item-1", into: target) } == .fill(.refused))
        #expect(await handles.activeField.written.isEmpty)
        // A field the item does not have, and an item that is not there.
        #expect(await engineError { try await engine.fill(.identityPhone, of: "item-4", into: target) } == .notFound)
        #expect(await engineError { try await engine.fill(.password, of: "missing", into: target) } != nil)
        #expect(await handles.activeField.written.isEmpty)
    }

    @Test func thereIsNothingToFillWithoutThePermissionOrWhileLocked() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let target = try #require(await engine.fillTarget())

        await handles.activeField.setPermitted(false)
        #expect(await !engine.isFillAllowed())
        #expect(await engine.fillTarget() == nil)
        #expect(await engineError { try await engine.fill(.password, of: "item-1", into: target) } == .fill(.notAllowed))
        // The system is asked only when a client says so.
        #expect(await handles.activeField.askedForPermission == 0)
        await engine.askForFillPermission()
        #expect(await handles.activeField.askedForPermission == 1)

        await handles.activeField.setPermitted(true)
        await engine.lock()
        #expect(await engine.fillTarget() == nil)
        #expect(await engineError { try await engine.fill(.password, of: "item-1", into: target) } != nil)
        #expect(await handles.activeField.written.isEmpty)
    }
}

/// A login form: which of its fields take the user name and the password, and the fill of both.
@Suite struct LoginFormTests {
    @Test func theUserNameIsTheOpenFieldBeforeThePassword() {
        // user name, password; the cursor in either.
        #expect(LoginFormFields.pair(isSecure: [false, true], cursor: 0).map { [$0.username, $0.password] } == [0, 1])
        #expect(LoginFormFields.pair(isSecure: [false, true], cursor: 1).map { [$0.username, $0.password] } == [0, 1])
        // A search field before the form, and a second password after it, are passed over.
        #expect(LoginFormFields.pair(isSecure: [false, false, true, true], cursor: 1).map { [$0.username, $0.password] } == [1, 2])
        #expect(LoginFormFields.pair(isSecure: [false, false, true, true], cursor: 2).map { [$0.username, $0.password] } == [1, 2])
        // The cursor in the second password takes the open field before it.
        #expect(LoginFormFields.pair(isSecure: [false, true, true], cursor: 2).map { [$0.username, $0.password] } == [0, 2])
    }

    @Test func aFormWithoutSuchAPairIsNoLoginForm() {
        // One field of a login in two steps, a password alone, a form of open fields, no field.
        #expect(LoginFormFields.pair(isSecure: [false], cursor: 0) == nil)
        #expect(LoginFormFields.pair(isSecure: [true], cursor: 0) == nil)
        #expect(LoginFormFields.pair(isSecure: [false, false], cursor: 0) == nil)
        // The password lies before the field with the cursor: no user name after a password.
        #expect(LoginFormFields.pair(isSecure: [true, false], cursor: 1) == nil)
        #expect(LoginFormFields.pair(isSecure: [], cursor: 0) == nil)
        #expect(LoginFormFields.pair(isSecure: [false, true], cursor: 5) == nil)
    }

    @Test func aLoginGoesIntoTheTwoFieldsOfAFormAndIntoNoOtherTarget() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let form = FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser", website: "https://item-2.example/login",
                              takesLogin: true)
        await handles.activeField.setField(form)
        let target = try #require(await engine.fillTarget())
        #expect(target.takesLogin)

        try await engine.fillLogin(of: "item-2", into: target)
        let written = await handles.activeField.writtenLogins
        #expect(written.count == 1)
        #expect(written.first?.username == "demo-shopper" && written.first?.password == "fake-password-item-2")
        #expect(written.first?.target == form)
        // Nothing went the way of one value.
        #expect(await handles.activeField.written.isEmpty)

        // A field of no login form takes no login, and neither does a form the cursor has left.
        let single = FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor")
        await handles.activeField.setField(single)
        await #expect(throws: EngineError.fill(.noField)) { try await engine.fillLogin(of: "item-2", into: single) }
        await handles.activeField.setField(FillTarget(appName: "Fake Browser", takesLogin: true))
        await #expect(throws: EngineError.fill(.targetChanged)) { try await engine.fillLogin(of: "item-2", into: form) }

        // An item that is no login with both values, and a locked vault.
        await handles.activeField.setField(form)
        await #expect(throws: EngineError.notFound) { try await engine.fillLogin(of: "item-3", into: form) }
        await engine.lock()
        await #expect(throws: (any Error).self) { try await engine.fillLogin(of: "item-2", into: form) }
        #expect(await handles.activeField.writtenLogins.count == 1)
    }

    @Test func thePageOfAFillBecomesAWebsiteOfTheLoginOnce() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let websites = { await engine.state.vault.items.first { $0.id == "item-2" }?.websites.map(\.address) }

        try await engine.addWebsite("https://shop.example.org/login", toLogin: "item-2")
        #expect(await websites() == ["https://item-2.example", "https://shop.example.org/login"])
        // The login is now one of that page, and kept what it had.
        #expect(await engine.state.vault.logins(ofPage: "https://shop.example.org/cart").map(\.id) == ["item-2"])
        #expect(try await engine.item(id: "item-2").value(of: .username) == "demo-shopper")

        // The same address again, and an empty one, change nothing.
        try await engine.addWebsite(" https://shop.example.org/login ", toLogin: "item-2")
        try await engine.addWebsite("  ", toLogin: "item-2")
        #expect(await websites()?.count == 2)

        // An item that is no login has no websites.
        await #expect(throws: EngineError.notFound) { try await engine.addWebsite("https://card.example", toLogin: "item-3") }
    }
}

/// A page or a window in which no field has the cursor.
@Suite struct LoginFormWithoutCursorTests {
    @Test func theFirstHiddenFieldWithAnOpenOneBeforeItIsTheForm() {
        #expect(LoginFormFields.first(isSecure: [false, true]).map { [$0.username, $0.password] } == [0, 1])
        // A search field of the page, then the form, then a second form further down.
        #expect(LoginFormFields.first(isSecure: [false, false, true, false, true]).map { [$0.username, $0.password] } == [1, 2])
        // A password with nothing before it is passed over; no pair, no form.
        #expect(LoginFormFields.first(isSecure: [true, false, true]).map { [$0.username, $0.password] } == [1, 2])
        #expect(LoginFormFields.first(isSecure: [true]) == nil)
        #expect(LoginFormFields.first(isSecure: [false, false]) == nil)
        #expect(LoginFormFields.first(isSecure: []) == nil)
    }

    @Test func aPageWithoutACursorTakesALoginAndNoSingleValue() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let page = FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser", website: "https://item-2.example/login",
                              takesLogin: true, takesValue: false)
        await handles.activeField.setField(page)
        let target = try #require(await engine.fillTarget())

        await #expect(throws: EngineError.fill(.noField)) { try await engine.fill(.password, of: "item-2", into: target) }
        #expect(await handles.activeField.written.isEmpty)
        try await engine.fillLogin(of: "item-2", into: target)
        #expect(await handles.activeField.writtenLogins.map(\.username) == ["demo-shopper"])
    }
}
