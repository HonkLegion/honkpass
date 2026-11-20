import Foundation

/// How an export of the vault is written.
public enum VaultExportFormat: Sendable, Equatable {
    case json, csv
    /// The JSON of the export, encrypted with a password of the file.
    case encryptedJson(password: String)

    /// The ending of the file name.
    public var fileExtension: String {
        self == .csv ? "csv" : "json"
    }
}

/// What a file holds that is imported into the vault: folders and new items, each in at most
/// one of the folders. Nothing of it has an identifier yet.
public struct VaultImport: Sendable, Codable, Equatable {
    public struct Item: Sendable, Codable, Equatable {
        public var draft: ItemDraft
        /// The place of the folder in `folders`. nil for an item in no folder.
        public var folder: Int?
        /// Import-only credentials. They never enter the editor draft or the success dialog.
        public var passkeys: [Passkey]?
        public var passwordHistory: [PasswordHistoryEntry]?

        public init(draft: ItemDraft, folder: Int? = nil, passkeys: [Passkey]? = nil,
                    passwordHistory: [PasswordHistoryEntry]? = nil) {
            self.draft = draft
            self.folder = folder
            self.passkeys = passkeys
            self.passwordHistory = passwordHistory
        }
    }

    /// The complete passkey of Bitwarden's JSON export. Encryption belongs to the SDK adapter.
    public struct Passkey: Sendable, Codable, Equatable {
        public let credentialId: String
        public let keyType: String
        public let keyAlgorithm: String
        public let keyCurve: String
        public let keyValue: String
        public let rpId: String
        public let userHandle: String?
        public let userName: String?
        public let counter: String
        public let rpName: String?
        public let userDisplayName: String?
        public let discoverable: String
        public let creationDate: Date
    }

    /// Counts only: a completed import must not keep credential material in UI state.
    public struct Summary: Sendable, Equatable {
        public let itemCount: Int
        public let newFolderCount: Int
        private let counts: [ItemType: Int]

        fileprivate init(_ file: VaultImport) {
            itemCount = file.items.count
            newFolderCount = file.newFolderCount
            counts = Dictionary(uniqueKeysWithValues: ItemType.allCases.map { ($0, file.count(of: $0)) })
        }

        public func count(of type: ItemType) -> Int { counts[type] ?? 0 }
    }

    public var summary: Summary { Summary(self) }

    /// A folder of the import. One with an identifier is a folder the vault has already.
    public struct Folder: Sendable, Codable, Equatable {
        public var id: String?
        public var name: String

        public init(id: String? = nil, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var folders: [Folder]
    public var items: [Item]

    public init(folders: [Folder] = [], items: [Item] = []) {
        self.folders = folders
        self.items = items
    }

    /// The import moved into a folder of the vault, as the reference does it for "select a
    /// folder": that folder comes first, the folders of the file become folders under it
    /// ("target/name"), and an item of no folder goes into it.
    public func placed(in target: VaultFolder) -> VaultImport {
        VaultImport(folders: [Folder(id: target.id, name: target.name)] + folders.map { Folder(name: target.name + "/" + $0.name) },
                    items: items.map { item in
                        var moved = item
                        moved.folder = (item.folder ?? -1) + 1
                        return moved
                    })
    }

    /// The folders the import adds to the vault.
    public var newFolderCount: Int {
        folders.count { $0.id == nil }
    }

    /// How many items of each type the file holds, for the summary after an import.
    public func count(of type: ItemType) -> Int {
        items.count { $0.draft.type == type }
    }
}

public enum VaultImportError: Error, Sendable, Equatable {
    /// The file is not what the chosen format is.
    case notReadable
    /// The file is an export that is encrypted. PassVault reads exports that are not.
    case encrypted
    /// The file is read and holds no item.
    case empty
}

/// The formats PassVault imports: the two exports of Bitwarden that are not encrypted.
public enum VaultImportFormat: String, Sendable, CaseIterable {
    case bitwardenJSON = "bitwardenjson"
    case bitwardenCSV = "bitwardencsv"

    /// Reads a file of this format. An item of a type PassVault has no form for, an item of
    /// the trash and an item of an organization are left out, as the reference leaves out
    /// what it cannot place.
    public func read(_ file: Data) throws -> VaultImport {
        let result = switch self {
        case .bitwardenJSON: try Self.readJSON(file)
        case .bitwardenCSV: try Self.readCSV(file)
        }
        guard !result.items.isEmpty else { throw VaultImportError.empty }
        return result
    }

    // MARK: JSON

    /// The unencrypted export of Bitwarden: `folders` with an identifier and a name, and `items`
    /// with `type` 1 to 5 (login, note, card, identity, SSH key) and the fields of that type.
    private static func readJSON(_ file: Data) throws -> VaultImport {
        guard let root = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any] else { throw VaultImportError.notReadable }
        if root["encrypted"] as? Bool == true { throw VaultImportError.encrypted }
        guard let items = root["items"] as? [[String: Any]] else { throw VaultImportError.notReadable }
        var result = VaultImport()
        var folderPlaces: [String: Int] = [:]
        for folder in (root["folders"] as? [[String: Any]]) ?? [] {
            guard let id = folder["id"] as? String, let name = folder["name"] as? String, !name.isEmpty else { continue }
            folderPlaces[id] = result.folders.count
            result.folders.append(VaultImport.Folder(name: name))
        }
        func text(_ object: [String: Any]?, _ key: String) -> String? {
            guard let value = object?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw VaultImportError.notReadable }
            return date
        }
        func entries<Value: Decodable>(_ raw: Any?, as type: Value.Type) throws -> [Value]? {
            guard let raw, !(raw is NSNull) else { return nil }
            guard let array = raw as? [Any] else { throw VaultImportError.notReadable }
            do {
                return try decoder.decode([Value].self, from: JSONSerialization.data(withJSONObject: array))
            } catch {
                // No partial success, and no decoder error that might contain credential data.
                throw VaultImportError.notReadable
            }
        }
        struct History: Decodable {
            let password: String
            let lastUsedDate: Date
        }
        for item in items {
            try Task.checkCancellation()
            guard item["deletedDate"] as? String == nil, item["organizationId"] as? String == nil,
                  let name = text(item, "name") else { continue }
            let content: ItemDraft.Content
            let passkeys = try entries((item["login"] as? [String: Any])?["fido2Credentials"], as: VaultImport.Passkey.self)
            let history = try entries(item["passwordHistory"], as: History.self)?.map {
                PasswordHistoryEntry(password: $0.password, lastUsed: $0.lastUsedDate)
            }
            guard passkeys?.isEmpty != false || item["type"] as? Int == 1 else { throw VaultImportError.notReadable }
            guard passkeys?.allSatisfy({ !$0.credentialId.isEmpty && !$0.keyValue.isEmpty && !$0.rpId.isEmpty }) != false else {
                throw VaultImportError.notReadable
            }
            switch item["type"] as? Int {
            case 1:
                let login = item["login"] as? [String: Any]
                let websites = ((login?["uris"] as? [[String: Any]]) ?? []).compactMap { uri -> ItemDraft.Website? in
                    guard let address = text(uri, "uri") else { return nil }
                    return ItemDraft.Website(address: address, match: (uri["match"] as? Int).flatMap(WebsiteMatch.init(rawValue:)))
                }
                content = .login(ItemDraft.Login(username: text(login, "username") ?? "", password: text(login, "password") ?? "",
                                                 verificationKey: text(login, "totp") ?? "", websites: websites))
            case 2:
                content = .secureNote
            case 3:
                let card = item["card"] as? [String: Any]
                content = .card(CardContent(cardholderName: text(card, "cardholderName"), brand: text(card, "brand"),
                                            number: text(card, "number"), expirationMonth: text(card, "expMonth"),
                                            expirationYear: text(card, "expYear"), securityCode: text(card, "code")))
            case 4:
                let source = item["identity"] as? [String: Any]
                var identity = IdentityContent()
                identity.title = text(source, "title")
                identity.firstName = text(source, "firstName")
                identity.middleName = text(source, "middleName")
                identity.lastName = text(source, "lastName")
                identity.username = text(source, "username")
                identity.company = text(source, "company")
                identity.socialSecurityNumber = text(source, "ssn")
                identity.passportNumber = text(source, "passportNumber")
                identity.licenseNumber = text(source, "licenseNumber")
                identity.email = text(source, "email")
                identity.phone = text(source, "phone")
                identity.address1 = text(source, "address1")
                identity.address2 = text(source, "address2")
                identity.address3 = text(source, "address3")
                identity.city = text(source, "city")
                identity.state = text(source, "state")
                identity.postalCode = text(source, "postalCode")
                identity.country = text(source, "country")
                content = .identity(identity)
            case 5:
                let key = item["sshKey"] as? [String: Any]
                guard let privateKey = text(key, "privateKey") else { continue }
                content = .sshKey(SSHKeyContent(privateKey: privateKey, publicKey: text(key, "publicKey") ?? "",
                                                fingerprint: text(key, "keyFingerprint") ?? ""))
            default:
                continue
            }
            let fields = ((item["fields"] as? [[String: Any]]) ?? []).compactMap { field -> CustomField? in
                let name = (field["name"] as? String) ?? ""
                let value = (field["value"] as? String) ?? ""
                switch field["type"] as? Int {
                case 0: return CustomField(name: name, value: .text(value))
                case 1: return CustomField(name: name, value: .hidden(value))
                case 2: return CustomField(name: name, value: .boolean(value == "true"))
                case 3: return (field["linkedId"] as? Int).map { CustomField(name: name, value: .linked($0)) }
                default: return nil
                }
            }
            let draft = ItemDraft(name: name, isFavorite: item["favorite"] as? Bool ?? false,
                                  asksForMasterPassword: item["reprompt"] as? Int == 1, notes: text(item, "notes") ?? "",
                                  content: content, customFields: fields)
            result.items.append(VaultImport.Item(draft: draft, folder: (item["folderId"] as? String).flatMap { folderPlaces[$0] },
                                                 passkeys: passkeys, passwordHistory: history))
        }
        return result
    }

    // MARK: CSV

    /// The CSV export of Bitwarden: a line of column names, then one line for each login and
    /// note: folder, favorite, type, name, notes, fields, reprompt, login_uri, login_username,
    /// login_password, login_totp. The websites of a login stand in one cell with commas between
    /// them, its custom fields in one cell as lines of "name: value".
    private static func readCSV(_ file: Data) throws -> VaultImport {
        guard let text = String(data: file, encoding: .utf8) else { throw VaultImportError.notReadable }
        var rows = try rows(ofCSV: text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let nameColumn = header.firstIndex(of: "name"), header.contains("type") else { throw VaultImportError.notReadable }
        let columns = Dictionary(header.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        rows.removeFirst()
        var result = VaultImport()
        var folderPlaces: [String: Int] = [:]
        for row in rows where row.count > nameColumn {
            try Task.checkCancellation()
            func cell(_ column: String) -> String {
                guard let index = columns[column], index < row.count else { return "" }
                return row[index]
            }
            let name = cell("name")
            guard !name.isEmpty else { continue }
            let content: ItemDraft.Content
            switch cell("type").lowercased() {
            case "login":
                let websites = cell("login_uri").split(separator: ",").map { ItemDraft.Website(address: String($0)) }
                content = .login(ItemDraft.Login(username: cell("login_username"), password: cell("login_password"),
                                                 verificationKey: cell("login_totp"), websites: websites))
            case "note":
                content = .secureNote
            default:
                continue
            }
            let fields = cell("fields").split(whereSeparator: \.isNewline).compactMap { line -> CustomField? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return CustomField(name: String(line[..<colon]), value: .text(value))
            }
            var folder: Int?
            let folderName = cell("folder")
            if !folderName.isEmpty {
                if let place = folderPlaces[folderName] {
                    folder = place
                } else {
                    folder = result.folders.count
                    folderPlaces[folderName] = result.folders.count
                    result.folders.append(VaultImport.Folder(name: folderName))
                }
            }
            let draft = ItemDraft(name: name, isFavorite: cell("favorite") == "1", asksForMasterPassword: cell("reprompt") == "1",
                                  notes: cell("notes"), content: content, customFields: fields)
            result.items.append(VaultImport.Item(draft: draft, folder: folder))
        }
        return result
    }

    /// The rows of a CSV text: cells between commas, a cell in quotes may hold commas, line
    /// breaks and doubled quotes.
    static func rows(ofCSV text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var isQuoted = false
        var characters = text.makeIterator()
        var pending = characters.next()
        var scanned = 0
        while let character = pending {
            if scanned.isMultiple(of: 4096) { try Task.checkCancellation() }
            scanned += 1
            pending = characters.next()
            if isQuoted {
                if character == "\"" {
                    if pending == "\"" {
                        cell.append("\"")
                        pending = characters.next()
                    } else {
                        isQuoted = false
                    }
                } else {
                    cell.append(character)
                }
            } else if character == "\"" {
                isQuoted = true
            } else if character == "," {
                row.append(cell)
                cell = ""
            } else if character.isNewline {
                row.append(cell)
                cell = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                cell.append(character)
            }
        }
        row.append(cell)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
