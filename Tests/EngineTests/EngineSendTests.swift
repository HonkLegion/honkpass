import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Sends through the engine, on fakes.
@Suite struct EngineSendTests {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aTextSendIsMadeChangedAndDeleted() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        #expect(await engine.state.vault.sends.isEmpty)

        let id = try await engine.saveSend(SendDraft(type: .text, name: "Example Send", notes: "a note", text: "shared text",
                                                    hidesText: true, deletionDate: day, maxAccessCount: 3, newPassword: "send-password"))
        let listed = try #require(await engine.state.vault.sends.first)
        #expect(listed.id == id && listed.name == "Example Send" && listed.type == .text && listed.hasPassword)
        #expect(listed.deletionDate == day && listed.expirationDate == day && listed.maxAccessCount == 3)
        let send = try await engine.send(id: id)
        #expect(send.text == "shared text" && send.hidesText && send.notes == "a note")

        // The link is the address of the server, then what the crypto port gives for the Send.
        let link = try await engine.sendLink(of: id)
        #expect(link == "https://vault.example/#/send/fake-access-\(id)/fake-key-\(id)")
        try await engine.copySendLink(of: id)
        #expect(await handles.clipboard.text == link)

        // A change keeps the password the form does not name.
        var draft = SendDraft(send)
        #expect(draft.newPassword == nil && draft.id == id)
        draft.name = "Example Send Renamed"
        draft.text = "another text"
        try await engine.saveSend(draft)
        let changed = try #require(await engine.state.vault.sends.first)
        #expect(await engine.state.vault.sends.count == 1 && changed.name == "Example Send Renamed" && changed.hasPassword)
        #expect(try await engine.send(id: id).text == "another text")

        try await engine.removeSendPassword(of: id)
        #expect(await engine.state.vault.sends.first?.hasPassword == false)
        #expect(await handles.server.removedSendPasswords == [id])
        await #expect(throws: EngineError.invalidState) { try await engine.removeSendPassword(of: id) }

        try await engine.deleteSend(id: id)
        #expect(await engine.state.vault.sends.isEmpty)
        await #expect(throws: EngineError.notFound) { try await engine.deleteSend(id: id) }
        await #expect(throws: EngineError.notFound) { _ = try await engine.send(id: id) }
    }

    @Test func aFileSendTakesItsFileOnceAndKeepsIt() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let file = SendDraft.File(name: "report.txt", data: Data("synthetic file".utf8))
        let id = try await engine.saveSend(SendDraft(type: .file, name: "Example File Send", file: file, deletionDate: day))

        // The server got the file as the crypto port made it, and the form without its content.
        let uploaded = await handles.server.uploadedSendFiles
        #expect(uploaded.count == 1 && uploaded.first?.fileName.hasSuffix("report.txt") == true)
        #expect(await handles.server.savedSends.allSatisfy { $0.file == nil })
        let send = try await engine.send(id: id)
        #expect(send.summary.type == .file && send.fileName == "report.txt" && send.fileSizeName == "14 Bytes")

        // A change of the Send keeps its file; the form cannot bring another one.
        var draft = SendDraft(send)
        draft.name = "Example File Send Renamed"
        try await engine.saveSend(draft)
        #expect(try await engine.send(id: id).fileName == "report.txt")
        #expect(await handles.server.uploadedSendFiles.count == 1)
        draft.file = file
        await #expect(throws: EngineError.invalidState) { try await engine.saveSend(draft) }
    }

    @Test func aSendThatIsNotCompleteOrTooLargeIsNotSent() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        func refused(_ draft: SendDraft, _ error: EngineError = .invalidState) async {
            await #expect(throws: error) { try await engine.saveSend(draft) }
        }
        await refused(SendDraft(type: .text, name: " ", text: "text", deletionDate: day))
        await refused(SendDraft(type: .text, name: "Name", text: "", deletionDate: day))
        await refused(SendDraft(type: .file, name: "Name", deletionDate: day))
        await refused(SendDraft(type: .text, name: "Name", text: "text", deletionDate: day, maxAccessCount: 0))
        await refused(SendDraft(type: .text, name: "Name", text: "text", deletionDate: day, newPassword: ""))
        await refused(SendDraft(type: .text, name: "Name", text: "text", file: .init(name: "a", data: Data([1])), deletionDate: day))
        await refused(SendDraft(type: .file, name: "Name", file: .init(name: "empty.txt", data: Data()), deletionDate: day),
                      .attachmentTooLarge)
        await refused(SendDraft(id: "unknown", type: .text, name: "Name", text: "text", deletionDate: day), .notFound)
        #expect(await handles.server.savedSends.isEmpty)

        // The type of a Send does not change.
        let id = try await engine.saveSend(SendDraft(type: .text, name: "Name", text: "text", deletionDate: day))
        await refused(SendDraft(id: id, type: .file, name: "Name", deletionDate: day))

        await engine.lock()
        await refused(SendDraft(type: .text, name: "Name", text: "text", deletionDate: day))
        await #expect(throws: EngineError.invalidState) { _ = try await engine.sendLink(of: id) }
    }

    @Test func theListOfSendsIsFilteredSearchedAndMarked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sends = [
            VaultSendSummary(id: "1", type: .text, name: "beta", deletionDate: now.addingTimeInterval(60)),
            VaultSendSummary(id: "2", type: .file, name: "Alpha", deletionDate: now.addingTimeInterval(-1),
                             expirationDate: now, maxAccessCount: 2, accessCount: 2),
            VaultSendSummary(id: "3", type: .text, name: "Gamma", deletionDate: now.addingTimeInterval(60), maxAccessCount: 2,
                             accessCount: 1),
        ]
        #expect(sends.shown(type: nil, search: "").map(\.name) == ["Alpha", "beta", "Gamma"])
        #expect(sends.shown(type: nil, search: "", sort: SendSort(isAscending: false)).map(\.name) == ["Gamma", "beta", "Alpha"])
        #expect(sends.shown(type: nil, search: "", sort: SendSort(column: .deletionDate)).map(\.name) == ["Alpha", "beta", "Gamma"])
        #expect(sends.shown(type: .text, search: " ").map(\.name) == ["beta", "Gamma"])
        #expect(sends.shown(type: nil, search: "ALP").map(\.name) == ["Alpha"])
        #expect(sends[1].isExpired(at: now) && sends[1].isPendingDeletion(at: now) && sends[1].isMaxAccessCountReached)
        #expect(!sends[0].isExpired(at: now) && !sends[0].isPendingDeletion(at: now) && !sends[2].isMaxAccessCountReached)

        let send = VaultSend(summary: sends[0], linkPath: "access/key")
        #expect(send.link(server: URL(string: "https://vault.example.com/")!) == "https://vault.example.com/#/send/access/key")
        #expect(send.link(server: URL(string: "https://example.com/vault")!) == "https://example.com/vault/#/send/access/key")
        #expect(VaultSend(summary: sends[0]).link(server: URL(string: "https://vault.example.com")!) == nil)
    }
}
