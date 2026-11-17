import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// The form of an item: the draft the engine gives out and the save that takes it back.
@Suite struct EngineItemSaveTests {
    private func listed(_ id: String, in engine: Engine) async -> VaultItemSummary? {
        await engine.state.vault.items.first { $0.id == id }
    }

    @Test func aChangedFormReplacesTheItem() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var draft = try await engine.draft(of: "item-2")
        #expect(draft.name == "Example Shop")
        #expect(draft.folderID == "folder-1")
        guard case .login(var login) = draft.content else {
            Issue.record("The draft of a login is not a login.")
            return
        }
        #expect(login.username == "demo-shopper")

        draft.name = "Example Shop, renamed"
        login.password = "a-new-fake-password"
        login.websites.append(ItemDraft.Website(address: "https://second.example", match: .host))
        draft.content = .login(login)
        let id = try await engine.save(draft)

        #expect(id == "item-2")
        #expect(await handles.server.savedDrafts == [draft])
        #expect(await listed("item-2", in: engine)?.name == "Example Shop, renamed")
        #expect(await listed("item-2", in: engine)?.folderID == "folder-1")
        let item = try await engine.item(id: "item-2")
        #expect(item.value(of: .password) == "a-new-fake-password")
        #expect(await engine.state.activity == nil)
    }

    @Test func aFormWithoutAnItemAddsOneAndACopyIsANewItemToo() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var draft = ItemDraft(new: .card, folderID: "folder-1")
        draft.name = "A new card"
        draft.content = .card(CardContent(brand: "Mastercard", number: "5555555555554444"))

        let id = try await engine.save(draft)

        #expect(await listed(id, in: engine)?.type == .card)
        #expect(await listed(id, in: engine)?.folderID == "folder-1")
        #expect(try await engine.item(id: id).value(of: .cardNumber) == "5555555555554444")

        let copy = try await engine.draft(of: "item-1").copy(named: "Example Mail, the copy")
        let copyID = try await engine.save(copy)
        #expect(copyID != "item-1" && copyID != id)
        #expect(await listed("item-1", in: engine)?.name == "Example Mail")
        #expect(await listed(copyID, in: engine)?.name == "Example Mail, the copy")
        #expect(await handles.server.savedDrafts.count == 2)
    }

    @Test func aFormThatCannotBeSavedSendsNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var nameless = try await engine.draft(of: "item-1")
        nameless.name = "   "
        #expect(await engineError { try await engine.save(nameless) } == .invalidState)
        // The reference has no form for an item in the trash.
        let trashed = try await engine.draft(of: "item-7")
        #expect(await engineError { try await engine.save(trashed) } == .invalidState)
        var unknown = try await engine.draft(of: "item-1")
        unknown.id = "missing"
        #expect(await engineError { try await engine.save(unknown) } == .notFound)
        #expect(await engineError { _ = try await engine.draft(of: "missing") } == .notFound)

        let draft = try await engine.draft(of: "item-1")
        await engine.lock()
        #expect(await engineError { try await engine.save(draft) } == .invalidState)
        #expect(await engineError { _ = try await engine.draft(of: "item-1") } == .invalidState)
        #expect(await handles.server.savedDrafts.isEmpty)
    }

    @Test func aNewerCopyOnTheServerRefusesTheFormAndShowsItself() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var draft = try await engine.draft(of: "item-1")
        draft.name = "My change"
        // Another device has renamed the item meanwhile.
        var contents = FakeAccount.demo.contents
        contents.items[0] = VaultItemSummary(id: "item-1", type: .login, name: "Their change")
        await handles.server.setContents(contents)
        await handles.server.failNext(.itemChanged)

        #expect(await engineError { try await engine.save(draft) } == .itemChanged)

        #expect(await listed("item-1", in: engine)?.name == "Their change")
        #expect(await handles.server.savedDrafts.isEmpty)
        #expect(await engine.state.activity == nil)
    }

    @Test func aSaveWaitsForTheSyncInProgress() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var draft = try await engine.draft(of: "item-1")
        draft.name = "Renamed"
        await handles.server.holdNextSync()
        let sync = Task { try await engine.sync() }
        await handles.server.syncIsHeld()

        let save = Task { try await engine.save(draft) }
        for _ in 0..<50 { await Task.yield() }
        #expect(await handles.server.savedDrafts.isEmpty)

        await handles.server.releaseSync()
        try await sync.value
        _ = try await save.value
        #expect(await listed("item-1", in: engine)?.name == "Renamed")
    }

    @Test func theEndOfTheSessionDuringASaveLogsTheAccountOut() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let draft = try await engine.draft(of: "item-1")
        await handles.server.endSession()

        #expect(await engineError { try await engine.save(draft) } == .sessionExpired)

        #expect(await engine.state.session == .loggedOut)
        #expect(await engine.state.notices == [.sessionExpired])
    }

    @Test func aLockDuringASaveLeavesNothingBehind() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        var draft = try await engine.draft(of: "item-1")
        draft.name = "Renamed"
        // The item is on the server; the lock comes while the vault is fetched again.
        await handles.server.holdNextSync()
        let save = Task { await engineError { try await engine.save(draft) } }
        await handles.server.syncIsHeld()

        await engine.lock()
        await handles.server.releaseSync()

        #expect(await save.value == .cancelled)
        let state = await engine.state
        #expect(state.vault == .empty)
        #expect(state.activity == nil)
    }
}
