import BitwardenSdk
import Engine
import Foundation
import VaultModel

// Writing items. Two rules come first, both from HonkPass:
//
// 1. Nothing is written until the SDK has been seen to decrypt strictly: an item with a damaged
//    part must fail to decrypt, not come back with that part missing.
// 2. An item is written back only when every part the server holds of it has decrypted.
//
// Without them an edit could erase a field that only failed to decrypt.

extension SDKVault {
    /// Turns strict decryption on and checks that it works. The SDK reports success even when it
    /// ignores the flag, so the check decrypts synthetic items with one damaged part each.
    func prepareStrictDecryption() async {
        let works = (try? await Self.strictDecryptionWorks(client)) ?? false
        decryptsStrictly.withLock { $0 = works }
    }

    private static func strictDecryptionWorks(_ client: Client) async throws -> Bool {
        try await client.platform().loadFlags(flags: ["pm-34500-strict-cipher-decryption": true])
        // A synthetic login, encrypted under the unlocked key. It never leaves this process.
        let date = Date(), id = UUID().uuidString.lowercased()
        let login = LoginView(username: "synthetic", password: nil, passwordRevisionDate: nil, uris: nil, totp: nil,
                              autofillOnPageLoad: nil, fido2Credentials: nil)
        let encrypted = try await client.vault().ciphers().encrypt(cipherView: newView(
            name: "synthetic", notes: nil, folderID: nil, isFavorite: false, reprompt: .none, type: .login, login: login,
            identity: nil, card: nil, secureNote: nil, sshKey: nil, fields: nil, now: date)).cipher
        guard let name = encrypted.name, let username = encrypted.login?.username,
              let bar = name.lastIndex(of: "|"), name.index(after: bar) < name.endIndex else { return false }
        // The same text with another first character of its authentication code.
        var damaged = name
        let position = damaged.index(after: bar)
        damaged.replaceSubrange(position...position, with: damaged[position] == "A" ? "B" : "A")
        let stamp = ISO8601DateFormatter().string(from: date)
        var whole: [String: Any] = ["id": id, "type": 1, "name": name, "creationDate": stamp, "revisionDate": stamp,
                                    "login": ["username": username]]
        // The SDK may have given the item a key of its own, which then encrypts its parts.
        if let key = encrypted.key { whole["key"] = key }

        func decrypts(_ record: [String: Any]) async -> Bool? {
            guard let data = try? JSONSerialization.data(withJSONObject: record), let json = String(data: data, encoding: .utf8),
                  let cipher = client.vault().ciphers().cipherFromServerJson(json: json) else { return nil }
            return (try? await client.vault().ciphers().decrypt(cipher: cipher)) != nil
        }
        // The whole item decrypts, so a refusal below is about the damaged part alone.
        guard await decrypts(whole) == true else { return false }
        for part in 0..<5 {
            var record = whole
            var login: [String: Any] = ["username": username]
            switch part {
            case 0: login["password"] = damaged
            case 1: login["totp"] = damaged
            case 2: login["uris"] = [["uri": damaged]]
            case 3: record["fields"] = [["name": name, "value": damaged, "type": 1]]
            default:
                login["fido2Credentials"] = [[
                    "credentialId": name, "keyType": name, "keyAlgorithm": name, "keyCurve": name, "keyValue": damaged,
                    "rpId": name, "counter": name, "discoverable": name, "creationDate": stamp,
                ]]
            }
            record["login"] = login
            guard await decrypts(record) == false else { return false }
        }
        return true
    }

    // MARK: The form of an item

    func draft(id: String) async throws -> ItemDraft {
        let view = try await writableView(id)
        guard let draft = ItemDraft(view, id: id) else { throw EngineError.itemNotWritable }
        return draft
    }

    func encrypt(_ draft: ItemDraft) async throws -> Data {
        guard decryptsStrictly.withLock({ $0 }) else { throw EngineError.itemNotWritable }
        let view: CipherView
        if let id = draft.id {
            let original = try await writableView(id)
            guard original.type == Self.cipherType(draft.type) else { throw EngineError.itemNotWritable }
            // The form was made from another revision: its content would undo what it has not seen.
            guard original.revisionDate == draft.revised else { throw EngineError.itemChanged }
            view = Self.view(of: draft, replacing: original, now: Date())
        } else {
            view = Self.view(of: draft, replacing: nil, now: Date())
        }
        do {
            let context = try await client.vault().ciphers().encrypt(cipherView: view)
            // What goes to the server must decrypt again to the item that was meant, whole.
            let readBack = try await client.vault().ciphers().decrypt(cipher: context.cipher)
            guard Self.keepsEveryPart(context.cipher, readBack), Self.hasSameContent(readBack, view),
                  let request = client.vault().ciphers().cipherRequestJson(context: context) else {
                throw EngineError.unexpected("The encrypted item does not read back as it was written.")
            }
            // A new item of an organization goes to the server with its collections beside it.
            if draft.id == nil, draft.organizationID != nil {
                return try Self.shareRequest(cipher: request, collectionIDs: draft.collectionIDs)
            }
            return Data(request.utf8)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt the item.")
        }
    }

    /// The request that shares an item: the encrypted item, and the collections it goes into.
    private static func shareRequest(cipher: String, collectionIDs: [String]) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: Data(cipher.utf8)),
              let request = try? JSONSerialization.data(withJSONObject: ["cipher": object, "collectionIds": collectionIDs]) else {
            throw EngineError.unexpected("The shared item could not be written for the server.")
        }
        return request
    }

    /// An item of the user for an organization: the SDK gives it to the organization, which
    /// encrypts its key again, and what goes to the server must read back as the item it was.
    func encryptShare(itemID: String, organizationID: String, collectionIDs: [String]) async throws -> Data {
        let original = try await writableView(itemID)
        guard original.organizationId == nil else { throw EngineError.itemNotWritable }
        do {
            let moved = try client.vault().ciphers().moveToOrganization(cipher: original, organizationId: organizationID)
            let context = try await client.vault().ciphers().encrypt(cipherView: moved)
            let readBack = try await client.vault().ciphers().decrypt(cipher: context.cipher)
            guard context.cipher.organizationId == organizationID, Self.keepsEveryPart(context.cipher, readBack),
                  Self.hasSameContent(readBack, original),
                  let request = client.vault().ciphers().cipherRequestJson(context: context) else {
                throw EngineError.unexpected("The shared item does not read back as it was.")
            }
            return try Self.shareRequest(cipher: request, collectionIDs: collectionIDs)
        } catch let error as EngineError {
            throw error
        } catch {
            // The SDK refuses an item with a file that has no key of its own.
            throw EngineError.itemNotWritable
        }
    }

    func passwordHistory(id: String) async throws -> [PasswordHistoryEntry] {
        guard let cipher = encryptedItems.withLock({ $0[id] }) else { throw EngineError.notFound }
        do {
            let view = try await client.vault().ciphers().decrypt(cipher: cipher)
            return (view.passwordHistory ?? []).map { PasswordHistoryEntry(password: $0.password, lastUsed: $0.lastUsedDate) }
        } catch {
            throw EngineError.itemNotReadable
        }
    }

    // MARK: History of the generator

    /// One entry as the store keeps it: the value encrypted by the SDK, the rest in clear.
    private struct StoredGenerated: Codable {
        var value: String
        var kind: GeneratorKind
        var date: Date
    }

    func encryptGenerated(_ value: GeneratedValue) async throws -> Data {
        do {
            let encrypted = try client.vault().passwordHistory().encrypt(
                passwordHistory: PasswordHistoryView(password: value.value, lastUsedDate: value.date))
            return try JSONEncoder().encode(StoredGenerated(value: encrypted.password, kind: value.kind, date: value.date))
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt a value of the generator.")
        }
    }

    func decryptGenerated(_ entries: [Data]) async throws -> [GeneratedValue?] {
        entries.map { entry in
            guard let stored = try? JSONDecoder().decode(StoredGenerated.self, from: entry),
                  let view = try? client.vault().passwordHistory().decryptList(
                      list: [PasswordHistory(password: stored.value, lastUsedDate: stored.date)]).first else { return nil }
            return GeneratedValue(value: view.password, kind: stored.kind, date: stored.date)
        }
    }

    // MARK: Attachments

    /// The file is encrypted under a key of its own, which the key of the item wraps. The item
    /// must be one that can be written back whole, as for every other write.
    func encryptAttachment(itemID: String, fileName: String, data: Data) async throws -> EncryptedAttachment {
        _ = try await writableView(itemID)
        guard let cipher = encryptedItems.withLock({ $0[itemID] }) else { throw EngineError.notFound }
        do {
            let result = try client.vault().attachments().encryptBuffer(
                cipher: cipher, attachment: AttachmentView(id: nil, url: nil, size: nil, sizeName: nil, fileName: fileName, key: nil),
                buffer: data)
            guard let key = result.attachment.key, let name = result.attachment.fileName else {
                throw EngineError.unexpected("The SDK encrypted the file without a key or a name.")
            }
            return EncryptedAttachment(key: key, fileName: name, contents: result.contents)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt the file.")
        }
    }

    func decryptAttachment(itemID: String, attachmentID: String, contents: Data) async throws -> Data {
        guard let cipher = encryptedItems.withLock({ $0[itemID] }) else { throw EngineError.notFound }
        do {
            let view = try await client.vault().ciphers().decrypt(cipher: cipher)
            guard let attachment = (view.attachments ?? []).first(where: { $0.id == attachmentID }) else {
                throw EngineError.notFound
            }
            return try client.vault().attachments().decryptBuffer(cipher: cipher, attachment: attachment, buffer: contents)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unexpected("The SDK could not decrypt the file.")
        }
    }

    // MARK: Export and import

    func exportVault(format: VaultExportFormat) async throws -> Data {
        // The vault of the user: no item of the trash and none of an organization, as in the reference.
        let ciphers = encryptedItems.withLock { items in
            items.values.filter { $0.deletedDate == nil && $0.organizationId == nil }
        }
        let folders = encryptedFolders.withLock { $0 }
        let sdkFormat: ExportFormat = switch format {
        case .json: .json
        case .csv: .csv
        case .encryptedJson(let password): .encryptedJson(password: password)
        }
        do {
            return Data(try await client.exporters().exportVault(folders: folders, ciphers: ciphers, format: sdkFormat).utf8)
        } catch {
            throw EngineError.unexpected("The SDK could not write the export.")
        }
    }

    /// The request of the server's import: the encrypted items as the requests that create
    /// them one by one, the encrypted names of the folders, and which item goes into which folder.
    func encryptImport(_ file: VaultImport) async throws -> Data {
        guard decryptsStrictly.withLock({ $0 }) else { throw EngineError.itemNotWritable }
        do {
            var ciphers: [Any] = []
            var relations: [[String: Int]] = []
            let now = Date()
            for (place, item) in file.items.enumerated() {
                var draft = item.draft
                draft.id = nil
                draft.folderID = nil
                guard item.passkeys?.isEmpty != false || draft.type == .login else { throw EngineError.itemNotWritable }
                let view = Self.view(of: draft, replacing: nil, now: now, imported: item)
                let context = try await client.vault().ciphers().encrypt(cipherView: view)
                let readBack = try await client.vault().ciphers().decrypt(cipher: context.cipher)
                guard Self.keepsEveryPart(context.cipher, readBack), Self.hasSameContent(readBack, view),
                      (readBack.passwordHistory ?? []) == (view.passwordHistory ?? []),
                      let request = client.vault().ciphers().cipherRequestJson(context: context),
                      let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] else {
                    throw EngineError.unexpected("An item of the import could not be encrypted.")
                }
                ciphers.append(object)
                if let folder = item.folder, file.folders.indices.contains(folder) { relations.append(["key": place, "value": folder]) }
            }
            // A folder the vault has already goes with its identifier: the server takes it as it is.
            var folders: [[String: String]] = []
            for folder in file.folders {
                var entry = ["name": try await encryptFolderName(folder.name)]
                if let id = folder.id { entry["id"] = id }
                folders.append(entry)
            }
            return try JSONSerialization.data(withJSONObject: ["ciphers": ciphers, "folders": folders, "folderRelationships": relations])
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt the import.")
        }
    }

    func encryptFolderName(_ name: String) async throws -> String {
        do {
            return try client.vault().folders().encrypt(folder: FolderView(id: nil, name: name, revisionDate: Date())).name
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt the name of the folder.")
        }
    }

    /// The decrypted item, when it can be written back whole.
    func writableView(_ id: String) async throws -> CipherView {
        guard decryptsStrictly.withLock({ $0 }) else { throw EngineError.itemNotWritable }
        guard let cipher = encryptedItems.withLock({ $0[id] }) else { throw EngineError.notFound }
        guard let view = try? await client.vault().ciphers().decrypt(cipher: cipher),
              Self.isWritable(view), Self.keepsEveryPart(cipher, view) else { throw EngineError.itemNotWritable }
        return view
    }

    /// An item that the user may change and see whole, and that is not in the trash: one of
    /// their own vault, or one of an organization that lets them.
    static func isWritable(_ view: CipherView) -> Bool {
        !view.partial && view.edit && view.viewPassword && view.deletedDate == nil
            && (view.attachmentDecryptionFailures ?? []).isEmpty
    }

    /// Whether every part the server holds of the item is in its decrypted view. Strict decryption
    /// still leaves out a website with a wrong checksum, and such a view must never be written back.
    static func keepsEveryPart(_ cipher: Cipher, _ view: CipherView) -> Bool {
        func kept(_ encrypted: String?, _ value: String?) -> Bool { encrypted == nil || value != nil }
        let fields = cipher.fields ?? [], shownFields = view.fields ?? []
        guard cipher.data == nil, cipher.partialData == nil, cipher.type == view.type,
              fields.count == shownFields.count,
              zip(fields, shownFields).allSatisfy({ kept($0.name, $1.name) && kept($0.value, $1.value) }),
              (cipher.passwordHistory?.count ?? 0) == (view.passwordHistory?.count ?? 0),
              (cipher.attachments?.count ?? 0) == (view.attachments?.count ?? 0),
              kept(cipher.notes, view.notes) else { return false }
        switch view.type {
        case .login:
            guard let login = cipher.login, let shown = view.login else { return false }
            let uris = login.uris ?? [], shownURIs = shown.uris ?? []
            let passkeys = login.fido2Credentials ?? [], shownPasskeys = shown.fido2Credentials ?? []
            return uris.count == shownURIs.count && zip(uris, shownURIs).allSatisfy { kept($0.uri, $1.uri) }
                && passkeys.count == shownPasskeys.count
                && zip(passkeys, shownPasskeys).allSatisfy {
                    kept($0.userHandle, $1.userHandle) && kept($0.userName, $1.userName)
                        && kept($0.userDisplayName, $1.userDisplayName) && kept($0.rpName, $1.rpName)
                }
                && kept(login.username, shown.username) && kept(login.password, shown.password) && kept(login.totp, shown.totp)
        case .card:
            guard let card = cipher.card, let shown = view.card else { return false }
            return kept(card.cardholderName, shown.cardholderName) && kept(card.number, shown.number)
                && kept(card.expMonth, shown.expMonth) && kept(card.expYear, shown.expYear)
                && kept(card.code, shown.code) && kept(card.brand, shown.brand)
        case .identity:
            guard let identity = cipher.identity, let shown = view.identity else { return false }
            let pairs: [(String?, String?)] = [
                (identity.title, shown.title), (identity.firstName, shown.firstName), (identity.middleName, shown.middleName),
                (identity.lastName, shown.lastName), (identity.address1, shown.address1), (identity.address2, shown.address2),
                (identity.address3, shown.address3), (identity.city, shown.city), (identity.state, shown.state),
                (identity.postalCode, shown.postalCode), (identity.country, shown.country), (identity.company, shown.company),
                (identity.email, shown.email), (identity.phone, shown.phone), (identity.ssn, shown.ssn),
                (identity.username, shown.username), (identity.passportNumber, shown.passportNumber),
                (identity.licenseNumber, shown.licenseNumber),
            ]
            return pairs.allSatisfy { kept($0.0, $0.1) }
        case .secureNote:
            return cipher.secureNote != nil && view.secureNote != nil
        case .sshKey:
            guard let key = cipher.sshKey, let shown = view.sshKey else { return false }
            return !shown.privateKey.isEmpty && (key.publicKey == nil || !shown.publicKey.isEmpty)
                && (key.fingerprint == nil || !shown.fingerprint.isEmpty)
        default:
            return false
        }
    }

    /// The parts a form or this file sets are the same in both views.
    private static func hasSameContent(_ first: CipherView, _ second: CipherView) -> Bool {
        first.name == second.name && first.notes == second.notes && first.folderId == second.folderId
            && first.favorite == second.favorite && first.reprompt == second.reprompt && first.type == second.type
            && first.login?.username == second.login?.username && first.login?.password == second.login?.password
            && first.login?.totp == second.login?.totp
            && (first.login?.uris ?? []).map(\.uri) == (second.login?.uris ?? []).map(\.uri)
            && (first.login?.uris ?? []).map(\.match) == (second.login?.uris ?? []).map(\.match)
            && (first.login?.fido2Credentials ?? []) == (second.login?.fido2Credentials ?? [])
            && first.card == second.card && first.identity == second.identity && first.sshKey == second.sshKey
            && (first.fields ?? []) == (second.fields ?? [])
            && (first.passwordHistory ?? []).map(\.password) == (second.passwordHistory ?? []).map(\.password)
    }

    // MARK: From a form to an item

    /// The item of a form. For a change, everything the form does not hold stays as it is in
    /// `original`: passkeys, attachments, the item key, the dates. The password history grows
    /// as the SDK's own edit grows it (`update_password_history` of bitwarden-vault).
    static func view(of draft: ItemDraft, replacing original: CipherView?, now: Date, imported: VaultImport.Item? = nil) -> CipherView {
        func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        var history: [PasswordHistoryView] = []
        var login: LoginView?
        var card: CardView?
        var identity: IdentityView?
        var secureNote: SecureNoteView?
        var sshKey: SshKeyView?
        switch draft.content {
        case .login(let form):
            let old = original?.login
            // `detect_password_change`: the date of the password and the old password for the history.
            var passwordRevision = old?.passwordRevisionDate
            if let old {
                let oldPassword = old.password ?? ""
                if oldPassword.isEmpty {
                    if !form.password.isEmpty { passwordRevision = now }
                } else if oldPassword != form.password {
                    passwordRevision = now
                    history.append(PasswordHistoryView(password: oldPassword, lastUsedDate: now))
                }
            }
            let uris = form.websites.filter { !$0.address.isEmpty }.map { website in
                LoginUriView(uri: website.address, match: website.match.flatMap { UriMatchType(rawValue: UInt8($0.rawValue)) },
                             uriChecksum: nil)
            }
            login = LoginView(username: text(form.username), password: text(form.password), passwordRevisionDate: passwordRevision,
                              uris: uris.isEmpty ? nil : uris, totp: text(form.verificationKey),
                              autofillOnPageLoad: old?.autofillOnPageLoad, httpAuthenticationEnabled: old?.httpAuthenticationEnabled,
                              // The form can only remove the passkey: the login is then saved without it.
                              fido2Credentials: imported?.passkeys.map { $0.map { passkey in
                                  Fido2CredentialView(credentialId: passkey.credentialId, keyType: passkey.keyType,
                                      keyAlgorithm: passkey.keyAlgorithm, keyCurve: passkey.keyCurve, keyValue: passkey.keyValue,
                                      rpId: passkey.rpId, userHandle: passkey.userHandle, userName: passkey.userName,
                                      counter: passkey.counter, rpName: passkey.rpName, userDisplayName: passkey.userDisplayName,
                                      discoverable: passkey.discoverable, creationDate: passkey.creationDate)
                              } } ?? (form.passkeyCreated == nil ? nil : old?.fido2Credentials))
        case .card(let form):
            card = CardView(cardholderName: text(form.cardholderName), expMonth: text(form.expirationMonth),
                            expYear: text(form.expirationYear), code: text(form.securityCode), brand: text(form.brand),
                            number: text(form.number))
        case .identity(let form):
            identity = IdentityView(
                title: text(form.title), firstName: text(form.firstName), middleName: text(form.middleName),
                lastName: text(form.lastName), address1: text(form.address1), address2: text(form.address2),
                address3: text(form.address3), city: text(form.city), state: text(form.state),
                postalCode: text(form.postalCode), country: text(form.country), company: text(form.company),
                email: text(form.email), phone: text(form.phone), ssn: text(form.socialSecurityNumber),
                username: text(form.username), passportNumber: text(form.passportNumber), licenseNumber: text(form.licenseNumber))
        case .secureNote:
            secureNote = original?.secureNote ?? SecureNoteView(type: .generic)
        case .sshKey(let form):
            sshKey = SshKeyView(privateKey: form.privateKey, publicKey: form.publicKey, fingerprint: form.fingerprint)
        }
        let fields = draft.customFields.map { field in
            switch field.value {
            case .text(let value): FieldView(name: text(field.name), value: text(value), type: .text, linkedId: nil)
            case .hidden(let value): FieldView(name: text(field.name), value: text(value), type: .hidden, linkedId: nil)
            case .boolean(let isOn): FieldView(name: text(field.name), value: isOn ? "true" : "false", type: .boolean, linkedId: nil)
            case .linked(let id): FieldView(name: text(field.name), value: nil, type: .linked, linkedId: UInt32(exactly: id))
            }
        }
        let type = cipherType(draft.type)
        let reprompt: CipherRepromptType = draft.asksForMasterPassword ? .password : .none
        guard let original else {
            return newView(name: draft.name, notes: text(draft.notes), folderID: draft.folderID, isFavorite: draft.isFavorite,
                           reprompt: reprompt, type: type, login: login, identity: identity, card: card, secureNote: secureNote,
                           sshKey: sshKey, fields: fields.isEmpty ? nil : fields, now: now,
                           organizationID: draft.organizationID, collectionIDs: draft.organizationID == nil ? [] : draft.collectionIDs,
                           passwordHistory: imported?.passwordHistory?.map { PasswordHistoryView(password: $0.password, lastUsedDate: $0.lastUsed) })
        }
        // `detect_hidden_field_changes`: a hidden field whose value has changed or gone.
        var hiddenNow: [String: String] = [:]
        for field in fields where field.type == .hidden {
            if let name = field.name, let value = field.value { hiddenNow[name] = value }
        }
        var seen: Set<String> = []
        for field in original.fields ?? [] where field.type == .hidden {
            guard let name = field.name, !name.isEmpty, let value = field.value, !value.isEmpty, seen.insert(name).inserted,
                  hiddenNow[name] != value else { continue }
            history.append(PasswordHistoryView(password: "\(name): \(value)", lastUsedDate: now))
        }
        // The newest first, and no more than the SDK keeps.
        let kept = Array((history.reversed() + (original.passwordHistory ?? [])).prefix(5))
        return CipherView(
            id: original.id, organizationId: original.organizationId, folderId: draft.folderID,
            collectionIds: original.collectionIds, key: original.key, name: draft.name, notes: text(draft.notes),
            type: original.type, login: login, identity: identity, card: card, secureNote: secureNote, sshKey: sshKey,
            bankAccount: original.bankAccount, driversLicense: original.driversLicense, passport: original.passport,
            favorite: draft.isFavorite, reprompt: reprompt, organizationUseTotp: original.organizationUseTotp,
            edit: original.edit, permissions: original.permissions, viewPassword: original.viewPassword,
            localData: original.localData, attachments: original.attachments,
            attachmentDecryptionFailures: original.attachmentDecryptionFailures, fields: fields.isEmpty ? nil : fields,
            passwordHistory: kept.isEmpty ? original.passwordHistory : kept, creationDate: original.creationDate,
            deletedDate: original.deletedDate, revisionDate: original.revisionDate, archivedDate: original.archivedDate,
            partial: original.partial)
    }

    private static func cipherType(_ type: ItemType) -> CipherType {
        switch type {
        case .login: .login
        case .card: .card
        case .identity: .identity
        case .secureNote: .secureNote
        case .sshKey: .sshKey
        }
    }

    private static func newView(name: String, notes: String?, folderID: String?, isFavorite: Bool, reprompt: CipherRepromptType,
                                type: CipherType, login: LoginView?, identity: IdentityView?, card: CardView?,
                                secureNote: SecureNoteView?, sshKey: SshKeyView?, fields: [FieldView]?, now: Date,
                                organizationID: String? = nil, collectionIDs: [String] = [],
                                passwordHistory: [PasswordHistoryView]? = nil) -> CipherView {
        CipherView(
            id: nil, organizationId: organizationID, folderId: folderID, collectionIds: collectionIDs, key: nil, name: name, notes: notes,
            type: type, login: login, identity: identity, card: card, secureNote: secureNote, sshKey: sshKey,
            bankAccount: nil, driversLicense: nil, passport: nil, favorite: isFavorite, reprompt: reprompt,
            organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true, localData: nil,
            attachments: nil, attachmentDecryptionFailures: nil, fields: fields, passwordHistory: passwordHistory,
            creationDate: now, deletedDate: nil, revisionDate: now, archivedDate: nil, partial: false)
    }
}

extension ItemDraft {
    /// nil for the item types PassVault has no form for.
    init?(_ view: CipherView, id: String) {
        guard let item = VaultItem(view, id: id) else { return nil }
        let content: Content
        switch item.content {
        case .login:
            let login = view.login
            let websites = (login?.uris ?? []).compactMap { uri in
                uri.uri.map { Website(address: $0, match: uri.match.flatMap { WebsiteMatch(rawValue: Int($0.rawValue)) }) }
            }
            content = .login(Login(username: login?.username ?? "", password: login?.password ?? "",
                                   verificationKey: login?.totp ?? "", websites: websites,
                                   passkeyCreated: login?.fido2Credentials?.first?.creationDate))
        case .card(let card): content = .card(card)
        case .identity(let identity): content = .identity(identity)
        case .secureNote: content = .secureNote
        case .sshKey(let key): content = .sshKey(key)
        }
        self.init(id: id, revised: view.revisionDate, name: view.name, folderID: view.folderId, isFavorite: view.favorite,
                  asksForMasterPassword: view.reprompt == .password, notes: view.notes ?? "", content: content,
                  customFields: item.customFields, organizationID: view.organizationId, collectionIDs: view.collectionIds)
    }
}
