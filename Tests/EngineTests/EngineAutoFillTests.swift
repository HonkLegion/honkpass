import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// The store of the system's AutoFill follows the vault.
@Suite struct EngineAutoFillTests {
    /// What the store holds once the engine has nothing more to write.
    private func stored(_ handles: FakeHandles, until condition: @Sendable ([AutoFillIdentity]) -> Bool) async -> [AutoFillIdentity] {
        for _ in 0..<200 {
            let identities = await handles.identities.identities
            if condition(identities) { return identities }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await handles.identities.identities
    }

    @Test func theLoginsOfTheUnlockedVaultAreTheEntriesOfTheStore() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        // A login with a user name, a password and a website, and a second entry for the one
        // that has an authenticator key; not the login in the trash, which has no website either.
        let first = await stored(handles) { $0.count == 3 }
        #expect(Set(first) == [
            AutoFillIdentity(itemID: "item-1", website: "https://item-1.example", username: "demo@passvault.test"),
            AutoFillIdentity(kind: .verificationCode, itemID: "item-1", website: "https://item-1.example", username: "demo@passvault.test"),
            AutoFillIdentity(itemID: "item-2", website: "https://item-2.example", username: "demo-shopper"),
        ])

        // The store follows a change of the vault.
        try await engine.change(.moveToTrash, of: "item-2")
        #expect(Set(await stored(handles) { $0.count == 2 }.map(\.itemID)) == ["item-1"])
        try await engine.change(.restore, of: "item-2")
        #expect(await stored(handles) { $0.count == 3 }.count == 3)

        var draft = ItemDraft(new: .login)
        draft.name = "New login"
        draft.content = .login(ItemDraft.Login(username: "new-user", password: "new-password",
                                               websites: [.init(address: "https://never.example", match: .never),
                                                          .init(address: "https://new.example/login")]))
        let id = try await engine.save(draft)
        // The website that is matched "never" is passed over.
        let third = await stored(handles) { $0.count == 4 }
        #expect(third.first { $0.itemID == id } == AutoFillIdentity(itemID: id, website: "https://new.example/login", username: "new-user"))
    }

    @Test func aLockKeepsTheEntriesAndALogoutRemovesThem() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        _ = await stored(handles) { $0.count == 3 }
        let writes = await handles.identities.writes

        await engine.lock()
        try? await Task.sleep(for: .milliseconds(50))
        // The system can still offer a login; taking it asks for the vault to be unlocked.
        #expect(await handles.identities.identities.count == 3)
        #expect(await handles.identities.writes == writes)

        try await engine.logOut()
        #expect(await stored(handles) { $0.isEmpty }.isEmpty)
    }

    @Test func nothingIsStoredWhileAutoFillIsTurnedOffInTheSystem() async throws {
        let (engine, handles) = await makeEngine()
        await handles.identities.setOn(false)
        let account = FakeAccount.demo
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        try await engine.change(.favorite(true), of: "item-2")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await handles.identities.identities.isEmpty)
        #expect(await handles.identities.writes == 0)
    }

    @Test func theExtensionGetsTheLoginsOfAWebsiteAndOnePasswordAtATime() async throws {
        let (engine, _) = try await makeUnlockedEngine()

        #expect(await engine.autoFill(.status) == .status(AutoFillStatus(vault: .unlocked, account: "demo@passvault.test")))
        // The system names a website as a domain or as a URL.
        let mail = AutoFillLogin(itemID: "item-1", name: "Example Mail", username: "demo@passvault.test")
        #expect(await engine.autoFill(.logins(services: ["https://item-1.example/login"])) == .logins([mail]))
        #expect(await engine.autoFill(.logins(services: ["item-1.example"])) == .logins([mail]))
        #expect(await engine.autoFill(.logins(services: ["unknown.example"])) == .logins([]))
        // Two websites: the logins of both, each once.
        guard case .logins(let both) = await engine.autoFill(.logins(services: ["item-1.example", "item-2.example", "item-1.example"])) else {
            Issue.record("expected logins")
            return
        }
        #expect(both.map(\.itemID) == ["item-1", "item-2"])
        // No website: every login that can be filled, without the one in the trash.
        guard case .logins(let all) = await engine.autoFill(.logins(services: [])) else {
            Issue.record("expected logins")
            return
        }
        #expect(all.map(\.itemID).sorted() == ["item-1", "item-2"])

        #expect(await engine.autoFill(.password(itemID: "item-1"))
            == .password(AutoFillPassword(username: "demo@passvault.test", password: "fake-password-item-1")))
        // Not a login, in the trash, or not there.
        #expect(await engine.autoFill(.password(itemID: "item-3")) == .failure(.notFound))
        #expect(await engine.autoFill(.password(itemID: "item-7")) == .failure(.notFound))
        #expect(await engine.autoFill(.password(itemID: "missing")) == .failure(.notFound))
        // The password is in no text that a log could take.
        #expect("\(AutoFillPassword(username: "u", password: "secret"))" == "AutoFillPassword")
        #expect(String(reflecting: AutoFillPassword(username: "u", password: "secret")) == "AutoFillPassword")
    }

    @Test func aLockedVaultTellsTheExtensionNothingAndOpensByItsPin() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        await engine.lock()

        #expect(await engine.autoFill(.status)
            == .status(AutoFillStatus(vault: .locked, canUnlockWithPin: true, account: "demo@passvault.test")))
        #expect(await engine.autoFill(.logins(services: ["item-1.example"])) == .failure(.locked))
        #expect(await engine.autoFill(.password(itemID: "item-1")) == .failure(.locked))
        #expect(await engine.autoFill(.unlock(pin: "0000")) == .failure(.wrongPin))
        #expect(await !engine.state.session.isUnlocked)

        #expect(await engine.autoFill(.unlock(pin: "4812")) == .status(AutoFillStatus(vault: .unlocked, account: "demo@passvault.test")))
        guard case .password = await engine.autoFill(.password(itemID: "item-1")) else {
            Issue.record("expected a password after the unlock")
            return
        }

        // Logged out there is no vault and no PIN.
        try await engine.logOut()
        #expect(await engine.autoFill(.status) == .status(AutoFillStatus(vault: .loggedOut)))
        #expect(await engine.autoFill(.logins(services: [])) == .failure(.loggedOut))
        #expect(await engine.autoFill(.unlock(pin: "4812")) == .failure(.pinUnavailable))
    }

    @Test func aLoginThatAsksForTheMasterPasswordKeepsItsPassword() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        var draft = try await engine.draft(of: "item-2")
        draft.asksForMasterPassword = true
        _ = try await engine.save(draft)

        guard case .logins(let logins) = await engine.autoFill(.logins(services: ["item-2.example"])) else {
            Issue.record("expected logins")
            return
        }
        // It is listed, marked, so that the extension can say where it is filled from.
        #expect(logins.map(\.itemID) == ["item-2"] && logins.first?.asksForMasterPassword == true)
        #expect(await engine.autoFill(.password(itemID: "item-2")) == .failure(.masterPasswordRequired))
    }

    @Test func onlyALoginThatCanBeFilledIsAnEntry() {
        let site = [ItemDraft.Website(address: "https://example.com")]
        let contents = VaultContents(items: [
            VaultItemSummary(id: "ok", type: .login, name: "Ok", subtitle: "user", fields: [.username, .password, .website], websites: site),
            VaultItemSummary(id: "no-password", type: .login, name: "A", subtitle: "user", fields: [.username, .website], websites: site),
            VaultItemSummary(id: "no-user", type: .login, name: "B", fields: [.password, .website], websites: site),
            VaultItemSummary(id: "no-site", type: .login, name: "C", subtitle: "user", fields: [.username, .password]),
            VaultItemSummary(id: "never", type: .login, name: "D", subtitle: "user", fields: [.username, .password, .website],
                             websites: [.init(address: "https://example.com", match: .never)]),
            VaultItemSummary(id: "trash", type: .login, name: "E", subtitle: "user", isInTrash: true,
                             fields: [.username, .password, .website], websites: site),
            VaultItemSummary(id: "archive", type: .login, name: "F", subtitle: "user", isArchived: true,
                             fields: [.username, .password, .website], websites: site),
            VaultItemSummary(id: "card", type: .card, name: "G", subtitle: "Visa", fields: [.cardNumber]),
        ], folders: [])
        #expect(contents.passwordIdentities == [AutoFillIdentity(itemID: "ok", website: "https://example.com", username: "user")])
    }

    @Test func aLoginWithAnAuthenticatorKeyIsAnEntryForItsCode() {
        let site = [ItemDraft.Website(address: "https://example.com")]
        let contents = VaultContents(items: [
            VaultItemSummary(id: "code", type: .login, name: "Code", subtitle: "user", fields: [.username, .verificationCode, .website],
                             websites: site),
            // Without a user name the system shows the name of the item beside the code.
            VaultItemSummary(id: "no-user", type: .login, name: "Named", fields: [.verificationCode, .website], websites: site),
            VaultItemSummary(id: "no-key", type: .login, name: "A", subtitle: "user", fields: [.username, .password, .website], websites: site),
            VaultItemSummary(id: "no-site", type: .login, name: "B", subtitle: "user", fields: [.username, .verificationCode]),
            VaultItemSummary(id: "trash", type: .login, name: "C", subtitle: "user", isInTrash: true,
                             fields: [.verificationCode, .website], websites: site),
        ], folders: [])
        #expect(contents.verificationCodeIdentities == [
            AutoFillIdentity(kind: .verificationCode, itemID: "code", website: "https://example.com", username: "user"),
            AutoFillIdentity(kind: .verificationCode, itemID: "no-user", website: "https://example.com", username: "Named"),
        ])
        #expect(contents.autoFillIdentities.count == 3)
    }

    @Test func theExtensionGetsTheVerificationCodeOfALoginThatHasAnAuthenticatorKey() async throws {
        let (engine, _) = try await makeUnlockedEngine()

        #expect(await engine.autoFill(.verificationCode(itemID: "item-1")) == .verificationCode("123456"))
        // A login without a key, and an item that is no login.
        #expect(await engine.autoFill(.verificationCode(itemID: "item-2")) == .failure(.notFound))
        #expect(await engine.autoFill(.verificationCode(itemID: "item-3")) == .failure(.notFound))

        await engine.lock()
        #expect(await engine.autoFill(.verificationCode(itemID: "item-1")) == .failure(.locked))
    }
}
