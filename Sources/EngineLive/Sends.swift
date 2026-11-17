import BitwardenSdk
import Engine
import Foundation
import VaultModel

// Sends. The SDK makes the key of a Send, encrypts what it carries and hashes its password;
// PassVault builds the records of the server around its values.

extension SDKVault {
    /// The Sends of a sync answer. A Send that is not readable or does not decrypt is left out.
    func decryptSends(_ root: [String: Any]) -> [VaultSendSummary] {
        var encrypted: [String: Send] = [:]
        var summaries: [VaultSendSummary] = []
        for row in (JSON.field(root, "Sends") as? [[String: Any]]) ?? [] {
            guard let send = Self.send(fromServer: row), let id = send.id,
                  let view = try? client.sends().decrypt(send: send), let summary = VaultSendSummary(view, id: id) else { continue }
            encrypted[id] = send
            summaries.append(summary)
        }
        encryptedSends.withLock { $0 = encrypted }
        return summaries
    }

    func send(id: String) async throws -> VaultSend {
        guard let send = encryptedSends.withLock({ $0[id] }) else { throw EngineError.notFound }
        guard let view = try? client.sends().decrypt(send: send), let summary = VaultSendSummary(view, id: id) else {
            throw EngineError.itemNotReadable
        }
        // The key of the view is the one of the link: the text the web vault reads after "/".
        let linkPath: String? = if let accessID = view.accessId, let key = view.key { accessID + "/" + key } else { nil }
        return VaultSend(summary: summary, notes: view.notes, text: view.text?.text, hidesText: view.text?.hidden ?? false,
                         fileName: view.file?.fileName, fileSizeName: view.file?.sizeName, hidesEmail: view.hideEmail,
                         linkPath: linkPath)
    }

    func encryptSend(_ draft: SendDraft) async throws -> EncryptedSend {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes: String? = draft.notes.isEmpty ? nil : draft.notes
        let maxAccessCount = draft.maxAccessCount.map { UInt32(clamping: $0) }
        let view: SendView
        if let id = draft.id {
            guard let stored = encryptedSends.withLock({ $0[id] }) else { throw EngineError.notFound }
            guard let old = try? client.sends().decrypt(send: stored) else { throw EngineError.itemNotWritable }
            // Everything the form does not hold stays as the Send has it: its key, its file,
            // the addresses it is for.
            let text: SendTextView? = draft.type == .text ? SendTextView(text: draft.text, hidden: draft.hidesText) : old.text
            let asksForPassword = draft.newPassword != nil || old.hasPassword
            view = SendView(id: old.id, accessId: old.accessId, name: name, notes: notes, key: old.key,
                            newPassword: draft.newPassword, hasPassword: old.hasPassword, type: old.type, file: old.file,
                            text: text, data: old.data, maxAccessCount: maxAccessCount, accessCount: old.accessCount,
                            disabled: old.disabled, hideEmail: draft.hidesEmail, revisionDate: old.revisionDate,
                            deletionDate: draft.deletionDate, expirationDate: draft.deletionDate, emails: old.emails,
                            authType: old.authType == .email ? .email : (asksForPassword ? .password : .none))
        } else {
            let now = Date()
            view = SendView(id: nil, accessId: nil, name: name, notes: notes, key: nil, newPassword: draft.newPassword,
                            hasPassword: false, type: draft.type == .text ? .text : .file,
                            file: draft.file.map { SendFileView(id: nil, fileName: $0.name, size: nil, sizeName: nil) },
                            text: draft.type == .text ? SendTextView(text: draft.text, hidden: draft.hidesText) : nil,
                            data: nil, maxAccessCount: maxAccessCount, accessCount: 0, disabled: false,
                            hideEmail: draft.hidesEmail, revisionDate: now, deletionDate: draft.deletionDate,
                            expirationDate: draft.deletionDate, emails: [],
                            authType: draft.newPassword != nil ? .password : .none)
        }
        let send: Send
        do {
            send = try client.sends().encrypt(send: view)
        } catch {
            throw EngineError.unexpected("The SDK could not encrypt the Send.")
        }
        var file: EncryptedSendFile?
        if draft.id == nil, let source = draft.file {
            guard let fileName = send.file?.fileName else { throw EngineError.unexpected("The SDK gave the file of the Send no name.") }
            do {
                file = EncryptedSendFile(fileName: fileName, contents: try client.sends().encryptBuffer(send: send, buffer: source.data))
            } catch {
                throw EngineError.unexpected("The SDK could not encrypt the file of the Send.")
            }
        }
        return EncryptedSend(request: try Self.request(for: send, fileLength: file?.contents.count), file: file)
    }

    // MARK: The records of the server

    /// SendRequest of the reference (libs/common/src/tools/send/models/request/send.request.ts).
    private static func request(for send: Send, fileLength: Int?) throws -> Data {
        var body: [String: Any] = [
            "type": send.type == .file ? 1 : 0, "name": send.name, "key": send.key,
            "deletionDate": ServerDate.text(send.deletionDate), "disabled": send.disabled, "hideEmail": send.hideEmail,
            "authType": Int(send.authType.rawValue),
        ]
        body["notes"] = send.notes ?? NSNull()
        body["maxAccessCount"] = send.maxAccessCount.map { Int($0) } ?? NSNull()
        body["expirationDate"] = send.expirationDate.map(ServerDate.text) ?? NSNull()
        body["password"] = send.password ?? NSNull()
        body["emails"] = send.emails ?? NSNull()
        if let text = send.text { body["text"] = ["text": text.text ?? NSNull(), "hidden": text.hidden] as [String: Any] }
        if let file = send.file { body["file"] = ["fileName": file.fileName] }
        if let fileLength { body["fileLength"] = fileLength }
        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw EngineError.unexpected("The Send could not be written for the server.")
        }
    }

    /// SendResponse of the reference. nil for a record without an identifier, a name, a key or
    /// a day of deletion, and for a type PassVault does not know.
    private static func send(fromServer row: [String: Any]) -> Send? {
        guard let id = JSON.string(row, "Id"), UUID(uuidString: id) != nil,
              let name = JSON.string(row, "Name"), let key = JSON.string(row, "Key"),
              let typeNumber = JSON.integer(row, "Type"), let deletion = JSON.string(row, "DeletionDate").flatMap(ServerDate.date) else {
            return nil
        }
        let type: BitwardenSdk.SendType
        var text: SendText?
        var file: SendFile?
        switch typeNumber {
        case 0:
            type = .text
            guard let part = JSON.field(row, "Text") as? [String: Any] else { return nil }
            text = SendText(text: JSON.string(part, "Text"), hidden: (JSON.field(part, "Hidden") as? Bool) ?? false)
        case 1:
            type = .file
            guard let part = JSON.field(row, "File") as? [String: Any], let fileName = JSON.string(part, "FileName") else { return nil }
            // The server writes the size as a number or as a text.
            let size = JSON.string(part, "Size") ?? JSON.integer(part, "Size").map(String.init)
            file = SendFile(id: JSON.string(part, "Id"), fileName: fileName, size: size, sizeName: JSON.string(part, "SizeName"))
        default:
            return nil
        }
        let password = JSON.string(row, "Password")
        let emails = JSON.string(row, "Emails")
        let authType: AuthType = switch JSON.integer(row, "AuthType") {
        case 0: .email
        case 1: .password
        case 2: .none
        // A server that does not name it: a Send with a password asks for it.
        default: password != nil ? .password : .none
        }
        return Send(id: id.lowercased(), accessId: JSON.string(row, "AccessId"), name: name, notes: JSON.string(row, "Notes"),
                    key: key, password: password, type: type, file: file, text: text, data: nil,
                    maxAccessCount: JSON.integer(row, "MaxAccessCount").map { UInt32(clamping: $0) },
                    accessCount: UInt32(clamping: JSON.integer(row, "AccessCount") ?? 0),
                    disabled: (JSON.field(row, "Disabled") as? Bool) ?? false,
                    hideEmail: (JSON.field(row, "HideEmail") as? Bool) ?? false,
                    revisionDate: JSON.string(row, "RevisionDate").flatMap(ServerDate.date) ?? Date(timeIntervalSince1970: 0),
                    deletionDate: deletion, expirationDate: JSON.string(row, "ExpirationDate").flatMap(ServerDate.date),
                    emails: emails, authType: authType)
    }
}

extension VaultSendSummary {
    /// nil for a type PassVault has no form for.
    init?(_ view: SendView, id: String) {
        let type: VaultModel.SendType
        switch view.type {
        case .text: type = .text
        case .file: type = .file
        default: return nil
        }
        self.init(id: id, type: type, name: view.name, deletionDate: view.deletionDate, expirationDate: view.expirationDate,
                  maxAccessCount: view.maxAccessCount.map { Int($0) }, accessCount: Int(view.accessCount),
                  hasPassword: view.hasPassword, isDisabled: view.disabled)
    }
}

/// The dates of the server: ISO 8601 in UTC, with or without parts of a second.
enum ServerDate {
    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
