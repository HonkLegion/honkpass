import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineFolderTests {
    @Test func aFolderIsAddedRenamedAndDeletedAndItsItemsStay() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        let id = try await engine.saveFolder(name: "Travel")
        #expect(await engine.state.vault.folders.map(\.name).sorted() == ["Shopping", "Travel"])
        // The server gets the name as the crypto port has encrypted it, never in clear.
        #expect(await handles.server.savedFolderNames == ["fake-encrypted-folder:Travel"])

        #expect(try await engine.saveFolder(id: id, name: "Journeys") == id)
        #expect(await engine.state.vault.folders.map(\.name).sorted() == ["Journeys", "Shopping"])

        // The demo shop login is in the folder "Shopping".
        try await engine.deleteFolder(id: "folder-1")
        let vault = await engine.state.vault
        #expect(vault.folders.map(\.name) == ["Journeys"])
        #expect(vault.items.first { $0.id == "item-2" }?.folderID == nil)
        #expect(vault.items.count == 7)
        #expect(await engine.state.activity == nil)
    }

    @Test func aFolderWriteThatDoesNotApplySendsNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        #expect(await engineError { try await engine.saveFolder(name: "  ") } == .invalidState)
        #expect(await engineError { try await engine.saveFolder(id: "missing", name: "Name") } == .notFound)
        #expect(await engineError { try await engine.deleteFolder(id: "missing") } == .notFound)
        await engine.lock()
        #expect(await engineError { try await engine.saveFolder(name: "Travel") } == .invalidState)
        #expect(await engineError { try await engine.deleteFolder(id: "folder-1") } == .invalidState)
        #expect(await handles.server.savedFolderNames.isEmpty)
    }

    @Test func aRefusedFolderWriteShowsTheServersVersionOfTheVault() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        // Another device has deleted the folder meanwhile.
        var contents = FakeAccount.demo.contents
        contents.folders = []
        await handles.server.setContents(contents)

        let error = await engineError { try await engine.saveFolder(id: "folder-1", name: "Renamed") }

        #expect(error == .server("HTTP 404: Invalid folder"))
        #expect(await engine.state.vault.folders.isEmpty)
        #expect(await engine.state.activity == nil)
    }

    @Test func aFolderIsAddedEvenWhenTheVaultCannotBeFetchedAfterIt() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.failNextSync(.serverUnreachable)

        let id = try await engine.saveFolder(name: "Travel")

        #expect(await engine.state.vault.folders.contains(VaultFolder(id: id, name: "Travel")))
    }
}
