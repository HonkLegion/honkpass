import Engine
import EngineFakes
import Foundation
import Testing
import VaultModel

/// Export and import of the vault through the engine, on fakes.
@Suite struct EngineExportImportTests {
    @Test func anExportAsksForTheMasterPasswordAndLeavesTheTrashOut() async throws {
        let (engine, _) = try await makeUnlockedEngine()
        let password = FakeAccount.demo.masterPassword

        await #expect(throws: EngineError.wrongMasterPassword) {
            _ = try await engine.exportVault(format: .json, masterPassword: "another password")
        }
        let lines = String(decoding: try await engine.exportVault(format: .json, masterPassword: password), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(lines.first == "fake-export:json")
        #expect(lines.contains("Example Mail") && !lines.contains("Example Old Login"))
        #expect(String(decoding: try await engine.exportVault(format: .encryptedJson(password: "file-password"), masterPassword: password),
                       as: UTF8.self).hasPrefix("fake-export:encrypted:file-password"))
        #expect(VaultExportFormat.csv.fileExtension == "csv" && VaultExportFormat.encryptedJson(password: "x").fileExtension == "json")

        await engine.lock()
        await #expect(throws: EngineError.invalidState) { _ = try await engine.exportVault(format: .csv, masterPassword: password) }
    }

    @Test func anImportAddsItsFoldersAndItemsInOneCall() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let before = await engine.state.vault.items.count
        let file = VaultImport(folders: [.init(name: "Imported")], items: [
            .init(draft: ItemDraft(name: "Imported Login", content: .login(.init(username: "imported-user", password: "synthetic",
                                                                               websites: [.init(address: "https://imported.example")]))),
                  folder: 0),
            .init(draft: ItemDraft(name: "Imported Note", notes: "text", content: .secureNote)),
        ])

        try await engine.importVault(file)
        #expect(await handles.server.imports == [file])
        let vault = await engine.state.vault
        #expect(vault.items.count == before + 2)
        let folder = try #require(vault.folders.first { $0.name == "Imported" })
        let login = try #require(vault.items.first { $0.name == "Imported Login" })
        #expect(login.folderID == folder.id && login.subtitle == "imported-user")
        #expect(vault.items.first { $0.name == "Imported Note" }?.folderID == nil)
        // The login is found for its website like any other.
        #expect(vault.logins(ofPage: "https://imported.example/login").map(\.name) == ["Imported Login"])

        // Into a folder the vault has: no second folder of that name, and every item in it or under it.
        let placed = VaultImport(items: [.init(draft: ItemDraft(name: "Imported Card", content: .card(CardContent())))])
            .placed(in: folder)
        try await engine.importVault(placed)
        let after = await engine.state.vault
        #expect(after.folders.filter { $0.name == "Imported" }.count == 1)
        #expect(after.items.first { $0.name == "Imported Card" }?.folderID == folder.id)

        // A file without items is nothing to import, and a locked vault takes none.
        await #expect(throws: EngineError.invalidState) { try await engine.importVault(VaultImport()) }
        await engine.lock()
        await #expect(throws: EngineError.invalidState) { try await engine.importVault(file) }
        #expect(await handles.server.imports.count == 2)
    }

    @Test func importedCredentialsReachTheFakeAdapterAndItsReadback() async throws {
        let (engine, handles) = try await makeUnlockedEngine()
        let data = Data(#"{"items":[{"type":1,"name":"Imported credentials","login":{"fido2Credentials":[{"credentialId":"synthetic-id","keyType":"public-key","keyAlgorithm":"ECDSA","keyCurve":"P-256","keyValue":"synthetic-key","rpId":"example.test","counter":"0","discoverable":"true","creationDate":"2026-01-01T00:00:00Z"}]},"passwordHistory":[{"password":"synthetic-old","lastUsedDate":"2026-01-01T00:00:00Z"}]}]}"#.utf8)
        let file = try VaultImportFormat.bitwardenJSON.read(data)
        try await engine.importVault(file)
        #expect(await handles.server.imports == [file])
        let item = try #require(await engine.state.vault.items.first { $0.name == "Imported credentials" })
        #expect(item.passkeys.first?.credentialID == Data("synthetic-id".utf8))
        #expect(try await engine.passwordHistory(of: item.id) == file.items[0].passwordHistory)
        let replacement = PasskeyRegistrationRequest(rpID: "example.test", userName: "replacement-user", userHandle: Data("synthetic".utf8),
            clientDataHash: Data(repeating: 0, count: 32), algorithms: [-7], userVerification: .required, isUserVerified: true, itemID: item.id)
        guard case .passkeyRegistration(let registered) = await engine.autoFill(.registerPasskey(replacement)) else {
            throw EngineError.invalidState
        }
        #expect(await engine.state.vault.items.first { $0.id == item.id }?.passkeys.first?.credentialID == registered.credentialID)
        var draft = try await engine.draft(of: item.id)
        guard case .login(var login) = draft.content else { throw EngineError.invalidState }
        #expect(login.passkeyCreated != nil)
        login.passkeyCreated = nil
        draft.content = .login(login)
        _ = try await engine.save(draft)
        #expect(await engine.state.vault.items.first { $0.id == item.id }?.passkeys.isEmpty == true)
    }
}
