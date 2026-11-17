import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Organizations and collections through the engine, on fakes.
@Suite struct EngineOrganizationTests {
    /// The demo account with an organization, an open and a read-only collection, and an item in the open one.
    private func makeOrganizationEngine() async throws -> (engine: Engine, handles: FakeHandles) {
        var account = FakeAccount.demo
        account.contents.organizations = [VaultOrganization(id: "org-1", name: "Example Organization")]
        account.contents.collections = [VaultCollection(id: "col-1", organizationID: "org-1", name: "Open"),
                                        VaultCollection(id: "col-2", organizationID: "org-1", name: "Closed", isReadOnly: true),
                                        VaultCollection(id: "col-3", organizationID: "org-1", name: "Second")]
        account.contents.items.append(VaultItemSummary(id: "shared-1", type: .login, name: "Example Shared", fields: [.username],
                                                       organizationID: "org-1", collectionIDs: ["col-1", "col-2"]))
        account.contents.items.append(VaultItemSummary(id: "shared-2", type: .login, name: "Example Read Only",
                                                       organizationID: "org-1", collectionIDs: ["col-2"], isReadOnly: true,
                                                       canDelete: false))
        let result = await makeEngine(account: account)
        try await result.engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
        return result
    }

    @Test func aNewItemGoesIntoCollectionsOfItsOrganization() async throws {
        let (engine, _) = try await makeOrganizationEngine()
        var draft = ItemDraft(new: .secureNote)
        draft.name = "New Shared"
        draft.organizationID = "org-1"
        // No collection, a collection twice, one the user cannot fill, one of nobody: nothing is sent.
        for collections in [[], ["col-1", "col-1"], ["col-2"], ["unknown"]] {
            draft.collectionIDs = collections
            await #expect(throws: EngineError.invalidState) { try await engine.save(draft) }
        }
        draft.collectionIDs = ["col-1", "col-3"]
        let id = try await engine.save(draft)
        let made = try #require(await engine.state.vault.items.first { $0.id == id })
        #expect(made.organizationID == "org-1" && made.collectionIDs == ["col-1", "col-3"])
        // An item of the user takes no collection with it.
        draft.organizationID = nil
        let own = try await engine.save(draft)
        #expect(await engine.state.vault.items.first { $0.id == own }?.collectionIDs == [])
    }

    @Test func anItemMovesToAnOrganizationAndItsCollectionsAreSet() async throws {
        let (engine, handles) = try await makeOrganizationEngine()
        try await engine.assign(itemID: "item-1", toOrganization: "org-1", collectionIDs: ["col-3"])
        #expect(await handles.server.shares == [FakeShare(itemID: "item-1", organizationID: "org-1", collectionIDs: ["col-3"])])
        let moved = try #require(await engine.state.vault.items.first { $0.id == "item-1" })
        #expect(moved.organizationID == "org-1" && moved.collectionIDs == ["col-3"])

        // The collections of an item of the organization: the one the user cannot change stays.
        try await engine.assign(itemID: "shared-1", toOrganization: "org-1", collectionIDs: ["col-3"])
        #expect(await handles.server.collectionChanges.last?.collectionIDs == ["col-3", "col-2"])
        #expect(await engine.state.vault.items.first { $0.id == "shared-1" }?.collectionIDs == ["col-3", "col-2"])

        // What does not move: an item the user may not change, one in the trash, one of another organization.
        await #expect(throws: EngineError.invalidState) {
            try await engine.assign(itemID: "shared-2", toOrganization: "org-1", collectionIDs: ["col-1"])
        }
        await #expect(throws: EngineError.invalidState) {
            try await engine.assign(itemID: "item-7", toOrganization: "org-1", collectionIDs: ["col-1"])
        }
        await #expect(throws: EngineError.notFound) {
            try await engine.assign(itemID: "item-2", toOrganization: "org-2", collectionIDs: ["col-1"])
        }
        await #expect(throws: EngineError.notFound) {
            try await engine.assign(itemID: "unknown", toOrganization: "org-1", collectionIDs: ["col-1"])
        }
    }

    @Test func theRightsOfAnOrganizationLimitWhatAnItemAllows() async throws {
        let (engine, _) = try await makeOrganizationEngine()
        let vault = await engine.state.vault
        let readOnly = try #require(vault.items.first { $0.id == "shared-2" })
        // The favourite mark, the folder and the archive are the user's own.
        #expect(readOnly.allows(.favorite(true)) && readOnly.allows(.moveToFolder("folder-1")) && readOnly.allows(.archive))
        #expect(!readOnly.allows(.moveToTrash))
        await #expect(throws: EngineError.invalidState) { try await engine.change(.moveToTrash, of: "shared-2") }
        var draft = ItemDraft(new: .login)
        draft.id = "shared-2"
        draft.name = "Renamed"
        await #expect(throws: EngineError.invalidState) { try await engine.save(draft) }

        // The lists by owner and by collection.
        #expect(vault.items(in: .allItems, owner: .organization("org-1")).map(\.name) == ["Example Read Only", "Example Shared"])
        #expect(vault.items(in: .allItems, owner: .user).count == 6)
        #expect(vault.items(in: .collection("col-1")).map(\.name) == ["Example Shared"])
        #expect(vault.assignableCollections(of: "org-1").map(\.name) == ["Open", "Second"])
    }
}
