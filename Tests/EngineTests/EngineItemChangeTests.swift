import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Changes of an item that the server does itself: favourite, archive, trash, restore, delete.
@Suite struct EngineItemChangeTests {
    private func item(_ id: String, in engine: Engine) async -> VaultItemSummary? {
        await engine.state.vault.items.first { $0.id == id }
    }

    @Test func aFavouriteIsSetWithTheFolderTheItemIsIn() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        try await engine.change(.favorite(true), of: "item-2")

        #expect(await handles.server.writes == [.init(.placement(isFavorite: true, folderID: "folder-1"), itemID: "item-2")])
        #expect(await item("item-2", in: engine)?.isFavorite == true)
        #expect(await item("item-2", in: engine)?.folderID == "folder-1")
        #expect(await engine.state.activity == nil)
    }

    @Test func theTrashTakesAnItemGivesItBackAndRemovesItForEver() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        try await engine.change(.moveToTrash, of: "item-1")
        #expect(await item("item-1", in: engine)?.isInTrash == true)
        #expect(try await engine.item(id: "item-1").isInTrash)

        try await engine.change(.restore, of: "item-1")
        #expect(await item("item-1", in: engine)?.isInTrash == false)

        try await engine.change(.deletePermanently, of: "item-7")
        #expect(await item("item-7", in: engine) == nil)
        #expect(await engineError { _ = try await engine.item(id: "item-7") } == .notFound)
        #expect(await handles.server.writes.map(\.write) == [.moveToTrash, .restore, .deletePermanently])
        // The stored copy is the server's version after the last change.
        let stored = try #require(await handles.store.stored?.vaultPayload)
        #expect(try JSONDecoder().decode(VaultContents.self, from: stored).items.count == 6)
    }

    @Test func anArchivedItemLeavesTheListsAndComesBack() async throws {
        let (engine, _) = try await makeUnlockedEngine()

        try await engine.change(.archive, of: "item-3")
        var vault = await engine.state.vault
        #expect(vault.items(in: .archive).map(\.id) == ["item-3"])
        #expect(!vault.items(in: .allItems).map(\.id).contains("item-3"))
        #expect(try await engine.item(id: "item-3").isArchived)

        try await engine.change(.unarchive, of: "item-3")
        vault = await engine.state.vault
        #expect(vault.items(in: .archive).isEmpty)
        #expect(vault.items(in: .type(.card)).map(\.id) == ["item-3"])
    }

    @Test func aChangeThatDoesNotApplySendsNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        #expect(await engineError { try await engine.change(.restore, of: "item-1") } == .invalidState)
        #expect(await engineError { try await engine.change(.deletePermanently, of: "item-1") } == .invalidState)
        #expect(await engineError { try await engine.change(.moveToTrash, of: "item-7") } == .invalidState)
        #expect(await engineError { try await engine.change(.archive, of: "item-7") } == .invalidState)
        #expect(await engineError { try await engine.change(.favorite(true), of: "item-1") } == .invalidState)
        #expect(await engineError { try await engine.change(.moveToTrash, of: "missing") } == .notFound)
        #expect(await handles.server.writes.isEmpty)

        await engine.lock()
        #expect(await engineError { try await engine.change(.moveToTrash, of: "item-1") } == .invalidState)
        #expect(await handles.server.writes.isEmpty)
    }

    @Test func anItemThatCannotBeDecryptedIsListedAndCanOnlyBeDeleted() async throws {
        var account = FakeAccount.demo
        account.contents.items.append(VaultItemSummary(id: "item-damaged", type: .login, name: "", isUndecryptable: true))
        let (engine, handles) = await makeEngine(account: account)
        try await engine.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)

        // The list has it, so the user learns of it; nothing of it opens.
        #expect(await item("item-damaged", in: engine)?.isUndecryptable == true)
        #expect(await engineError { _ = try await engine.item(id: "item-damaged") } == .itemNotReadable)
        #expect(await engineError { _ = try await engine.draft(of: "item-damaged") } == .itemNotWritable)
        #expect(await engineError { try await engine.change(.favorite(true), of: "item-damaged") } == .invalidState)
        #expect(await engineError { try await engine.change(.archive, of: "item-damaged") } == .invalidState)
        #expect(await handles.server.writes.isEmpty)

        try await engine.change(.moveToTrash, of: "item-damaged")
        #expect(await engineError { try await engine.change(.restore, of: "item-damaged") } == .invalidState)
        try await engine.change(.deletePermanently, of: "item-damaged")
        #expect(await item("item-damaged", in: engine) == nil)
    }

    @Test func severalItemsChangeInOneRequest() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let ids = ["item-1", "item-3", "item-5"]

        try await engine.change(.moveToFolder("folder-1"), ofItems: ids)
        #expect(await engine.state.vault.items(in: .folder("folder-1")).map(\.id).sorted() == ["item-1", "item-2", "item-3", "item-5"])
        // The favourite mark of the demo mail login stays.
        #expect(await item("item-1", in: engine)?.isFavorite == true)

        try await engine.change(.archive, ofItems: ids)
        #expect(await engine.state.vault.items(in: .archive).count == 3)
        try await engine.change(.unarchive, ofItems: ids)
        try await engine.change(.moveToTrash, ofItems: ids)
        #expect(await engine.state.vault.items(in: .trash).count == 4)
        try await engine.change(.restore, ofItems: ids)
        try await engine.change(.moveToTrash, ofItems: ids)
        try await engine.change(.deletePermanently, ofItems: ids)
        #expect(await engine.state.vault.items.map(\.id).sorted() == ["item-2", "item-4", "item-6", "item-7"])

        let writes = await handles.server.bulkWrites
        #expect(writes.map(\.write) == [.moveToFolder("folder-1"), .archive, .unarchive, .moveToTrash, .restore, .moveToTrash,
                                        .deletePermanently])
        #expect(writes.allSatisfy { $0.itemIDs == Set(ids) })
        // One request each, and none for a single item.
        #expect(await handles.server.writes.isEmpty)
    }

    @Test func aChangeOfSeveralItemsThatDoesNotApplyToOneOfThemSendsNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        // The demo old login is in the trash already.
        #expect(await engineError { try await engine.change(.moveToTrash, ofItems: ["item-1", "item-7"]) } == .invalidState)
        #expect(await engineError { try await engine.change(.restore, ofItems: ["item-1", "item-7"]) } == .invalidState)
        #expect(await engineError { try await engine.change(.archive, ofItems: ["item-1", "missing"]) } == .notFound)
        #expect(await engineError { try await engine.change(.moveToFolder("missing"), ofItems: ["item-1"]) } == .notFound)
        #expect(await engineError { try await engine.change(.favorite(true), ofItems: ["item-2", "item-3"]) } == .invalidState)
        #expect(await engineError { try await engine.change(.moveToTrash, ofItems: []) } == .invalidState)
        #expect(await handles.server.bulkWrites.isEmpty)

        // One item moves to a folder with its favourite mark, and out of it again.
        try await engine.change(.moveToFolder("folder-1"), of: "item-1")
        #expect(await handles.server.writes == [.init(.placement(isFavorite: true, folderID: "folder-1"), itemID: "item-1")])
        try await engine.change(.moveToFolder(nil), of: "item-1")
        #expect(await item("item-1", in: engine)?.folderID == nil)
        #expect(await engineError { try await engine.change(.moveToFolder("missing"), of: "item-1") } == .notFound)
    }

    @Test func aChangeWaitsForTheSyncInProgress() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.holdNextSync()
        let sync = Task { try await engine.sync() }
        await handles.server.syncIsHeld()

        let change = Task { try await engine.change(.moveToTrash, of: "item-1") }
        for _ in 0..<50 { await Task.yield() }
        #expect(await handles.server.writes.isEmpty)

        await handles.server.releaseSync()
        try await sync.value
        try await change.value
        #expect(await handles.server.writes.map(\.write) == [.moveToTrash])
        #expect(await item("item-1", in: engine)?.isInTrash == true)
    }

    @Test func aRefusedAccessTokenIsRenewedAndTheChangeRepeated() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.expireAccessToken()

        try await engine.change(.moveToTrash, of: "item-1")

        #expect(await handles.server.refreshCount == 1)
        #expect(await handles.server.writes.map(\.write) == [.moveToTrash])
        #expect(await engine.state.session.isUnlocked)
    }

    @Test func theEndOfTheSessionDuringAChangeLogsTheAccountOut() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.endSession()

        #expect(await engineError { try await engine.change(.moveToTrash, of: "item-1") } == .sessionExpired)

        let state = await engine.state
        #expect(state.session == .loggedOut)
        #expect(state.notices == [.sessionExpired])
        #expect(await handles.server.writes.isEmpty)
    }

    @Test func aRefusedChangeShowsTheServersVersionOfTheVault() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        // Another device has removed the item meanwhile.
        var contents = FakeAccount.demo.contents
        contents.apply(.deletePermanently, to: "item-1")
        await handles.server.setContents(contents)

        let error = await engineError { try await engine.change(.moveToTrash, of: "item-1") }

        #expect(error == .server("HTTP 400: Cipher doesn't exist"))
        #expect(await item("item-1", in: engine) == nil)
        #expect(await engine.state.activity == nil)
    }

    @Test func aChangeIsDoneEvenWhenTheVaultCannotBeFetchedAfterIt() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.failNextSync(.serverUnreachable)

        try await engine.change(.moveToTrash, of: "item-1")

        // The list shows the change; the stored copy follows with the next sync.
        #expect(await item("item-1", in: engine)?.isInTrash == true)
        try await engine.sync()
        #expect(await item("item-1", in: engine)?.isInTrash == true)
    }

    @Test func aChangeThatFailsOnTheWayChangesNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.failNext(.serverUnreachable)

        #expect(await engineError { try await engine.change(.moveToTrash, of: "item-1") } == .serverUnreachable)

        #expect(await item("item-1", in: engine)?.isInTrash == false)
        #expect(await engine.state.activity == nil)
    }

    @Test func aLockDuringAChangeLeavesNothingBehind() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        // The change is on the server; the lock comes while the vault is fetched again.
        await handles.server.holdNextSync()
        let change = Task { await engineError { try await engine.change(.moveToTrash, of: "item-1") } }
        await handles.server.syncIsHeld()

        await engine.lock()
        await handles.server.releaseSync()

        #expect(await change.value == .cancelled)
        let state = await engine.state
        #expect(state.vault == .empty)
        #expect(state.activity == nil)
        #expect(!state.session.isUnlocked)
    }
}
