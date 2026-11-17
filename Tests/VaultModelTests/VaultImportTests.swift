import Foundation
import Testing
@testable import VaultModel

/// The reader of the exports of Bitwarden. Every value is synthetic.
@Suite struct VaultImportTests {
    private let json = """
    {"encrypted": false,
     "folders": [{"id": "f1", "name": "Work"}, {"id": "f2", "name": "Home"}],
     "items": [
      {"type": 1, "name": "Example Mail", "notes": "a note", "favorite": true, "reprompt": 1, "folderId": "f2",
       "login": {"username": "user@example.com", "password": "synthetic-password", "totp": "JBSWY3DPEHPK3PXP",
                 "uris": [{"uri": "https://mail.example.com", "match": null}, {"uri": "https://example.org/login", "match": 3}]},
       "fields": [{"name": "plain", "value": "one", "type": 0}, {"name": "secret", "value": "two", "type": 1},
                  {"name": "flag", "value": "true", "type": 2}, {"name": "linked", "value": null, "type": 3, "linkedId": 100}]},
      {"type": 2, "name": "Example Note", "notes": "text", "secureNote": {"type": 0}},
      {"type": 3, "name": "Example Card", "card": {"cardholderName": "Test Person", "brand": "Visa", "number": "4242424242424242",
                                                   "expMonth": "12", "expYear": "2030", "code": "123"}},
      {"type": 4, "name": "Example Identity", "identity": {"firstName": "Test", "lastName": "Person", "email": "test@example.com",
                                                           "ssn": "000-00-0000", "city": "Brno"}},
      {"type": 5, "name": "Example Key", "sshKey": {"privateKey": "fake-private-key", "publicKey": "fake-public-key",
                                                    "keyFingerprint": "SHA256:fake"}},
      {"type": 1, "name": "Deleted", "deletedDate": "2026-01-01T00:00:00.000Z", "login": {}},
      {"type": 1, "name": "Of an organization", "organizationId": "org-1", "login": {}},
      {"type": 9, "name": "Unknown type"}
     ]}
    """

    @Test func theJsonExportOfBitwardenBecomesFoldersAndDrafts() throws {
        let read = try VaultImportFormat.bitwardenJSON.read(Data(json.utf8))
        #expect(read.folders.map(\.name) == ["Work", "Home"] && read.newFolderCount == 2)
        // The item of the trash, the one of an organization and the unknown type are left out.
        #expect(read.items.map(\.draft.name) == ["Example Mail", "Example Note", "Example Card", "Example Identity", "Example Key"])
        #expect(read.count(of: .login) == 1 && read.count(of: .card) == 1 && read.count(of: .sshKey) == 1)

        let mail = try #require(read.items.first)
        #expect(mail.folder == 1 && mail.draft.isFavorite && mail.draft.asksForMasterPassword && mail.draft.notes == "a note")
        #expect(mail.draft.content == .login(ItemDraft.Login(
            username: "user@example.com", password: "synthetic-password", verificationKey: "JBSWY3DPEHPK3PXP",
            websites: [.init(address: "https://mail.example.com"), .init(address: "https://example.org/login", match: .exact)])))
        #expect(mail.draft.customFields == [
            CustomField(name: "plain", value: .text("one")), CustomField(name: "secret", value: .hidden("two")),
            CustomField(name: "flag", value: .boolean(true)), CustomField(name: "linked", value: .linked(100)),
        ])
        #expect(read.items[1].folder == nil && read.items[1].draft.content == .secureNote)
        guard case .card(let card) = read.items[2].draft.content, case .identity(let identity) = read.items[3].draft.content,
              case .sshKey(let key) = read.items[4].draft.content else {
            Issue.record("the types of the items are not the ones of the file")
            return
        }
        #expect(card.number == "4242424242424242" && card.expirationYear == "2030" && card.securityCode == "123")
        #expect(identity.firstName == "Test" && identity.socialSecurityNumber == "000-00-0000" && identity.city == "Brno")
        #expect(key.privateKey == "fake-private-key" && key.fingerprint == "SHA256:fake")
    }

    @Test func aFileThatIsEncryptedEmptyOrSomethingElseIsRefused() {
        #expect(throws: VaultImportError.encrypted) {
            try VaultImportFormat.bitwardenJSON.read(Data(#"{"encrypted": true, "data": "2.abc"}"#.utf8))
        }
        #expect(throws: VaultImportError.empty) {
            try VaultImportFormat.bitwardenJSON.read(Data(#"{"encrypted": false, "items": []}"#.utf8))
        }
        #expect(throws: VaultImportError.notReadable) { try VaultImportFormat.bitwardenJSON.read(Data("name,type".utf8)) }
        #expect(throws: VaultImportError.notReadable) { try VaultImportFormat.bitwardenCSV.read(Data("just a text".utf8)) }
    }

    @Test func passwordHistoryIsRetainedByTheImportModel() throws {
        let source = Data(#"{"items":[{"type":1,"name":"Synthetic","login":{},"passwordHistory":[{"password":"synthetic-old","lastUsedDate":"2026-01-02T03:04:05.000Z"}]}]}"#.utf8)
        let file = try VaultImportFormat.bitwardenJSON.read(source)
        let encoded = String(decoding: try JSONEncoder().encode(file), as: UTF8.self)
        #expect(encoded.contains("synthetic-old"))
    }

    private var passkey: [String: Any] { [
        "credentialId": "synthetic-credential", "keyType": "public-key", "keyAlgorithm": "ECDSA", "keyCurve": "P-256",
        "keyValue": "synthetic-key-material", "rpId": "example.test", "userHandle": NSNull(), "userName": "synthetic-user",
        "counter": "12", "rpName": "Example", "userDisplayName": "Synthetic", "discoverable": "true",
        "creationDate": "2026-01-02T03:04:05.123Z",
    ] }

    @Test func allPasskeysAndHistorySurvivePlacementAndCodable() throws {
        let history = (0..<7).map { ["password": "synthetic-old-\($0)", "lastUsedDate": "2026-01-02T03:04:05Z"] }
        let root: [String: Any] = ["items": [["type": 1, "name": "Synthetic", "login": ["fido2Credentials": [passkey, passkey]],
                                             "passwordHistory": history]]]
        let file = try VaultImportFormat.bitwardenJSON.read(JSONSerialization.data(withJSONObject: root))
        let first = try #require(file.items.first)
        #expect(first.passkeys?.count == 2 && first.passwordHistory?.count == 7)
        #expect(first.passkeys?.first?.keyValue == "synthetic-key-material")
        let placed = file.placed(in: VaultFolder(id: "existing", name: "Imported"))
        #expect(placed.items[0].passkeys == first.passkeys && placed.items[0].passwordHistory == first.passwordHistory)
        #expect(try JSONDecoder().decode(VaultImport.self, from: JSONEncoder().encode(placed)) == placed)
        #expect(placed.summary.itemCount == 1 && placed.summary.count(of: .login) == 1 && placed.summary.newFolderCount == 0)
        // Old Codable imports have neither metadata array; both decode as absent.
        let legacy = Data(#"{"items":[{"draft":{"name":"Legacy","notes":"","content":{"secureNote":{}},"isFavorite":false,"asksForMasterPassword":false,"customFields":[],"collectionIDs":[]}}],"folders":[]}"#.utf8)
        #expect(try JSONDecoder().decode(VaultImport.self, from: legacy).items[0].passkeys == nil)
    }

    @Test func malformedCredentialMetadataRejectsTheWholeImport() throws {
        var missingKey = passkey
        missingKey.removeValue(forKey: "keyValue")
        var wrongDate = passkey
        wrongDate["creationDate"] = "not-a-date"
        for bad in [[missingKey], [passkey, wrongDate], [passkey, ["keyValue": "partial"]]] {
            let root: [String: Any] = ["items": [["type": 1, "name": "Valid", "login": [:]],
                                                 ["type": 1, "name": "Invalid", "login": ["fido2Credentials": bad]]]]
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: VaultImportError.notReadable) { try VaultImportFormat.bitwardenJSON.read(data) }
        }
        for field in ["fido2Credentials", "passwordHistory"] {
            for bad: Any in ["not-an-array", ["not-an-object"], [["password": "synthetic", "lastUsedDate": "invalid"]]] {
                var item: [String: Any] = ["type": 1, "name": "Invalid", "login": [:]]
                if field == "fido2Credentials" { item["login"] = [field: bad] } else { item[field] = bad }
                let data = try JSONSerialization.data(withJSONObject: ["items": [item]])
                #expect(throws: VaultImportError.notReadable) { try VaultImportFormat.bitwardenJSON.read(data) }
            }
        }
    }

    @Test func theCsvExportOfBitwardenBecomesLoginsAndNotes() throws {
        let csv = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,1,login,Example Shop,"a note, with a comma","size: large
        colour: blue",0,"https://shop.example.com,https://example.org",shopper,"pass""word",
        Work,,note,Example Note,"two
        lines",,1,,,,
        ,,login,No folder,,,,,user,synthetic,
        ,,card,A card of another export,,,,,,,
        """
        let read = try VaultImportFormat.bitwardenCSV.read(Data(csv.utf8))
        #expect(read.folders.map(\.name) == ["Work"])
        #expect(read.items.map(\.draft.name) == ["Example Shop", "Example Note", "No folder"])

        // Moved into a folder of the vault: that folder first, the folder of the file under it,
        // and the item of no folder in it.
        let placed = read.placed(in: VaultFolder(id: "existing", name: "Imports"))
        #expect(placed.folders == [VaultImport.Folder(id: "existing", name: "Imports"), VaultImport.Folder(name: "Imports/Work")])
        #expect(placed.items.map(\.folder) == [1, 1, 0] && placed.newFolderCount == 1)
        let shop = read.items[0]
        #expect(shop.folder == 0 && shop.draft.isFavorite && !shop.draft.asksForMasterPassword && shop.draft.notes == "a note, with a comma")
        #expect(shop.draft.content == .login(ItemDraft.Login(
            username: "shopper", password: "pass\"word",
            websites: [.init(address: "https://shop.example.com"), .init(address: "https://example.org")])))
        #expect(shop.draft.customFields == [CustomField(name: "size", value: .text("large")), CustomField(name: "colour", value: .text("blue"))])
        #expect(read.items[1].draft.notes == "two\nlines" && read.items[1].draft.asksForMasterPassword && read.items[1].folder == 0)
        #expect(read.items[2].folder == nil)
    }
}
