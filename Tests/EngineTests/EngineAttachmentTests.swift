import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineAttachmentTests {
    private let file = Data("A fake attachment.".utf8)

    @Test func anUploadSaysHowMuchOfTheFileHasGone() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let states = await engine.states()
        try await engine.addAttachment(to: "item-1", fileName: "notes.txt", data: file)

        // Each change once: none, the start, the two halves of the fake server, none after the
        // vault was fetched again. All of it was said before the command returned.
        var seen: [AttachmentUpload?] = []
        var wasSaving = false
        for await state in states {
            if seen.isEmpty || seen.last! != state.upload { seen.append(state.upload) }
            wasSaving = wasSaving || state.activity == .saving
            if wasSaving, state.activity == nil, state.upload == nil { break }
        }
        #expect(seen == [nil, AttachmentUpload(itemID: "item-1", percent: 0), AttachmentUpload(itemID: "item-1", percent: 50),
                         AttachmentUpload(itemID: "item-1", percent: 100), nil])

        // An upload the server refuses ends as well.
        await handles.server.failNext(.server("HTTP 500"))
        #expect(await engineError { try await engine.addAttachment(to: "item-1", fileName: "notes.txt", data: file) } != nil)
        #expect(await engine.state.upload == nil)
    }

    @Test func aFileIsAddedListedFetchedAndDeleted() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        try await engine.addAttachment(to: "item-1", fileName: "notes.txt", data: file)

        // The server gets the name and the content as the crypto port has encrypted them.
        #expect(await handles.server.uploadedFileNames == ["fake-encrypted-file:notes.txt"])
        #expect(await engine.state.vault.items.first { $0.id == "item-1" }?.attachmentCount == 1)
        let listed = try await engine.item(id: "item-1").attachments
        #expect(listed.map(\.fileName) == ["notes.txt"])
        #expect(listed.first?.sizeName == "\(file.count) Bytes")
        let id = try #require(listed.first?.id)

        #expect(try await engine.attachment(id, of: "item-1") == AttachmentFile(fileName: "notes.txt", data: file))

        try await engine.deleteAttachment(id, of: "item-1")
        #expect(await engine.state.vault.items.first { $0.id == "item-1" }?.attachmentCount == 0)
        #expect(try await engine.item(id: "item-1").attachments.isEmpty)
        #expect(await engineError { _ = try await engine.attachment(id, of: "item-1") } == .notFound)
        #expect(await engine.state.activity == nil)
    }

    @Test func aFileOfTheOldKindGetsAKeyOfItsOwn() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.addOldAttachment(named: "old.txt", contents: file, to: "item-1")
        try await engine.sync()
        let old = try #require(try await engine.item(id: "item-1").attachments.first)
        #expect(!old.hasOwnKey)

        try await engine.repairAttachment(old.id, of: "item-1")

        // The file was stored again, encrypted anew, and the old one is gone.
        #expect(await handles.server.uploadedFileNames == ["fake-encrypted-file:old.txt"])
        let listed = try await engine.item(id: "item-1").attachments
        #expect(listed.map(\.fileName) == ["old.txt"] && listed.first?.hasOwnKey == true && listed.first?.id != old.id)
        #expect(await engine.state.vault.items.first { $0.id == "item-1" }?.attachmentCount == 1)
        let new = try #require(listed.first)
        #expect(try await engine.attachment(new.id, of: "item-1").data == file)
        // A file with a key of its own is not stored again.
        #expect(await engineError { try await engine.repairAttachment(new.id, of: "item-1") } == .invalidState)
        #expect(await handles.server.uploadedFileNames.count == 1)
        #expect(await engine.state.activity == nil)
    }

    @Test func theOldFileStaysWhenTheServerKeepsTheNewOneWrong() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        await handles.server.addOldAttachment(named: "old.txt", contents: file, to: "item-1")
        try await engine.sync()
        let old = try #require(try await engine.item(id: "item-1").attachments.first)
        await handles.server.setDamagesNextUpload()

        let error = await engineError { try await engine.repairAttachment(old.id, of: "item-1") }

        // The damaged copy was removed again; the old file is all the item has, and it still reads.
        if case .server = error {} else { Issue.record("expected a refusal, got \(String(describing: error))") }
        let listed = await handles.server.attachmentList(of: "item-1")
        #expect(listed.map(\.id) == [old.id] && listed.first?.hasOwnKey == false)
        #expect(try await engine.attachment(old.id, of: "item-1").data == file)
        #expect(await engine.state.vault.items.first { $0.id == "item-1" }?.attachmentCount == 1)
        #expect(await engine.state.activity == nil)
    }

    @Test func aFileThatCannotBeAddedSendsNothing() async throws {
        let (engine, handles) = try await makeUnlockedEngine()

        #expect(await engineError { try await engine.addAttachment(to: "item-1", fileName: "empty", data: Data()) } == .attachmentTooLarge)
        #expect(await engineError { try await engine.addAttachment(to: "item-1", fileName: "", data: file) } == .invalidState)
        // An item in the trash takes no file.
        #expect(await engineError { try await engine.addAttachment(to: "item-7", fileName: "notes.txt", data: file) } == .invalidState)
        #expect(await engineError { try await engine.addAttachment(to: "missing", fileName: "notes.txt", data: file) } == .notFound)
        #expect(await engineError { try await engine.deleteAttachment("attachment-1", of: "missing") } == .notFound)
        await engine.lock()
        #expect(await engineError { try await engine.addAttachment(to: "item-1", fileName: "notes.txt", data: file) } == .invalidState)
        #expect(await engineError { _ = try await engine.attachment("attachment-1", of: "item-1") } == .invalidState)
        #expect(await handles.server.uploadedFileNames.isEmpty)
    }

    @Test func aFileOfAnItemSurvivesTheFormOfThatItem() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        try await engine.addAttachment(to: "item-2", fileName: "receipt.pdf", data: file)

        var draft = try await engine.draft(of: "item-2")
        draft.name = "Example Shop, renamed"
        try await engine.save(draft)

        let item = try await engine.item(id: "item-2")
        #expect(item.name == "Example Shop, renamed")
        #expect(item.attachments.map(\.fileName) == ["receipt.pdf"])
    }
}
