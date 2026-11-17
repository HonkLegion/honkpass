import CommonCrypto
import CryptoKit
import Engine
import EngineFakes
import EngineLive
import Foundation
import Testing
import VaultModel

/// The local Vaultwarden of support/vaultwarden. Start it with `make server`.
enum LocalServer {
    static let account: SeedAccount? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? SeedAccount.load(from: root.appending(path: "support/vaultwarden/test-account.json"))
    }()

    /// The account with two-step login by authenticator app and by email.
    static let twoStepAccount: SeedAccount? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? SeedAccount.load(from: root.appending(path: "support/vaultwarden/test-account-two-step.json"))
    }()

    /// The account with an organization, two collections and items in them.
    static let organizationAccount: SeedAccount? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? SeedAccount.load(from: root.appending(path: "support/vaultwarden/test-account-organization.json"))
    }()
    static let organizationSeeded = Task { try await DevelopmentSeed.runOrganization(organizationAccount!) }

    /// Seeds the server once for all tests of a run.
    static let seeded = Task { try await DevelopmentSeed.run(account!) }
    static let twoStepSeeded = Task { try await DevelopmentSeed.runTwoStep(twoStepAccount!) }

    static func isReachable() async -> Bool {
        guard let account else { return false }
        var request = URLRequest(url: account.server.appending(path: "alive"))
        request.timeoutInterval = 2
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// The engine on the real adapters: URLSession to Vaultwarden and the Bitwarden SDK.
/// Only the store and the system events are in-memory.
@Suite(.enabled("Needs the local Vaultwarden: make server") { await LocalServer.isReachable() }, .serialized)
struct LocalServerTests {
    let account = LocalServer.account!
    let clipboard = FakeClipboard()

    private func makeEngine() async -> (engine: Engine, store: InMemoryAccountStore) {
        let store = InMemoryAccountStore(deviceIdentifier: "7e570000-0000-4000-8000-000000000001")
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                               systemEvents: ManualSystemEvents(), clipboard: clipboard, leaks: FakePasswordLeaks()))
        await engine.start()
        return (engine, store)
    }

    private func logIn(_ engine: Engine) async throws {
        _ = try await LocalServer.seeded.value
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
    }

    @Test func theEngineLogsInSyncsAndDecryptsTheSeededVault() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)

        let state = await engine.state
        #expect(state.session.account?.email == account.email)
        #expect(state.session.isUnlocked)
        let vault = state.vault
        #expect(vault.items.map(\.name).sorted() == DevelopmentSeed.itemNames.sorted())
        #expect(Set(vault.items.map(\.type)) == Set(ItemType.allCases))
        #expect(vault.folders.map(\.name).sorted() == DevelopmentSeed.folderNames.sorted())
        #expect(vault.omittedItemCount == 0)
        #expect(vault.lastSync != nil)

        let mail = try #require(vault.items.first { $0.name == "Example Mail" })
        #expect(mail.type == .login)
        #expect(mail.subtitle == "test.user@example.com")
        #expect(mail.isFavorite)
        let shop = try #require(vault.items.first { $0.name == "Example Shop" })
        #expect(shop.folderID == vault.folders.first { $0.name == "Shopping" }?.id)
        #expect(vault.items.filter(\.isInTrash).map(\.name) == [DevelopmentSeed.trashedItemName])
        let card = try #require(vault.items.first { $0.type == .card })
        #expect(card.subtitle.contains("4242"))
        #expect(card.cardBrand == "Visa")
        #expect(card.fields == [.cardNumber, .cardSecurityCode])
        #expect(mail.fields == [.username, .password, .verificationCode, .website])
        // The websites of a login come with its row, and the logins of a page are found by them.
        #expect(mail.websites == [ItemDraft.Website(address: "https://mail.example.com")])
        #expect(shop.websites.map(\.address) == ["https://shop.example.com/login", "https://checkout.example.com"])
        #expect(vault.logins(ofPage: "https://shop.example.com/basket").map(\.name) == ["Example Mail", "Example Shop"])
        #expect(vault.logins(ofPage: "http://intranet.example.local/wiki").map(\.name) == ["Example Intranet"])
        // The deleted login of "old.example.com" has the same base domain; it is in the trash.
        #expect(vault.logins(ofPage: "https://example.org/").isEmpty)
        // The server sends the groups of domains that count as one.
        #expect(vault.equivalentDomains.contains { $0.contains("youtube.com") && $0.contains("google.com") })
        let noPassword = try #require(vault.items.first { $0.name == "Example Login Without Password" })
        #expect(noPassword.fields == [.username])
        #expect(mail.websiteHost == "mail.example.com")
        #expect(vault.items.filter(\.asksForMasterPassword).map(\.name) == ["Example Intranet"])

        // What the engine keeps for the next unlock is the encrypted answer of the server.
        let stored = try #require(await store.stored)
        let payload = String(decoding: try #require(stored.vaultPayload), as: UTF8.self)
        #expect(!payload.contains("Example Mail"))
        #expect(!payload.contains("synthetic"))
    }

    @Test func aLockedVaultOpensFromTheStoredCopyWithTheMasterPasswordOnly() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let itemCount = await engine.state.vault.items.count

        await engine.lock()
        #expect(await engine.state.vault == .empty)

        do {
            try await engine.unlock(masterPassword: account.masterPassword + "x")
            Issue.record("A wrong master password opened the vault.")
        } catch {
            #expect(error as? EngineError == .wrongMasterPassword)
        }
        #expect(await !engine.state.session.isUnlocked)

        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.vault.items.count == itemCount)
    }

    @Test func theServerRejectsAWrongMasterPassword() async throws {
        let (engine, store) = await makeEngine()
        _ = try await LocalServer.seeded.value
        do {
            try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword + "x")
            Issue.record("A wrong master password logged in.")
        } catch {
            #expect(error as? EngineError == .invalidCredentials)
        }
        #expect(await engine.state.session == .loggedOut)
        #expect(await store.stored == nil)
    }

    @Test func itemsOpenWithAllTheirFields() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let list = await engine.state.vault.items
        func item(_ name: String) async throws -> VaultItem {
            try await engine.item(id: try #require(list.first { $0.name == name }).id)
        }

        let mail = try await item("Example Mail")
        #expect(mail.content == .login(LoginContent(username: "test.user@example.com", password: "synthetic-mail-password",
                                                    hasVerificationCode: true, websites: ["https://mail.example.com"])))
        #expect(mail.isFavorite)
        #expect(!mail.asksForMasterPassword)

        let shop = try await item("Example Shop")
        #expect(shop.notes == "Synthetic note of the shop login.")
        #expect(shop.customFields == [
            CustomField(name: "Customer number", value: .text("C-000123")),
            CustomField(name: "Security answer", value: .hidden("synthetic answer")),
            CustomField(name: "Newsletter", value: .boolean(true)),
        ])
        #expect(try await item("Example Intranet").asksForMasterPassword)

        guard case .card(let card) = try await item("Example Card").content else {
            Issue.record("The card is not a card.")
            return
        }
        #expect(card.number == "4242424242424242")
        #expect(card.expirationYear == "2030")

        guard case .identity(let identity) = try await item("Example Identity").content else {
            Issue.record("The identity is not an identity.")
            return
        }
        #expect(identity.fullName == "Mr Test User")
        #expect(identity.fullAddress == "1 Example Street\nPrague, 110 00\nCZ")

        guard case .sshKey(let key) = try await item("Example SSH Key").content else {
            Issue.record("The SSH key is not an SSH key.")
            return
        }
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(try await item("Example Note").notes == "A synthetic secure note.\nIt has two lines.")
    }

    @Test func verificationCodesCopiesAndTheMasterPasswordCheckWork() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let list = await engine.state.vault.items
        let mail = try #require(list.first { $0.name == "Example Mail" })

        let code = try await engine.verificationCode(for: mail.id)
        #expect(code.period == 30)
        #expect(code.code.count == 6 && code.code.allSatisfy(\.isNumber))

        try await engine.copy(.password, of: mail.id)
        #expect(await clipboard.text == "synthetic-mail-password")
        #expect(await clipboard.wasSensitive)
        try await engine.copy(.verificationCode, of: mail.id)
        #expect(await clipboard.text?.count == 6)

        let noPassword = try #require(list.first { $0.name == "Example Login Without Password" })
        await #expect(throws: EngineError.notFound) { try await engine.copy(.password, of: noPassword.id) }
        await #expect(throws: EngineError.notFound) { _ = try await engine.verificationCode(for: noPassword.id) }

        #expect(await engine.isMasterPassword(account.masterPassword))
        #expect(await !engine.isMasterPassword(account.masterPassword + "x"))
    }

    @Test func aPinOpensTheVaultThroughTheSDK() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        try await engine.setPin("4812", asksForMasterPasswordAfterRestart: false)
        let record = try #require(await store.pins.values.first)
        // Neither stored value holds the PIN in the clear.
        #expect(record.envelope?.contains("4812") == false)
        #expect(!record.encryptedPin.contains("4812"))

        await engine.lock()
        let wrong = await { do { try await engine.unlock(pin: "0000"); return nil as EngineError? } catch { return error as? EngineError } }()
        #expect(wrong == .wrongPin)
        #expect(await !engine.state.session.isUnlocked)

        try await engine.unlock(pin: "4812")
        let state = await engine.state
        #expect(state.session.isUnlocked)
        #expect(state.vault.items.map(\.name).sorted() == DevelopmentSeed.itemNames.sorted())
        // The keys opened by the PIN decrypt items as the keys opened by the master password do.
        let mail = try #require(state.vault.items.first { $0.name == "Example Mail" })
        #expect(try await engine.item(id: mail.id).value(of: .password) == "synthetic-mail-password")
    }

    @Test func aPinThatAsksForTheMasterPasswordIsMadeAgainAfterIt() async throws {
        let (first, store) = await makeEngine()
        try await logIn(first)
        try await first.setPin("4812", asksForMasterPasswordAfterRestart: true)
        let record = try #require(await store.pins.values.first)
        #expect(record.envelope == nil)

        // A restart: a new engine on what the first one stored.
        let restarted = InMemoryAccountStore(stored: await store.stored, pins: await store.pins,
                                             deviceIdentifier: "7e570000-0000-4000-8000-000000000001")
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: restarted,
                                               systemEvents: ManualSystemEvents(), clipboard: clipboard, leaks: FakePasswordLeaks()))
        await engine.start()
        #expect(await engine.state.pin == PinState(isSet: true, asksForMasterPasswordAfterRestart: true, canUnlock: false))

        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.pin.canUnlock)
        await engine.lock()
        try await engine.unlock(pin: "4812")
        #expect(await engine.state.session.isUnlocked)
    }

    /// Every change of this step, on an item that the test adds and removes again.
    @Test func theServerMarksArchivesTrashesRestoresAndDeletesAnItem() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let before = try await engine.item(id: id)
        let folder = try #require(before.folderID)
        func summary() async -> VaultItemSummary? { await engine.state.vault.items.first { $0.id == id } }

        try await engine.change(.favorite(true), of: id)
        #expect(await summary()?.isFavorite == true)
        // The server sets the folder with the favourite mark; the item must stay where it was.
        #expect(await summary()?.folderID == folder)
        try await engine.change(.favorite(false), of: id)
        #expect(await summary()?.isFavorite == false)

        try await engine.change(.archive, of: id)
        #expect(await engine.state.vault.items(in: .archive).map(\.id) == [id])
        #expect(try await engine.item(id: id).isArchived)
        try await engine.change(.unarchive, of: id)
        #expect(await engine.state.vault.items(in: .archive).isEmpty)

        try await engine.change(.moveToTrash, of: id)
        #expect(await summary()?.isInTrash == true)
        try await engine.change(.restore, of: id)
        #expect(await summary()?.isInTrash == false)

        // No change has touched the content of the item.
        let after = try await engine.item(id: id)
        #expect(after.content == before.content)
        #expect(after.notes == before.notes)
        #expect(after.customFields == before.customFields)
        #expect(after.folderID == folder)

        // The stored copy opens with the same list after a lock.
        await engine.lock()
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await summary() != nil)

        // The change waits for the sync that follows the unlock.
        try await engine.change(.moveToTrash, of: id)
        try await engine.change(.deletePermanently, of: id)
        #expect(await summary() == nil)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
        #expect(await store.stored?.vaultPayload != nil)
    }

    /// The error a command throws, or nil when it succeeds.
    private func engineError(_ command: () async throws -> Void) async -> EngineError? {
        do {
            try await command()
            return nil
        } catch {
            return error as? EngineError ?? .unexpected("not an EngineError")
        }
    }

    /// Removes an item the test has added, whatever state it is in.
    private func remove(_ id: String, with engine: Engine) async {
        if await engine.state.vault.items.first(where: { $0.id == id })?.isInTrash == false {
            try? await engine.change(.moveToTrash, of: id)
        }
        try? await engine.change(.deletePermanently, of: id)
    }

    @Test func aFormChangesAnItemAndKeepsWhatItDoesNotHold() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let before = try await engine.item(id: id)

        // The form holds what the item has.
        let opened = try await engine.draft(of: id)
        guard case .login(var login) = opened.content else {
            Issue.record("The form of a login is not a login.")
            return
        }
        #expect(opened.name == DevelopmentSeed.temporaryItemName)
        #expect(opened.folderID == before.folderID && opened.folderID != nil)
        #expect(login.username == "temporary-user" && login.password == "synthetic-temporary-password")
        #expect(login.websites == [ItemDraft.Website(address: "https://temporary.example.com")])
        #expect(opened.notes == "A synthetic note that must survive every change.")
        #expect(opened.customFields == [
            CustomField(name: "Temporary field", value: .text("synthetic value")),
            CustomField(name: "Temporary secret", value: .hidden("synthetic secret")),
            CustomField(name: "Temporary link", value: .linked(100)),
        ])

        var draft = opened
        draft.name = DevelopmentSeed.temporaryItemName + ", edited"
        draft.isFavorite = true
        draft.asksForMasterPassword = true
        login.password = "synthetic-second-password"
        login.verificationKey = "JBSWY3DPEHPK3PXP"
        login.websites.append(ItemDraft.Website(address: "https://second.example.com", match: .host))
        draft.content = .login(login)
        draft.customFields[1].value = .hidden("synthetic second secret")
        #expect(try await engine.save(draft) == id)

        let after = try await engine.item(id: id)
        #expect(after.name == draft.name && after.isFavorite && after.asksForMasterPassword)
        #expect(after.value(of: .password) == "synthetic-second-password")
        #expect(after.notes == before.notes && after.folderID == before.folderID && after.created == before.created)
        guard case .login(let saved) = after.content else { return }
        #expect(saved.websites == ["https://temporary.example.com", "https://second.example.com"])
        #expect(saved.hasVerificationCode)
        #expect(try await engine.verificationCode(for: id).code.count == 6)
        #expect(after.customFields == draft.customFields)
        // The old password and the old value of the hidden field went to the history.
        #expect(before.passwordHistoryCount == 0 && after.passwordHistoryCount == 2)
        #expect(try await engine.passwordHistory(of: id).map(\.password)
            == ["Temporary secret: synthetic secret", "synthetic-temporary-password"])
        #expect(after.passwordRevised != nil)
        // The form keeps the way a website is matched.
        guard case .login(let reopened) = try await engine.draft(of: id).content else { return }
        #expect(reopened.websites.map(\.match) == [nil, .host])

        // The form of the older revision is refused: it would undo what it has not seen.
        var stale = opened
        stale.name = DevelopmentSeed.temporaryItemName + ", stale"
        #expect(await engineError { try await engine.save(stale) } == .itemChanged)
        #expect(try await engine.item(id: id).name == draft.name)

        // A save without a change adds nothing to the history.
        try await engine.save(try await engine.draft(of: id))
        let unchanged = try await engine.item(id: id)
        #expect(unchanged.passwordHistoryCount == 2)
        // The date of the password stays; the server and the SDK may write its last digit differently.
        let drift = abs((unchanged.passwordRevised ?? .distantPast).timeIntervalSince(after.passwordRevised ?? .distantFuture))
        #expect(drift < 0.001, "the password date moved by \(drift) seconds")
        #expect(unchanged.content == after.content && unchanged.customFields == after.customFields)

        await remove(id, with: engine)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func theOrderOfWebsitesAndCustomFieldsIsTheOneOfTheForm() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        var draft = try await engine.draft(of: id)
        guard case .login(var login) = draft.content else { return }
        login.websites.append(ItemDraft.Website(address: "https://second.example.com", match: .exact))
        // The new website first, and the custom fields the other way round.
        login.websites.swapAt(0, 1)
        draft.content = .login(login)
        draft.customFields.reverse()

        try await engine.save(draft)

        let saved = try await engine.draft(of: id)
        guard case .login(let reordered) = saved.content else { return }
        #expect(reordered.websites == [ItemDraft.Website(address: "https://second.example.com", match: .exact),
                                       ItemDraft.Website(address: "https://temporary.example.com")])
        #expect(saved.customFields.map(\.name) == ["Temporary link", "Temporary secret", "Temporary field"])
        // A new order of the same hidden field is no new value of it: nothing goes to the history.
        #expect(try await engine.item(id: id).passwordHistoryCount == 0)
        await remove(id, with: engine)
    }

    @Test func theUserKeyOfTheSDKOpensTheVaultAgainAndAChangedKeyDoesNot() async throws {
        // The real SDK, with a Keychain behind Touch ID that is none: a test asks for no finger.
        let store = InMemoryAccountStore(deviceIdentifier: "7e570000-0000-4000-8000-000000000001")
        let biometrics = FakeBiometricKeys(isSensorAvailable: true)
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                               systemEvents: ManualSystemEvents(), clipboard: clipboard, leaks: FakePasswordLeaks(),
                                               biometrics: biometrics))
        await engine.start()
        try await logIn(engine)
        let id = try #require(await engine.state.session.account?.id)

        try await engine.setBiometricUnlock(true)
        let key = try #require(await biometrics.kept[id])
        #expect(await engine.state.biometrics.canUnlock)

        // The key the SDK gave out opens the stored copy of the vault, with all its keys.
        await engine.lock()
        try await engine.unlockWithBiometrics(reason: "unlock your vault")
        #expect(await engine.state.session.isUnlocked)
        let mail = try #require(await engine.state.vault.items.first { $0.name == "Example Mail" })
        #expect(try await engine.item(id: mail.id).value(of: .username) == "test.user@example.com")

        // A key that is not the key of the account opens nothing, and the engine removes it:
        // whichever half of it is wrong, the one that encrypts or the one that signs.
        let whole = try #require(Data(base64Encoded: key))
        for place in [0, whole.count / 2] {
            await engine.lock()
            var bytes = whole
            bytes[place] ^= 0xFF
            await biometrics.setKept(bytes.base64EncodedString(), accountID: id)
            await engine.refreshBiometrics()
            #expect(await engineError { try await engine.unlockWithBiometrics(reason: "unlock your vault") }
                == .biometrics(.keyRejected), "byte \(place)")
            #expect(await !engine.state.session.isUnlocked)
            #expect(await biometrics.kept.isEmpty)
        }
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func theAddressOfAnAppIsKeptAmongTheWebsitesWithTheMatchNever() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let app = try #require(AppAddress("osxapp://com.example.Mail:ABCDE12345"))
        var draft = try await engine.draft(of: id)
        guard case .login(var login) = draft.content else { return }
        login.websites.append(ItemDraft.Website(app: app))
        draft.content = .login(login)

        try await engine.save(draft)
        // What the server keeps is read again, not what the engine has in its memory.
        try await engine.sync()

        let saved = try await engine.draft(of: id)
        guard case .login(let kept) = saved.content else { return }
        #expect(kept.websites == [ItemDraft.Website(address: "https://temporary.example.com"),
                                  ItemDraft.Website(address: "osxapp://com.example.Mail:ABCDE12345", match: .never)])
        let summary = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(summary.websites.compactMap(\.app) == [app])
        // The login belongs to the app, has the website it had, and is the login of no page for the address.
        #expect(await engine.state.vault.logins(ofApp: app).map(\.id) == [id])
        #expect(summary.fields.contains(.website) && summary.websiteHost == "temporary.example.com")
        guard case .login(let shown) = try await engine.item(id: id).content else { return }
        #expect(shown.pages == ["https://temporary.example.com"] && shown.apps == [app])
        #expect(await engine.state.vault.passwordIdentities.first { $0.itemID == id }?.website == "https://temporary.example.com")
        await remove(id, with: engine)
    }

    @Test func aFormAddsAnItemOfEachTypeAndACopy() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let prefix = DevelopmentSeed.temporaryItemPrefix
        var added: [String] = []

        var loginForm = ItemDraft(new: .login)
        loginForm.name = prefix + " New Login"
        loginForm.notes = "A synthetic note."
        loginForm.content = .login(ItemDraft.Login(username: "new-user", password: "synthetic-new-password",
                                                   websites: [ItemDraft.Website(address: "https://new.example.com")]))
        loginForm.customFields = [CustomField(name: "Checked", value: .boolean(true))]
        let loginID = try await engine.save(loginForm)
        added.append(loginID)
        let login = try await engine.item(id: loginID)
        #expect(login.name == loginForm.name && login.notes == "A synthetic note." && !login.isFavorite)
        #expect(login.value(of: .username) == "new-user" && login.value(of: .website) == "https://new.example.com")
        #expect(login.customFields == loginForm.customFields)
        #expect(login.passwordHistoryCount == 0)

        var cardForm = ItemDraft(new: .card)
        cardForm.name = prefix + " New Card"
        let card = CardContent(cardholderName: "Test User", brand: "Visa", number: "4242424242424242",
                               expirationMonth: "1", expirationYear: "2031", securityCode: "321")
        cardForm.content = .card(card)
        let cardID = try await engine.save(cardForm)
        added.append(cardID)
        #expect(try await engine.item(id: cardID).content == .card(card))

        var identity = IdentityContent()
        identity.firstName = "Test"
        identity.lastName = "User"
        identity.email = "test.user@example.com"
        var identityForm = ItemDraft(new: .identity)
        identityForm.name = prefix + " New Identity"
        identityForm.content = .identity(identity)
        let identityID = try await engine.save(identityForm)
        added.append(identityID)
        #expect(try await engine.item(id: identityID).content == .identity(identity))

        var noteForm = ItemDraft(new: .secureNote)
        noteForm.name = prefix + " New Note"
        noteForm.notes = "A synthetic secure note."
        let noteID = try await engine.save(noteForm)
        added.append(noteID)
        #expect(try await engine.item(id: noteID).notes == "A synthetic secure note.")

        // A copy is a new item with the same content.
        let copyID = try await engine.save(try await engine.draft(of: loginID).copy(named: prefix + " Copy"))
        added.append(copyID)
        let copy = try await engine.item(id: copyID)
        #expect(copyID != loginID && copy.content == login.content && copy.customFields == login.customFields)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count + 5)

        for id in added { await remove(id, with: engine) }
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func severalItemsAreMovedArchivedTrashedRestoredAndDeletedAtOnce() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let first = try await DevelopmentSeed.addTemporaryItem(account)
        let second = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let ids = [first, second]
        let before = try await engine.item(id: first)
        let work = try #require(await engine.state.vault.folders.first { $0.name == "Work" }?.id)
        func listed() async -> [VaultItemSummary] { await engine.state.vault.items.filter { ids.contains($0.id) } }

        try await engine.change(.moveToFolder(work), ofItems: ids)
        #expect(await listed().allSatisfy { $0.folderID == work })
        try await engine.change(.moveToFolder(nil), ofItems: ids)
        #expect(await listed().allSatisfy { $0.folderID == nil })

        try await engine.change(.archive, ofItems: ids)
        #expect(await engine.state.vault.items(in: .archive).map(\.id).sorted() == ids.sorted())
        try await engine.change(.unarchive, ofItems: ids)
        #expect(await engine.state.vault.items(in: .archive).isEmpty)

        try await engine.change(.moveToTrash, ofItems: ids)
        #expect(await listed().allSatisfy(\.isInTrash))
        try await engine.change(.restore, ofItems: ids)
        #expect(await listed().allSatisfy { !$0.isInTrash })
        // None of it has touched the content.
        let after = try await engine.item(id: first)
        #expect(after.content == before.content && after.notes == before.notes && after.customFields == before.customFields)

        try await engine.change(.moveToTrash, ofItems: ids)
        try await engine.change(.deletePermanently, ofItems: ids)
        #expect(await listed().isEmpty)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func aFolderIsAddedRenamedFilledAndDeleted() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let itemID = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let before = try await engine.item(id: itemID)
        let name = DevelopmentSeed.temporaryItemPrefix + " Folder"
        func folderNames() async -> [String] { await engine.state.vault.folders.map(\.name).sorted() }

        let folderID = try await engine.saveFolder(name: name)
        #expect(await folderNames() == [name] + DevelopmentSeed.folderNames)
        #expect(try await engine.saveFolder(id: folderID, name: name + ", renamed") == folderID)
        #expect(await folderNames() == [name + ", renamed"] + DevelopmentSeed.folderNames)

        // An item moves to the folder through its form.
        var draft = try await engine.draft(of: itemID)
        draft.folderID = folderID
        try await engine.save(draft)
        #expect(await engine.state.vault.items(in: .folder(folderID)).map(\.id) == [itemID])

        // The deleted folder leaves its item in the vault, whole and without a folder.
        try await engine.deleteFolder(id: folderID)
        #expect(await folderNames() == DevelopmentSeed.folderNames)
        let after = try await engine.item(id: itemID)
        #expect(after.folderID == nil && !after.isInTrash)
        #expect(after.content == before.content && after.notes == before.notes && after.customFields == before.customFields)

        await remove(itemID, with: engine)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func theNameOfTheAccountComesFromItsAccessToken() async throws {
        let (engine, _) = await makeEngine()
        #expect(await engine.state.accountName == nil)
        try await logIn(engine)
        // The name of support/vaultwarden/test-account.json.
        #expect(await engine.state.accountName == "Test User")
        await engine.lock()
        #expect(await engine.state.accountName == "Test User")
    }

    @Test func aFileIsAttachedListedFetchedAndRemoved() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await engine.sync()
        let before = try await engine.item(id: id)
        // Synthetic content: a line of text and four kilobytes of a pattern.
        let file = Data("A synthetic attachment.\n".utf8) + Data((0..<4_096).map { UInt8($0 % 251) })

        let states = await engine.states()
        try await engine.addAttachment(to: id, fileName: "synthetic-notes.txt", data: file)
        // The request said how much of it had gone: never less than before, all of it at the end.
        var percents: [Int] = []
        var wasSaving = false
        for await state in states {
            if let percent = state.upload?.percent, percents.last != percent { percents.append(percent) }
            wasSaving = wasSaving || state.activity == .saving
            if wasSaving, state.activity == nil, state.upload == nil { break }
        }
        #expect(percents.first == 0 && percents.last == 100 && percents == percents.sorted())
        var item = try await engine.item(id: id)
        #expect(item.attachments.map(\.fileName) == ["synthetic-notes.txt"])
        #expect(item.attachments.first?.sizeName.isEmpty == false)
        #expect(await engine.state.vault.items.first { $0.id == id }?.attachmentCount == 1)
        let attachmentID = try #require(item.attachments.first?.id)

        // The file comes back as it went, through the server and the SDK.
        #expect(try await engine.attachment(attachmentID, of: id) == AttachmentFile(fileName: "synthetic-notes.txt", data: file))
        #expect(item.content == before.content && item.notes == before.notes && item.customFields == before.customFields)

        // The form of the item keeps its file.
        var draft = try await engine.draft(of: id)
        draft.name = DevelopmentSeed.temporaryItemName + ", with a file"
        try await engine.save(draft)
        item = try await engine.item(id: id)
        #expect(item.name == draft.name && item.attachments.map(\.id) == [attachmentID])
        #expect(try await engine.attachment(attachmentID, of: id).data == file)

        try await engine.deleteAttachment(attachmentID, of: id)
        #expect(try await engine.item(id: id).attachments.isEmpty)
        #expect(await engine.state.vault.items.first { $0.id == id }?.attachmentCount == 0)
        #expect(await engineError { _ = try await engine.attachment(attachmentID, of: id) } == .notFound)

        await remove(id, with: engine)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func theServerRefusesAFormOfAnItemItHasANewerCopyOf() async throws {
        let (first, _) = await makeEngine()
        let (second, _) = await makeEngine()
        try await logIn(first)
        try await logIn(second)
        let id = try await DevelopmentSeed.addTemporaryItem(account)
        try await first.sync()
        try await second.sync()
        var mine = try await first.draft(of: id)
        var theirs = try await second.draft(of: id)
        // The server compares the revisions in whole seconds.
        try await Task.sleep(for: .milliseconds(2_200))

        theirs.name = DevelopmentSeed.temporaryItemName + ", theirs"
        try await second.save(theirs)
        mine.name = DevelopmentSeed.temporaryItemName + ", mine"
        let error = await engineError { try await first.save(mine) }

        #expect(error == .itemChanged)
        // The refused engine shows the newer item.
        #expect(await first.state.vault.items.first { $0.id == id }?.name == theirs.name)
        await remove(id, with: first)
    }

    @Test func anItemWithADamagedPartIsNeitherShownInPartNorWritten() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        let stored = try #require(await store.stored)
        let crypto = try await BitwardenCrypto().unlock(UnlockRequest(
            userID: stored.account.id, email: account.email, material: stored.crypto, masterPassword: account.masterPassword))
        var form = ItemDraft(new: .login)
        form.name = DevelopmentSeed.temporaryItemPrefix + " Damaged"
        form.notes = "A synthetic note."
        form.content = .login(ItemDraft.Login(username: "damaged-user"))
        var request = try #require(try JSONSerialization.jsonObject(with: try await crypto.encrypt(form)) as? [String: Any])
        // Another first character of the authentication code of the note.
        var notes = try #require(request["notes"] as? String)
        let position = notes.index(after: try #require(notes.lastIndex(of: "|")))
        notes.replaceSubrange(position...position, with: notes[position] == "A" ? "B" : "A")
        request["notes"] = notes
        let server = VaultwardenServer()
        let id = try await server.save(request: JSONSerialization.data(withJSONObject: request), itemID: nil,
                                       server: account.server, accessToken: stored.accessToken)

        let synced = await engineError { try await engine.sync() }
        let isListed = await engine.state.vault.items.contains { $0.id == id }
        let openError = await engineError { _ = try await engine.item(id: id) }
        let draftError = await engineError { _ = try await engine.draft(of: id) }
        // A form made by hand, as a client with a mistake could send it.
        form.id = id
        form.notes = ""
        let saveError = await engineError { try await engine.save(form) }
        try await server.write(.deletePermanently, itemID: id, server: account.server, accessToken: stored.accessToken)
        try await engine.sync()

        #expect(synced == nil)
        // The list needs the name only, so the item is in it.
        #expect(isListed)
        // Strict decryption: the item does not open with its note missing, it does not open at all.
        #expect(openError == .itemNotReadable)
        // And no form of it is given out or taken, so nothing can write it back without the note.
        #expect(draftError == .itemNotWritable)
        #expect(saveError == .itemNotWritable)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func anItemWhoseNameIsDamagedIsListedAsSuchAndCanBeDeleted() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        let stored = try #require(await store.stored)
        let crypto = try await BitwardenCrypto().unlock(UnlockRequest(
            userID: stored.account.id, email: account.email, material: stored.crypto, masterPassword: account.masterPassword))
        var form = ItemDraft(new: .card)
        form.name = DevelopmentSeed.temporaryItemPrefix + " Nameless"
        var request = try #require(try JSONSerialization.jsonObject(with: try await crypto.encrypt(form)) as? [String: Any])
        // Another first character of the authentication code of the name.
        var name = try #require(request["name"] as? String)
        let position = name.index(after: try #require(name.lastIndex(of: "|")))
        name.replaceSubrange(position...position, with: name[position] == "A" ? "B" : "A")
        request["name"] = name
        let server = VaultwardenServer()
        let id = try await server.save(request: JSONSerialization.data(withJSONObject: request), itemID: nil,
                                       server: account.server, accessToken: stored.accessToken)

        try await engine.sync()
        let listed = await engine.state.vault.items.first { $0.id == id }
        let openError = await engineError { _ = try await engine.item(id: id) }
        // The engine itself removes it: the server needs no decrypted part for that.
        let trashError = await engineError { try await engine.change(.moveToTrash, of: id) }
        let deleteError = await engineError { try await engine.change(.deletePermanently, of: id) }
        if trashError != nil || deleteError != nil {
            try? await server.write(.deletePermanently, itemID: id, server: account.server, accessToken: stored.accessToken)
            try? await engine.sync()
        }

        // The server keeps the type in clear, so the row is in the right lists.
        #expect(listed?.isUndecryptable == true && listed?.name == "" && listed?.type == .card)
        #expect(openError == .itemNotReadable)
        #expect(trashError == nil && deleteError == nil)
        let vault = await engine.state.vault
        #expect(!vault.items.contains { $0.id == id } && vault.omittedItemCount == 0)
        #expect(vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func theHistoryOfTheGeneratorIsStoredEncryptedAndReadAgainAfterALock() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        var options = PasswordOptions()
        options.length = 24

        let password = try await engine.generate(.password(options))
        let passphrase = try await engine.generate(.passphrase(PassphraseOptions()))
        #expect(try await engine.generatorHistory().map(\.value) == [passphrase, password])

        // What lies in the store is encrypted by the SDK: neither value can be read in it.
        let stored = await store.generatorHistory
        #expect(stored.count == 2)
        let text = stored.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!text.contains(password) && !text.contains(passphrase))

        await engine.lock()
        try await engine.unlock(masterPassword: account.masterPassword)
        let history = try await engine.generatorHistory()
        #expect(history.map(\.value) == [passphrase, password] && history.map(\.kind) == [.passphrase, .password])

        try await engine.clearGeneratorHistory()
        #expect(try await engine.generatorHistory().isEmpty)
    }

    @Test func theServerRenewsTheAccessTokenAndRefusesAnUnknownRefreshToken() async throws {
        let (engine, store) = await makeEngine()
        try await logIn(engine)
        let stored = try #require(await store.stored)
        let server = VaultwardenServer()

        let fresh = try await server.refresh(server: account.server, refreshToken: try #require(stored.refreshToken))
        #expect(fresh.expiresIn > 0)
        #expect(!fresh.accessToken.isEmpty)
        // The new token opens the vault.
        #expect(!(try await server.sync(server: account.server, accessToken: fresh.accessToken)).isEmpty)

        await #expect(throws: EngineError.sessionExpired) {
            _ = try await server.refresh(server: account.server, refreshToken: "not-a-refresh-token")
        }
        await #expect(throws: EngineError.sessionExpired) {
            _ = try await server.sync(server: account.server, accessToken: "not-an-access-token")
        }
    }

    @Test func aServerThatDoesNotAnswerIsReportedAsUnreachable() async throws {
        let (engine, _) = await makeEngine()
        do {
            try await engine.logIn(server: URL(string: "http://localhost:9")!, email: account.email, masterPassword: "x")
            Issue.record("A log-in without a server succeeded.")
        } catch {
            #expect(error as? EngineError == .serverUnreachable)
        }
    }

    // MARK: Passkeys

    /// The authenticator of the SDK, with the real server behind it: a passkey is made in a
    /// temporary login, the server keeps it, and what the SDK signs with it is a signature that
    /// a website would accept. The check of the signature is the test's own; the app has none.
    @Test func theAuthenticatorOfTheSDKMakesAPasskeyThatTheServerKeepsAndSignsWithIt() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        var draft = ItemDraft(new: .login)
        draft.name = "Example Temporary Passkey Login"
        draft.content = .login(ItemDraft.Login(username: "passkey-user", password: "synthetic-password",
                                               websites: [.init(address: "https://passkey.example.test/login")]))
        let id = try await engine.save(draft)
        do {
            try await usePasskey(of: id, with: engine)
        } catch {
            await remove(id, with: engine)
            throw error
        }
        await remove(id, with: engine)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    private func usePasskey(of id: String, with engine: Engine) async throws {
        let rpID = "passkey.example.test"
        let handle = Data("example-temporary-user".utf8)
        let hash = Data(SHA256.hash(data: Data("example client data".utf8)))

        // The login of the website is one the new passkey can go into.
        #expect(await engine.autoFill(.passkeyTargets(rpID: rpID, userHandle: handle))
            == .logins([AutoFillLogin(itemID: id, name: "Example Temporary Passkey Login", username: "passkey-user")]))
        let request = PasskeyRegistrationRequest(rpID: rpID, userName: "passkey-user", userHandle: handle, clientDataHash: hash,
                                                 algorithms: [-7], userVerification: .required, isUserVerified: true, itemID: id)
        guard case .passkeyRegistration(let registration) = await engine.autoFill(.registerPasskey(request)) else {
            Issue.record("the SDK made no passkey")
            return
        }
        #expect(!registration.credentialID.isEmpty)

        // The vault that came back from the server has the passkey, and the login kept the rest.
        let summary = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(summary.passkeys == [VaultPasskey(credentialID: registration.credentialID, rpID: rpID, userName: "passkey-user",
                                                  userHandle: handle)])
        let item = try await engine.item(id: id)
        #expect(item.value(of: .password) == "synthetic-password")
        guard case .login(let login) = item.content else {
            Issue.record("expected a login")
            return
        }
        #expect(login.passkeyCreated != nil)
        #expect(await engine.state.vault.passkeyIdentities == [
            AutoFillIdentity(kind: .passkey, itemID: id, website: rpID, username: "passkey-user",
                             credentialID: registration.credentialID, userHandle: handle),
        ])
        #expect(await engine.autoFill(.passkeys(rpID: rpID, allowedCredentialIDs: [])) == .passkeys([
            AutoFillPasskey(itemID: id, credentialID: registration.credentialID, name: "Example Temporary Passkey Login",
                            username: "passkey-user"),
        ]))

        // The signature. The data of the authenticator begin with the hash of the relying
        // party and say that the user was present (bit 0) and verified (bit 2).
        let question = PasskeyAssertionRequest(rpID: rpID, clientDataHash: hash, allowedCredentialIDs: [registration.credentialID],
                                               itemID: id, userVerification: .required, isUserVerified: true)
        guard case .passkeyAssertion(let assertion) = await engine.autoFill(.passkeyAssertion(question)) else {
            Issue.record("the SDK did not sign")
            return
        }
        #expect(assertion.credentialID == registration.credentialID && assertion.userHandle == handle)
        let data = assertion.authenticatorData
        let rpHash = Data(SHA256.hash(data: Data(rpID.utf8)))
        #expect(data.count >= 37 && data.prefix(32) == rpHash)
        if data.count >= 37 { #expect(data[data.startIndex + 32] & 0x05 == 0x05) }

        // The public key of the passkey is in what the website got at its making: after the
        // data of the authenticator, as the coordinates x (key -2) and y (key -3) of 32 bytes.
        let attestation = registration.attestationObject
        func coordinate(_ key: UInt8) -> Data? {
            guard let mark = attestation.firstRange(of: Data([key, 0x58, 0x20])), attestation.endIndex - mark.upperBound >= 32 else {
                return nil
            }
            return attestation[mark.upperBound..<mark.upperBound + 32]
        }
        guard attestation.firstRange(of: rpHash) != nil, let x = coordinate(0x21), let y = coordinate(0x22),
              let key = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: assertion.signature) else {
            Issue.record("the public key or the signature of the passkey is not readable")
            return
        }
        #expect(key.isValidSignature(signature, for: data + hash))

        // A user who was not verified gets nothing where the website asks for a verified one.
        var unverified = question
        unverified.isUserVerified = false
        #expect(await engine.autoFill(.passkeyAssertion(unverified)) == .failure(.userNotVerified))

        // The website excludes the passkey: no second one is made.
        var again = request
        again.itemID = nil
        again.excludedCredentialIDs = [registration.credentialID]
        #expect(await engine.autoFill(.registerPasskey(again)) == .failure(.passkeyExists))
        // A login that was made all the same must not stay in the account of the tests.
        for item in await engine.state.vault.items where item.name == rpID { await remove(item.id, with: engine) }

        // The form removes the passkey, and the login is saved without it.
        var form = try await engine.draft(of: id)
        guard case .login(var fields) = form.content else {
            Issue.record("expected the form of a login")
            return
        }
        #expect(fields.passkeyCreated != nil)
        fields.passkeyCreated = nil
        form.content = .login(fields)
        _ = try await engine.save(form)
        #expect(await engine.state.vault.items.first { $0.id == id }?.passkeys.isEmpty == true)
        #expect(try await engine.item(id: id).value(of: .password) == "synthetic-password")
    }

    // MARK: The account

    @Test func theSDKMakesTheFingerprintPhraseOfTheAccount() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let words = try await engine.fingerprintPhrase()
        // Five words of letters; the same again after a lock and an unlock.
        #expect(words.count == 5 && words.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) })
        await engine.lock()
        try await engine.unlock(masterPassword: account.masterPassword)
        #expect(try await engine.fingerprintPhrase() == words)
    }

    @Test func theServerKnowsTheDeviceOfALogInAndNoOther() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        try await engine.logOut()
        #expect(await engine.isKnownDevice(server: account.server, email: account.email))

        // An installation that never logged in, with the same address.
        let other = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(),
                                              store: InMemoryAccountStore(deviceIdentifier: UUID().uuidString.lowercased()),
                                              systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(), leaks: FakePasswordLeaks()))
        await other.start()
        #expect(await other.isKnownDevice(server: account.server, email: account.email) == false)
    }

    @Test func theServerTakesTheRequestForAHint() async throws {
        let (engine, _) = await makeEngine()
        // The development server has no mail: it refuses with its own words, and the refusal
        // comes through as what the server said. A server with mail answers without one.
        do {
            try await engine.requestPasswordHint(server: account.server, email: account.email)
        } catch EngineError.server(let message) {
            #expect(message.hasPrefix("HTTP 4"))
        }
    }

    // MARK: Export and import

    @Test func theSDKWritesTheExportsAndTheReaderReadsTheJsonBack() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let personal = await engine.state.vault.items.filter { !$0.isInTrash }

        let json = try await engine.exportVault(format: .json, masterPassword: account.masterPassword)
        let read = try VaultImportFormat.bitwardenJSON.read(json)
        #expect(Set(read.items.map(\.draft.name)) == Set(personal.map(\.name)))
        #expect(Set(read.folders.map(\.name)) == Set(await engine.state.vault.folders.map(\.name)))

        let csv = String(decoding: try await engine.exportVault(format: .csv, masterPassword: account.masterPassword), as: UTF8.self)
        #expect(csv.hasPrefix("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp"))
        // The CSV of Bitwarden holds logins and notes only.
        let fromCSV = try VaultImportFormat.bitwardenCSV.read(Data(csv.utf8))
        #expect(Set(fromCSV.items.map(\.draft.name)) == Set(personal.filter { $0.type == .login || $0.type == .secureNote }.map(\.name)))

        // The encrypted export says so, names no item, and the reader refuses it.
        let encrypted = try await engine.exportVault(format: .encryptedJson(password: "synthetic-file-password"),
                                                     masterPassword: account.masterPassword)
        let text = String(decoding: encrypted, as: UTF8.self)
        #expect(text.contains("\"encrypted\"") && text.contains("\"passwordProtected\"") && !personal.contains { text.contains($0.name) })
        #expect(throws: VaultImportError.encrypted) { try VaultImportFormat.bitwardenJSON.read(encrypted) }

        await #expect(throws: EngineError.wrongMasterPassword) { _ = try await engine.exportVault(format: .json, masterPassword: "wrong") }
    }

    /// What the web vault asks of the server when a link of a Send is opened: the status of the
    /// answer, the answer when it is a record, and the token the server gave for the Send.
    private func openSend(_ access: String, passwordHash: String? = nil) async throws
        -> (status: Int, record: [String: Any], token: String?) {
        // First a token for the Send, from the identity service; a Send with a password gives
        // it for the hash of the password only.
        var token = URLRequest(url: account.server.appending(path: "identity/connect/token"))
        token.httpMethod = "POST"
        token.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = [("grant_type", "send_access"), ("client_id", "send"), ("scope", "api.send.access"), ("send_id", access)]
        if let passwordHash { form.append(("password_hash_b64", passwordHash)) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        token.httpBody = Data(form.map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
            .joined(separator: "&").utf8)
        let (tokenData, tokenResponse) = try await URLSession.shared.data(for: token)
        guard let accessToken = ((try? JSONSerialization.jsonObject(with: tokenData)) as? [String: Any])?["access_token"] as? String else {
            return ((tokenResponse as? HTTPURLResponse)?.statusCode ?? 0, [:], nil)
        }
        var request = URLRequest(url: account.server.appending(path: "api/sends/access"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let record = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, record, accessToken)
    }

    /// The hash the web vault makes of the password of a Send with the key of its link:
    /// PBKDF2-SHA256, 100 000 rounds, as `SEND_KDF_ITERATIONS` of the reference.
    private func sendPasswordHash(_ password: String, linkKey: String) throws -> String {
        var text = linkKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        let salt = try #require(Data(base64Encoded: text))
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000, &derived, derived.count)
        }
        #expect(status == kCCSuccess)
        return Data(derived).base64EncodedString()
    }

    @Test func aTextSendIsMadeOpenedWithItsPasswordChangedAndDeleted() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        for old in await engine.state.vault.sends where old.name.hasPrefix("Example Temporary") { try await engine.deleteSend(id: old.id) }
        let day = Date().addingTimeInterval(7 * 86_400)

        let id = try await engine.saveSend(SendDraft(type: .text, name: "Example Temporary Send", notes: "a private note",
                                                    text: "synthetic shared text", hidesText: true, deletionDate: day,
                                                    maxAccessCount: 5, hidesEmail: true, newPassword: "synthetic-send-password"))
        let listed = try #require(await engine.state.vault.sends.first { $0.id == id })
        #expect(listed.name == "Example Temporary Send" && listed.type == .text && listed.hasPassword && !listed.isDisabled)
        #expect(listed.maxAccessCount == 5 && listed.accessCount == 0)
        #expect(abs(listed.deletionDate.timeIntervalSince(day)) < 1 && listed.expirationDate == listed.deletionDate)
        let send = try await engine.send(id: id)
        #expect(send.text == "synthetic shared text" && send.hidesText && send.notes == "a private note" && send.hidesEmail)

        // The link: the web vault of the server, the identifier the server gave, and a key of 16 bytes.
        let link = try await engine.sendLink(of: id)
        let prefix = account.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/#/send/"
        #expect(link.hasPrefix(prefix))
        let parts = link.dropFirst(prefix.count).split(separator: "/").map(String.init)
        #expect(parts.count == 2 && parts.last?.count == 22)
        let access = try #require(parts.first), linkKey = try #require(parts.last)

        // The server opens it for the password only, hashed with the key of the link as the web
        // vault does it. So the key of the link is the key the SDK made the Send with.
        #expect(try await openSend(access).token == nil)
        #expect(try await openSend(access, passwordHash: sendPasswordHash("another-password", linkKey: linkKey)).token == nil)
        let opened = try await openSend(access, passwordHash: sendPasswordHash("synthetic-send-password", linkKey: linkKey))
        #expect(opened.status == 200)
        // What the server gives out is encrypted, and it does not name the user, who asked for that.
        let text = String(describing: opened.record)
        #expect(!text.contains("synthetic shared text") && !text.contains("Example Temporary") && !text.contains(account.email))
        #expect(opened.record["creatorIdentifier"] is NSNull)
        try await engine.sync()
        #expect(await engine.state.vault.sends.first { $0.id == id }?.accessCount == 1)

        // A change keeps the password and the key; then the password is removed and the link opens without one.
        var draft = SendDraft(send)
        draft.name = "Example Temporary Send Renamed"
        draft.text = "another synthetic text"
        draft.hidesText = false
        draft.maxAccessCount = nil
        draft.notes = ""
        try await engine.saveSend(draft)
        let changed = try await engine.send(id: id)
        #expect(changed.summary.name == "Example Temporary Send Renamed" && changed.text == "another synthetic text")
        #expect(!changed.hidesText && changed.notes == nil && changed.summary.maxAccessCount == nil && changed.summary.hasPassword)
        #expect(try await engine.sendLink(of: id) == link)
        #expect(try await openSend(access).token == nil)
        try await engine.removeSendPassword(of: id)
        #expect(await engine.state.vault.sends.first { $0.id == id }?.hasPassword == false)
        #expect(try await openSend(access).status == 200)

        try await engine.deleteSend(id: id)
        #expect(await engine.state.vault.sends.contains { $0.id == id } == false)
        #expect(try await openSend(access).status == 404)
    }

    @Test func aFileSendBringsItsFileEncrypted() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        for old in await engine.state.vault.sends where old.name.hasPrefix("Example Temporary") { try await engine.deleteSend(id: old.id) }
        let contents = Data("synthetic file of a Send\n".utf8)

        let id = try await engine.saveSend(SendDraft(type: .file, name: "Example Temporary File Send",
                                                    file: .init(name: "example-temporary.txt", data: contents),
                                                    deletionDate: Date().addingTimeInterval(3_600)))
        let send = try await engine.send(id: id)
        #expect(send.summary.type == .file && send.fileName == "example-temporary.txt" && send.fileSizeName?.isEmpty == false)
        #expect(!send.summary.hasPassword)

        // The server gives the file out to the one with the link, as it was brought: encrypted.
        let access = try #require(send.linkPath?.split(separator: "/").first.map(String.init))
        let opened = try await openSend(access)
        #expect(opened.status == 200)
        // Without the wish to hide it, the one with the link learns whose Send it is.
        #expect(opened.record["creatorIdentifier"] as? String == account.email)
        let fileID = try #require((opened.record["file"] as? [String: Any])?["id"] as? String)
        var request = URLRequest(url: account.server.appending(path: "api/sends/access/file/\(fileID)"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + (try #require(opened.token)), forHTTPHeaderField: "Authorization")
        let (answer, _) = try await URLSession.shared.data(for: request)
        let address = try #require(((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["url"] as? String)
        let path = try #require(URLComponents(string: address))
        var local = try #require(URLComponents(url: account.server, resolvingAgainstBaseURL: false))
        local.percentEncodedPath = path.percentEncodedPath
        local.percentEncodedQuery = path.percentEncodedQuery
        let (stored, response) = try await URLSession.shared.data(from: try #require(local.url))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(stored.count > contents.count && stored.range(of: contents) == nil)

        // A change of the Send keeps its file.
        var draft = SendDraft(send)
        draft.name = "Example Temporary File Send Renamed"
        try await engine.saveSend(draft)
        let changed = try await engine.send(id: id)
        #expect(changed.summary.name == "Example Temporary File Send Renamed" && changed.fileName == "example-temporary.txt")

        try await engine.deleteSend(id: id)
        #expect(await engine.state.vault.sends.contains { $0.id == id } == false)
    }

    /// The whole way of the SSH agent: the engine, the key of the seeded vault from the SDK,
    /// the socket, and the tools of the system as its clients.
    @Test func theAgentSignsWithTheKeyOfTheVaultForTheToolsOfTheSystem() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/pv-ssh-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "agent.sock").path
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(),
                                               store: InMemoryAccountStore(deviceIdentifier: "7e570000-0000-4000-8000-000000000001"),
                                               systemEvents: ManualSystemEvents(), clipboard: clipboard, leaks: FakePasswordLeaks(),
                                               sshAgent: UnixSSHAgentSocket(path: path)))
        await engine.start()
        try await logIn(engine)
        func tool(_ name: String, _ arguments: [String], input: Data = Data()) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/" + name)
            process.arguments = arguments
            process.environment = ["SSH_AUTH_SOCK": path, "PATH": "/usr/bin:/bin", "HOME": "/var/empty"]
            let output = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        // Off until the user turns it on: no socket.
        #expect(!FileManager.default.fileExists(atPath: path))
        var settings = await engine.state.settings
        settings.sshAgent = SSHAgentSettings(isEnabled: true, prompt: .never)
        try await engine.setSettings(settings)
        let stored = try await engine.item(id: try #require(await engine.state.vault.items.first { $0.type == .sshKey }?.id))
        guard case .sshKey(let key) = stored.content else {
            Issue.record("The seeded vault has no SSH key.")
            return
        }
        var listed = (status: Int32(1), output: "")
        for _ in 0..<100 where listed.status != 0 {
            try await Task.sleep(for: .milliseconds(50))
            if FileManager.default.fileExists(atPath: path) { listed = try tool("ssh-add", ["-L"]) }
        }
        #expect(listed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == key.publicKey.split(separator: " ").prefix(2).joined(separator: " ") + " " + stored.name)

        // A signature as git asks for one, checked by the tool against the public key of the item.
        let publicKeyFile = folder.appending(path: "key.pub"), message = folder.appending(path: "message.txt")
        try Data((key.publicKey + "\n").utf8).write(to: publicKeyFile)
        try Data("synthetic message\n".utf8).write(to: message)
        let signed = try tool("ssh-keygen", ["-Y", "sign", "-n", "git", "-U", "-f", publicKeyFile.path, message.path])
        #expect(signed.status == 0, "\(signed.output)")
        let signers = folder.appending(path: "signers")
        try Data(("user@example.test " + key.publicKey + "\n").utf8).write(to: signers)
        let verify = ["-Y", "verify", "-n", "git", "-f", signers.path, "-I", "user@example.test", "-s", message.path + ".sig"]
        let verified = try tool("ssh-keygen", verify, input: Data("synthetic message\n".utf8))
        #expect(verified.status == 0, "\(verified.output)")
        // The signature holds for that message only.
        #expect(try tool("ssh-keygen", verify, input: Data("another message\n".utf8)).status != 0)

        // A locked vault still names its key, signs nothing while it stays locked, and a logout ends the agent.
        await engine.lock()
        #expect(try tool("ssh-add", ["-L"]).status == 0)
        try await engine.logOut()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func anImportReachesTheServerWithItsFolderAndItsItems() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let file = VaultImport(folders: [.init(name: "Example Temporary Imported Folder")], items: [
            .init(draft: ItemDraft(name: "Example Temporary Imported Login", isFavorite: true, notes: "imported",
                                   content: .login(.init(username: "imported-user", password: "synthetic-password",
                                                         verificationKey: "JBSWY3DPEHPK3PXP",
                                                         websites: [.init(address: "https://imported.example.test")])),
                                   customFields: [CustomField(name: "field", value: .hidden("value"))]),
                  folder: 0),
            .init(draft: ItemDraft(name: "Example Temporary Imported Note", notes: "a note", content: .secureNote)),
        ])
        try await engine.importVault(file)

        let vault = await engine.state.vault
        let folder = try #require(vault.folders.first { $0.name == "Example Temporary Imported Folder" })
        let login = try #require(vault.items.first { $0.name == "Example Temporary Imported Login" })
        let note = try #require(vault.items.first { $0.name == "Example Temporary Imported Note" })
        #expect(login.folderID == folder.id && login.isFavorite && note.folderID == nil)
        let item = try await engine.item(id: login.id)
        #expect(item.value(of: .password) == "synthetic-password" && item.value(of: .username) == "imported-user")
        #expect(item.customFields == [CustomField(name: "field", value: .hidden("value"))])
        #expect(try await engine.verificationCode(for: login.id).code.count == 6)

        // A second import into that folder: the server takes the folder it has and adds one under it.
        let second = VaultImport(folders: [.init(name: "Sub")], items: [
            .init(draft: ItemDraft(name: "Example Temporary Imported Second", content: .secureNote), folder: 0),
            .init(draft: ItemDraft(name: "Example Temporary Imported Third", content: .secureNote)),
        ]).placed(in: folder)
        try await engine.importVault(second)
        let later = await engine.state.vault
        #expect(later.folders.filter { $0.name == "Example Temporary Imported Folder" }.count == 1)
        let sub = try #require(later.folders.first { $0.name == "Example Temporary Imported Folder/Sub" })
        #expect(later.items.first { $0.name == "Example Temporary Imported Second" }?.folderID == sub.id)
        #expect(later.items.first { $0.name == "Example Temporary Imported Third" }?.folderID == folder.id)

        for item in later.items where item.name.hasPrefix("Example Temporary Imported") { await remove(item.id, with: engine) }
        try await engine.deleteFolder(id: sub.id)
        try await engine.deleteFolder(id: folder.id)
        #expect(await engine.state.vault.items.count == DevelopmentSeed.itemNames.count)
    }

    @Test func anImportedPasskeyStillSignsAndKeepsItsPasswordHistory() async throws {
        let (engine, _) = await makeEngine()
        try await logIn(engine)
        let sourceName = "Example Temporary Import Source", importedName = "Example Temporary Import Credential"
        var source = ItemDraft(name: sourceName, content: .login(.init(username: "import-user", password: "synthetic-before",
                                                                      websites: [.init(address: "https://import.example.test")])) )
        let sourceID = try await engine.save(source)
        var importedID: String?
        do {
            let hash = Data(SHA256.hash(data: Data("synthetic import assertion".utf8)))
            let request = PasskeyRegistrationRequest(rpID: "import.example.test", userName: "import-user",
                userHandle: Data("synthetic-import-user".utf8), clientDataHash: hash, algorithms: [-7],
                userVerification: .required, isUserVerified: true, itemID: sourceID)
            guard case .passkeyRegistration(let registration) = await engine.autoFill(.registerPasskey(request)) else {
                throw EngineError.unexpected("The synthetic passkey was not created.")
            }
            source = try await engine.draft(of: sourceID)
            guard case .login(var login) = source.content else { throw EngineError.invalidState }
            login.password = "synthetic-after"
            source.content = .login(login)
            _ = try await engine.save(source)
            let exported = try await engine.exportVault(format: .json, masterPassword: account.masterPassword)
            // Freeze only timestamps in this synthetic export. .125 is exactly representable
            // by Date and the SDK's nanosecond FFI; Date.now fractions can lose a millisecond
            // in the pinned SDK's Double conversion followed by its millisecond exporter.
            // All credential/key/history fields still undergo exact roundtrip equality.
            var json = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            var records = try #require(json["items"] as? [[String: Any]])
            let index = try #require(records.firstIndex { $0["name"] as? String == sourceName })
            var exportedLogin = try #require(records[index]["login"] as? [String: Any])
            var credentials = try #require(exportedLogin["fido2Credentials"] as? [[String: Any]])
            for index in credentials.indices { credentials[index]["creationDate"] = "2026-01-02T03:04:05.125Z" }
            exportedLogin["fido2Credentials"] = credentials
            records[index]["login"] = exportedLogin
            var history = try #require(records[index]["passwordHistory"] as? [[String: Any]])
            for index in history.indices { history[index]["lastUsedDate"] = "2026-01-02T03:04:05.125Z" }
            records[index]["passwordHistory"] = history
            json["items"] = records
            let all = try VaultImportFormat.bitwardenJSON.read(JSONSerialization.data(withJSONObject: json))
            var item = try #require(all.items.first { $0.draft.name == sourceName })
            #expect(item.passkeys?.count == 1 && item.passwordHistory?.first?.password == "synthetic-before")
            item.draft.name = importedName
            item.folder = nil
            try await engine.importVault(VaultImport(items: [item]))
            let restored = try #require(await engine.state.vault.items.first { $0.name == importedName })
            importedID = restored.id
            #expect(restored.passkeys.first?.credentialID == registration.credentialID)
            #expect(try await engine.passwordHistory(of: restored.id) == item.passwordHistory)
            let roundtrip = try VaultImportFormat.bitwardenJSON.read(await engine.exportVault(format: .json, masterPassword: account.masterPassword))
            let readBack = try #require(roundtrip.items.first { $0.draft.name == importedName })
            #expect(readBack.passkeys == item.passkeys && readBack.passwordHistory == item.passwordHistory)

            // Prove the imported private key can authenticate, not merely that metadata survived.
            let question = PasskeyAssertionRequest(rpID: "import.example.test", clientDataHash: hash,
                allowedCredentialIDs: [registration.credentialID], itemID: restored.id, userVerification: .required, isUserVerified: true)
            guard case .passkeyAssertion(let assertion) = await engine.autoFill(.passkeyAssertion(question)) else {
                throw EngineError.unexpected("The imported synthetic passkey did not sign.")
            }
            func coordinate(_ mark: UInt8) throws -> Data {
                let range = try #require(registration.attestationObject.firstRange(of: Data([mark, 0x58, 0x20])))
                return registration.attestationObject[range.upperBound..<range.upperBound + 32]
            }
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + coordinate(0x21) + coordinate(0x22))
            let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
            #expect(publicKey.isValidSignature(signature, for: assertion.authenticatorData + hash))
        } catch {
            if let importedID { await remove(importedID, with: engine) }
            await remove(sourceID, with: engine)
            throw error
        }
        if let importedID { await remove(importedID, with: engine) }
        await remove(sourceID, with: engine)
    }
}
