import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

@Suite struct EngineVaultSessionTests {
    @Test func preparedFilesCannotCrossALockAndUnlockOfTheSameAccount() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let token = try await engine.vaultSession()
        try await engine.checkVaultSession(token)
        await engine.lock()
        try await engine.unlock(masterPassword: FakeAccount.demo.masterPassword)
        #expect(try await engine.vaultSession() != token)
        #expect(await engineError { try await engine.checkVaultSession(token) } == .cancelled)
        let imported = VaultImport(items: [.init(draft: ItemDraft(name: "Synthetic prepared import", content: .secureNote))])
        #expect(await engineError { try await engine.importVault(imported, session: token) } == .cancelled)
        #expect(await engineError {
            _ = try await engine.saveSend(SendDraft(type: .text, name: "Synthetic Send", text: "synthetic", deletionDate: fixedDate),
                                          session: token)
        } == .cancelled)
        #expect(await engineError {
            try await engine.addAttachment(to: "item-1", fileName: "synthetic.txt", data: Data([1]), session: token)
        } == .cancelled)
        #expect(await engineError {
            _ = try await engine.exportVault(format: .json, masterPassword: FakeAccount.demo.masterPassword, session: token)
        } == .cancelled)
        #expect(await handles.server.imports.isEmpty)
        #expect(await handles.server.uploadedFileNames.isEmpty)
        let fresh = try await engine.vaultSession()
        try await engine.importVault(imported, session: fresh)
        #expect(await handles.server.imports == [imported])
    }

    @Test func preparedFilesCannotMoveToAnotherAccount() async throws {
        let first = FakeAccount.demo
        let second = FakeAccount(server: URL(string: "https://second.example")!, email: "second@example.test",
                                 masterPassword: "synthetic-second", userID: "00000000-0000-4000-8000-000000000002",
                                 contents: .empty)
        var (ports, handles) = EnginePorts.fake(first)
        let secondServer = FakeServer(account: second)
        ports.server = FakeServerRouter([first.server: handles.server, second.server: secondServer])
        let engine = Engine(ports: ports)
        await engine.start()
        try await engine.logIn(server: first.server, email: first.email, masterPassword: first.masterPassword)
        let token = try await engine.vaultSession()
        try await engine.addAccount()
        try await engine.logIn(server: second.server, email: second.email, masterPassword: second.masterPassword)
        let imported = VaultImport(items: [.init(draft: ItemDraft(name: "Synthetic stale import", content: .secureNote))])
        #expect(await engineError { try await engine.importVault(imported, session: token) } == .cancelled)
        #expect(await secondServer.imports.isEmpty)
        try await engine.switchAccount(to: first.userID)
        try await engine.unlock(masterPassword: first.masterPassword)
        #expect(await engineError { try await engine.checkVaultSession(token) } == .cancelled)
    }

    @Test func cancelledPreparationCannotStartAnImportAfterWaitingForAnotherCommand() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let token = try await engine.vaultSession()
        await handles.server.holdNextUpload()
        let active = Task { try await engine.addAttachment(to: "item-1", fileName: "synthetic.txt", data: Data([1])) }
        await handles.server.uploadIsHeld()
        let file = VaultImport(items: [.init(draft: ItemDraft(name: "Synthetic cancelled import", content: .secureNote))])
        let queued = Task { await engineError { try await engine.importVault(file, session: token) } }
        await Task.yield()
        queued.cancel()
        await handles.server.releaseUpload()
        try await active.value
        #expect(await queued.value == .cancelled)
        #expect(await handles.server.imports.isEmpty)
    }
}
