import Engine
import EngineFakes
import EngineLive
import Foundation
import Testing
import VaultModel

/// Organizations and collections against the local Vaultwarden, with the account that has one
/// (support/vaultwarden/test-account-organization.json). The engine runs on the real adapters.
@Suite(.enabled("Needs the local Vaultwarden: make server") { await LocalServer.isReachable() }, .serialized)
struct OrganizationServerTests {
    let account = LocalServer.organizationAccount!

    private func makeEngine() async throws -> Engine {
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(),
                                               store: InMemoryAccountStore(deviceIdentifier: "7e570000-0000-4000-8000-000000000002"),
                                               systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(), leaks: FakePasswordLeaks()))
        await engine.start()
        _ = try await LocalServer.organizationSeeded.value
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        // What a run that broke off left behind.
        for item in await engine.state.vault.items where item.name.hasPrefix(DevelopmentSeed.temporaryItemPrefix) {
            if !item.isInTrash { try await engine.change(.moveToTrash, of: item.id) }
            try await engine.change(.deletePermanently, of: item.id)
        }
        return engine
    }

    @Test func theVaultShowsTheOrganizationItsCollectionsAndWhoseEachItemIs() async throws {
        let engine = try await makeEngine()
        let vault = await engine.state.vault
        #expect(vault.organizations.map(\.name) == [DevelopmentSeed.organizationName])
        #expect(vault.collections.map(\.name).sorted() == DevelopmentSeed.collectionNames.sorted())
        #expect(vault.omittedItemCount == 0 && !vault.items.contains(where: \.isUndecryptable))
        let organization = try #require(vault.organizations.first)
        #expect(vault.collections.allSatisfy { $0.organizationID == organization.id && !$0.isReadOnly })

        let own = try #require(vault.items.first { $0.name == DevelopmentSeed.personalItemOfOrganizationAccount })
        let login = try #require(vault.items.first { $0.name == "Example Shared Login" })
        let note = try #require(vault.items.first { $0.name == "Example Shared Note" })
        #expect(own.organizationID == nil && own.collectionIDs.isEmpty)
        #expect(login.organizationID == organization.id && note.organizationID == organization.id)
        #expect(vault.organizationName(of: login) == DevelopmentSeed.organizationName && vault.organizationName(of: own) == nil)
        func collection(_ name: String) throws -> String { try #require(vault.collections.first { $0.name == name }?.id) }
        let first = try collection(DevelopmentSeed.collectionNames[0]), second = try collection(DevelopmentSeed.collectionNames[1])
        #expect(login.collectionIDs == [first] && Set(note.collectionIDs) == [first, second])
        #expect(!login.isReadOnly && login.canDelete)

        // The lists: all vaults, mine, the organization's, and one collection.
        #expect(vault.items(in: .allItems).count == 3)
        #expect(vault.items(in: .allItems, owner: .user).map(\.name) == [own.name])
        #expect(vault.items(in: .allItems, owner: .organization(organization.id)).map(\.name) == [login.name, note.name])
        #expect(vault.items(in: .collection(second)).map(\.name) == [note.name])
        #expect(vault.items(in: .allItems, sort: VaultSort(column: .owner, isAscending: false)).last?.name == own.name)

        // An item of the organization opens with what it holds, decrypted with the key of the organization.
        let opened = try await engine.item(id: login.id)
        #expect(opened.value(of: .username) == "shared-user" && opened.value(of: .password) == "synthetic-shared-password")
    }

    @Test func anItemOfTheOrganizationIsChangedAndANewOneIsMadeInItsCollections() async throws {
        let engine = try await makeEngine()
        let vault = await engine.state.vault
        let organization = try #require(vault.organizations.first)
        let collections = vault.assignableCollections(of: organization.id)
        #expect(collections.count == 2)

        // A new item of the organization, in one collection.
        var draft = ItemDraft(new: .login)
        draft.name = "Example Temporary Shared"
        draft.content = .login(.init(username: "temporary-shared", password: "synthetic-password"))
        draft.organizationID = organization.id
        draft.collectionIDs = [collections[0].id]
        let id = try await engine.save(draft)
        let made = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(made.organizationID == organization.id && made.collectionIDs == [collections[0].id])
        #expect(try await engine.item(id: id).value(of: .password) == "synthetic-password")

        // Its form changes it; it stays with the organization and in its collection.
        var change = try await engine.draft(of: id)
        #expect(change.organizationID == organization.id && change.collectionIDs == [collections[0].id])
        change.name = "Example Temporary Shared Renamed"
        change.notes = "changed"
        change.organizationID = nil
        change.collectionIDs = []
        try await engine.save(change)
        let changed = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(changed.name == "Example Temporary Shared Renamed" && changed.organizationID == organization.id)
        #expect(changed.collectionIDs == [collections[0].id])
        #expect(try await engine.item(id: id).notes == "changed")

        // "Assign to collections" of an item of the organization sets its collections.
        try await engine.assign(itemID: id, toOrganization: organization.id, collectionIDs: collections.map(\.id))
        #expect(Set(await engine.state.vault.items.first { $0.id == id }?.collectionIDs ?? []) == Set(collections.map(\.id)))

        // Without a collection, or with one of nobody, nothing is sent.
        var nowhere = draft
        nowhere.collectionIDs = []
        await #expect(throws: EngineError.invalidState) { try await engine.save(nowhere) }
        nowhere.collectionIDs = ["00000000-0000-4000-8000-000000000000"]
        await #expect(throws: EngineError.invalidState) { try await engine.save(nowhere) }
        nowhere.organizationID = "00000000-0000-4000-8000-000000000000"
        await #expect(throws: EngineError.notFound) { try await engine.save(nowhere) }

        try await engine.change(.moveToTrash, of: id)
        try await engine.change(.deletePermanently, of: id)
        #expect(await engine.state.vault.items.count == 3)
    }

    /// Two accounts of the local server in one engine, on the store of the app in a folder of its own.
    @Test func twoAccountsOfTheServerWaitForEachOtherAndEachOpensItsOwnVault() async throws {
        let main = LocalServer.account!
        _ = try await LocalServer.seeded.value
        _ = try await LocalServer.organizationSeeded.value
        let folder = FileManager.default.temporaryDirectory.appending(path: "passvault-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileAccountStore(directory: folder, secrets: MemorySecretStore())
        let engine = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                               systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(), leaks: FakePasswordLeaks()))
        await engine.start()
        try await engine.logIn(server: main.server, email: main.email, masterPassword: main.masterPassword)
        let mainID = try #require(await engine.state.session.account?.id)
        let mainCount = await engine.state.vault.items.count

        try await engine.addAccount()
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        #expect(await engine.state.vault.organizations.count == 1)
        #expect(await engine.state.otherAccounts.map(\.email) == [main.email])

        // The first account: locked, opened from its stored copy, and in step with the server again.
        try await engine.switchAccount(to: mainID)
        #expect(await engine.state.vault == .empty)
        await #expect(throws: EngineError.wrongMasterPassword) { try await engine.unlock(masterPassword: account.masterPassword) }
        try await engine.unlock(masterPassword: main.masterPassword)
        try await engine.sync()
        let vault = await engine.state.vault
        #expect(vault.items.count == mainCount && vault.organizations.isEmpty)
        #expect(vault.items.contains { $0.name == "Example Mail" })

        // A restart finds both; the log-out of one leaves the other.
        let restarted = Engine(ports: EnginePorts(server: VaultwardenServer(), crypto: BitwardenCrypto(), store: store,
                                                  systemEvents: ManualSystemEvents(), clipboard: FakeClipboard(),
                                                  leaks: FakePasswordLeaks()))
        await restarted.start()
        #expect(await restarted.state.session.account?.email == main.email)
        #expect(await restarted.state.otherAccounts.map(\.email) == [account.email])
        try await restarted.logOut()
        #expect(await restarted.state.session.account?.email == account.email)
        try await restarted.unlock(masterPassword: account.masterPassword)
        #expect(await restarted.state.vault.items.contains { $0.name == "Example Shared Login" })
        try await restarted.logOut()
        #expect(await restarted.state.session == .loggedOut)
        #expect(try await store.parkedAccounts().isEmpty)
    }

    @Test func anItemOfTheUserMovesToTheOrganizationAndStillOpens() async throws {
        let engine = try await makeEngine()
        let vault = await engine.state.vault
        let organization = try #require(vault.organizations.first)
        let collections = vault.assignableCollections(of: organization.id)

        var draft = ItemDraft(new: .login)
        draft.name = "Example Temporary Moved"
        draft.notes = "a note that moves with it"
        draft.content = .login(.init(username: "temporary-moved", password: "synthetic-moved-password",
                                     verificationKey: "JBSWY3DPEHPK3PXP", websites: [.init(address: "https://moved.example.test")]))
        draft.customFields = [CustomField(name: "field", value: .hidden("value"))]
        let id = try await engine.save(draft)
        #expect(await engine.state.vault.items.first { $0.id == id }?.organizationID == nil)

        try await engine.assign(itemID: id, toOrganization: organization.id, collectionIDs: [collections[1].id])
        let moved = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(moved.organizationID == organization.id && moved.collectionIDs == [collections[1].id])
        // Everything of the item is there under the key of the organization.
        let opened = try await engine.item(id: id)
        #expect(opened.value(of: .password) == "synthetic-moved-password" && opened.notes == "a note that moves with it")
        #expect(opened.customFields == [CustomField(name: "field", value: .hidden("value"))])
        #expect(try await engine.verificationCode(for: id).code.count == 6)
        #expect(await engine.state.vault.logins(ofPage: "https://moved.example.test/").map(\.id) == [id])

        // It does not move on to another organization.
        await #expect(throws: EngineError.invalidState) {
            try await engine.assign(itemID: id, toOrganization: "00000000-0000-4000-8000-000000000000", collectionIDs: [collections[0].id])
        }

        try await engine.change(.moveToTrash, of: id)
        try await engine.change(.deletePermanently, of: id)
        #expect(await engine.state.vault.items.count == 3)
    }
}
