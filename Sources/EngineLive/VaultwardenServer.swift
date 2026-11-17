import Engine
import Foundation

/// The Vaultwarden REST API over URLSession. The SDK's own HTTP client is not used.
public struct VaultwardenServer: ServerPort {
    let http = HTTPClient()

    public init() {}

    /// Whether PassVault connects to this server URL: HTTPS, or plain HTTP on this Mac and the local network.
    public static func accepts(_ server: URL) -> Bool {
        HTTPClient.isAcceptable(server)
    }

    public func prelogin(server: URL, email: String) async throws -> Prelogin {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        let (data, status) = try await http.send(HTTPClient.jsonRequest("POST", server, "identity/accounts/prelogin", body: body))
        guard status == 200 else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = JSON.integer(object, "Kdf"),
              let iterations = JSON.integer(object, "KdfIterations").flatMap(UInt32.init(exactly:)), iterations > 0 else {
            throw EngineError.server("The prelogin answer is not readable.")
        }
        let kdf: KeyDerivation
        switch type {
        case 0:
            kdf = .pbkdf2(iterations: iterations)
        case 1:
            guard let memory = JSON.integer(object, "KdfMemory").flatMap(UInt32.init(exactly:)), memory > 0,
                  let parallelism = JSON.integer(object, "KdfParallelism").flatMap(UInt32.init(exactly:)), parallelism > 0 else {
                throw EngineError.server("The prelogin answer is not readable.")
            }
            kdf = .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
        default:
            throw EngineError.server("The account uses an unknown key derivation.")
        }
        // Without a salt from the server, the salt is the email as Bitwarden normalises it.
        let salt = JSON.string(object, "Salt") ?? email.trimmingCharacters(in: .whitespaces).lowercased()
        return Prelogin(kdf: kdf, salt: salt)
    }

    public func logIn(_ request: LoginRequest) async throws -> LoginOutcome {
        var urlRequest = try HTTPClient.request("POST", request.server, "identity/connect/token")
        urlRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        var fields = [
            ("scope", "api offline_access"), ("client_id", ClientIdentity.clientName), ("grant_type", "password"),
            ("deviceType", ClientIdentity.deviceType), ("deviceIdentifier", request.deviceIdentifier),
            ("deviceName", ClientIdentity.deviceName), ("username", request.email), ("password", request.passwordHash),
        ]
        var sentCode = false
        if let proof = request.twoStep {
            // The numbers of the two-step methods: 0 authenticator app, 1 email, 7 WebAuthn,
            // 5 the remembered device.
            let provider: String
            switch proof.kind {
            case .method(.authenticator): provider = "0"
            case .method(.email): provider = "1"
            case .method(.webAuthn): provider = "7"
            case .rememberedDevice: provider = "5"
            }
            sentCode = proof.kind != .rememberedDevice
            fields += [("twoFactorToken", proof.token), ("twoFactorProvider", provider),
                       ("twoFactorRemember", proof.remember ? "1" : "0")]
        }
        urlRequest.httpBody = JSON.formEncoded(fields)
        let (data, status) = try await http.send(urlRequest)
        return try TokenResponse.outcome(from: data, status: status, prelogin: request.prelogin, sentCode: sentCode)
    }

    public func sendTwoStepEmail(_ request: LoginRequest) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "email": request.email, "masterPasswordHash": request.passwordHash, "deviceIdentifier": request.deviceIdentifier,
        ])
        let (data, status) = try await http.send(HTTPClient.jsonRequest("POST", request.server, "api/two-factor/send-email-login", body: body))
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func importVault(request: Data, server: URL, accessToken: String) async throws {
        let urlRequest = try HTTPClient.jsonRequest("POST", server, "api/ciphers/import", body: request, accessToken: accessToken)
        let (data, status) = try await http.send(urlRequest)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func requestPasswordHint(server: URL, email: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        let (data, status) = try await http.send(HTTPClient.jsonRequest("POST", server, "api/accounts/password-hint", body: body))
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func isKnownDevice(server: URL, email: String, deviceIdentifier: String) async throws -> Bool {
        var request = try HTTPClient.request("GET", server, "api/devices/knowndevice")
        request.setValue(deviceIdentifier, forHTTPHeaderField: "X-Device-Identifier")
        // The address as URL-safe Base64 without padding (`Utils.fromUtf8ToUrlB64`).
        let address = Data(email.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        request.setValue(address, forHTTPHeaderField: "X-Request-Email")
        let (data, status) = try await http.send(request)
        guard status == 200 else { throw HTTPClient.refusal(data, status: status) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func sync(server: URL, accessToken: String) async throws -> Data {
        // With the domains: the groups that count as one domain when a login is matched to a page.
        let request = try HTTPClient.request("GET", server, "api/sync", accessToken: accessToken)
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard status == 200 else { throw HTTPClient.refusal(data, status: status) }
        return data
    }

    public func websiteIcon(server: URL, host: String) async throws -> Data {
        var request = try HTTPClient.request("GET", server, "icons/\(host)/icon.png")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, status) = try await http.send(request)
        guard status == 200, !data.isEmpty, data.count <= 1_048_576 else { throw HTTPClient.refusal(Data(), status: status) }
        return data
    }

    public func write(_ write: ItemWrite, itemID: String, server: URL, accessToken: String) async throws {
        // The identifier becomes a part of the path.
        guard UUID(uuidString: itemID) != nil else { throw EngineError.notFound }
        let path = "api/ciphers/" + itemID.lowercased()
        let request: URLRequest
        switch write {
        case .placement(let isFavorite, let folderID):
            let body = try JSONSerialization.data(withJSONObject: [
                "favorite": isFavorite, "folderId": folderID.map { $0 as Any } ?? NSNull(),
            ])
            request = try HTTPClient.jsonRequest("PUT", server, path + "/partial", body: body, accessToken: accessToken)
        case .archive:
            request = try HTTPClient.request("PUT", server, path + "/archive", accessToken: accessToken)
        case .unarchive:
            request = try HTTPClient.request("PUT", server, path + "/unarchive", accessToken: accessToken)
        case .moveToTrash:
            request = try HTTPClient.request("PUT", server, path + "/delete", accessToken: accessToken)
        case .restore:
            request = try HTTPClient.request("PUT", server, path + "/restore", accessToken: accessToken)
        case .deletePermanently:
            request = try HTTPClient.request("DELETE", server, path, accessToken: accessToken)
        }
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    /// The bulk requests of the Bitwarden clients: the identifiers in the body, one request.
    public func write(_ write: ItemBulkWrite, itemIDs: [String], server: URL, accessToken: String) async throws {
        guard !itemIDs.isEmpty, itemIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw EngineError.notFound }
        var body: [String: Any] = ["ids": itemIDs.map { $0.lowercased() }]
        let method: String, path: String
        switch write {
        case .moveToFolder(let folderID):
            body["folderId"] = folderID.map { $0 as Any } ?? NSNull()
            (method, path) = ("PUT", "api/ciphers/move")
        case .archive: (method, path) = ("PUT", "api/ciphers/archive")
        case .unarchive: (method, path) = ("PUT", "api/ciphers/unarchive")
        case .moveToTrash: (method, path) = ("PUT", "api/ciphers/delete")
        case .restore: (method, path) = ("PUT", "api/ciphers/restore")
        case .deletePermanently: (method, path) = ("DELETE", "api/ciphers")
        }
        let request = try HTTPClient.jsonRequest(method, server, path, body: JSONSerialization.data(withJSONObject: body),
                                                 accessToken: accessToken)
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func save(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        let urlRequest: URLRequest
        if let itemID {
            // The identifier becomes a part of the path.
            guard UUID(uuidString: itemID) != nil else { throw EngineError.notFound }
            urlRequest = try HTTPClient.jsonRequest("PUT", server, "api/ciphers/" + itemID.lowercased(), body: request,
                                                    accessToken: accessToken)
        } else {
            urlRequest = try HTTPClient.jsonRequest("POST", server, "api/ciphers", body: request, accessToken: accessToken)
        }
        let (data, status) = try await http.send(urlRequest)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else {
            let refusal = HTTPClient.refusal(data, status: status)
            // Vaultwarden: "The client copy of this cipher is out of date. Resync the client and try again."
            if case .server(let message) = refusal, message.localizedCaseInsensitiveContains("out of date") {
                throw EngineError.itemChanged
            }
            throw refusal
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = JSON.string(object, "Id"), UUID(uuidString: id) != nil else {
            throw EngineError.server("The server returned no identifier of the item.")
        }
        return id.lowercased()
    }

    public func share(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        let urlRequest: URLRequest
        if let itemID {
            guard UUID(uuidString: itemID) != nil else { throw EngineError.notFound }
            urlRequest = try HTTPClient.jsonRequest("PUT", server, "api/ciphers/" + itemID.lowercased() + "/share", body: request,
                                                    accessToken: accessToken)
        } else {
            urlRequest = try HTTPClient.jsonRequest("POST", server, "api/ciphers/create", body: request, accessToken: accessToken)
        }
        let (data, status) = try await http.send(urlRequest)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = JSON.string(object, "Id"), UUID(uuidString: id) != nil else {
            throw EngineError.server("The server returned no identifier of the item.")
        }
        return id.lowercased()
    }

    public func setCollections(_ collectionIDs: [String], itemID: String, server: URL, accessToken: String) async throws {
        guard UUID(uuidString: itemID) != nil, collectionIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw EngineError.notFound }
        let body = try JSONSerialization.data(withJSONObject: ["collectionIds": collectionIDs])
        let request = try HTTPClient.jsonRequest("PUT", server, "api/ciphers/" + itemID.lowercased() + "/collections_v2", body: body,
                                                 accessToken: accessToken)
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func saveFolder(id: String?, encryptedName: String, server: URL, accessToken: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["name": encryptedName])
        let request: URLRequest
        if let id {
            guard UUID(uuidString: id) != nil else { throw EngineError.notFound }
            request = try HTTPClient.jsonRequest("PUT", server, "api/folders/" + id.lowercased(), body: body, accessToken: accessToken)
        } else {
            request = try HTTPClient.jsonRequest("POST", server, "api/folders", body: body, accessToken: accessToken)
        }
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let folderID = JSON.string(object, "Id"), UUID(uuidString: folderID) != nil else {
            throw EngineError.server("The server returned no identifier of the folder.")
        }
        return folderID.lowercased()
    }

    public func deleteFolder(id: String, server: URL, accessToken: String) async throws {
        guard UUID(uuidString: id) != nil else { throw EngineError.notFound }
        let request = try HTTPClient.request("DELETE", server, "api/folders/" + id.lowercased(), accessToken: accessToken)
        let (data, status) = try await http.send(request)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    // MARK: Attachments

    /// An identifier becomes a part of a path, so only a plain one is taken.
    private static func isPlain(_ identifier: String) -> Bool {
        (1...128).contains(identifier.utf8.count)
            && identifier.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    private static func attachmentPath(_ itemID: String, _ attachmentID: String? = nil) throws -> String {
        guard UUID(uuidString: itemID) != nil, attachmentID.map(isPlain) ?? true else { throw EngineError.notFound }
        return "api/ciphers/" + itemID.lowercased() + "/attachment" + (attachmentID.map { "/" + $0 } ?? "/v2")
    }

    /// Two requests, as the Bitwarden clients send them: one opens a place for the file, the
    /// other brings the encrypted file. When the second fails, the place is removed again.
    @discardableResult
    public func addAttachment(_ attachment: EncryptedAttachment, itemID: String, server: URL, accessToken: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard !attachment.fileName.contains(where: { $0 == "\"" || $0.isNewline }) else {
            throw EngineError.unexpected("The encrypted file name cannot be sent.")
        }
        let slot = try JSONSerialization.data(withJSONObject: [
            "key": attachment.key, "fileName": attachment.fileName, "fileSize": attachment.contents.count,
        ] as [String: Any])
        let (data, status) = try await http.send(HTTPClient.jsonRequest("POST", server, Self.attachmentPath(itemID), body: slot,
                                                                        accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attachmentID = JSON.string(object, "AttachmentId"), Self.isPlain(attachmentID) else {
            throw EngineError.server("The server opened no place for the file.")
        }

        let boundary = "PassVault-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"data\"; filename=\"\(attachment.fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(attachment.contents)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = try HTTPClient.request("POST", server, Self.attachmentPath(itemID, attachmentID), accessToken: accessToken)
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.timeoutInterval = 300
        do {
            // `xhr.upload.onprogress` of the reference: the part of the body that has gone.
            let (answer, uploadStatus) = try await http.upload(upload, body: body) { sent, total in
                if total > 0 { progress(Double(sent) / Double(total)) }
            }
            guard (200..<300).contains(uploadStatus) else { throw HTTPClient.refusal(answer, status: uploadStatus) }
        } catch {
            // The place without its file would show as an attachment that cannot be opened.
            try? await deleteAttachment(itemID: itemID, attachmentID: attachmentID, server: server, accessToken: accessToken)
            throw error
        }
        return attachmentID
    }

    /// The server answers with a link to the file. The file is then fetched from this server at
    /// the path and the query of that link, whatever host the link names: a server behind a
    /// proxy may name another one, and PassVault sends requests to the account's server only.
    public func attachmentContents(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws -> Data {
        let (data, status) = try await http.send(HTTPClient.request("GET", server, Self.attachmentPath(itemID, attachmentID),
                                                                    accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        if status == 404 { throw EngineError.notFound }
        guard status == 200 else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let link = JSON.string(object, "Url"), let linked = URLComponents(string: link),
              linked.path.split(separator: "/").contains(Substring(attachmentID)),
              HTTPClient.isAcceptable(server), var address = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw EngineError.server("The server gave no usable address of the file.")
        }
        address.percentEncodedPath = linked.percentEncodedPath
        address.percentEncodedQuery = linked.percentEncodedQuery
        guard let url = address.url else { throw EngineError.server("The server gave no usable address of the file.") }
        // The link carries its own short-lived token; the access token is not sent with it.
        var request = URLRequest(url: url)
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (contents, fileStatus) = try await http.sendFile(request)
        guard fileStatus == 200, !contents.isEmpty, contents.count <= Engine.maximumAttachmentBytes + 65_536 else {
            throw EngineError.server("The file could not be fetched: HTTP \(fileStatus).")
        }
        return contents
    }

    public func deleteAttachment(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws {
        let (data, status) = try await http.send(HTTPClient.request("DELETE", server, Self.attachmentPath(itemID, attachmentID),
                                                                    accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    // MARK: Sends

    private static func sendPath(_ id: String?, _ rest: String = "") throws -> String {
        guard let id else { return "api/sends" + rest }
        // The identifier becomes a part of the path.
        guard UUID(uuidString: id) != nil else { throw EngineError.notFound }
        return "api/sends/" + id.lowercased() + rest
    }

    private static func sendID(in data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = JSON.string(object, "Id"), UUID(uuidString: id) != nil else {
            throw EngineError.server("The server returned no identifier of the Send.")
        }
        return id.lowercased()
    }

    public func saveSend(request: Data, sendID: String?, server: URL, accessToken: String) async throws -> String {
        let urlRequest = try HTTPClient.jsonRequest(sendID == nil ? "POST" : "PUT", server, Self.sendPath(sendID), body: request,
                                                    accessToken: accessToken)
        let (data, status) = try await http.send(urlRequest)
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        return try Self.sendID(in: data)
    }

    /// Two requests, as the Bitwarden clients send them: one makes the Send and opens a place
    /// for its file, the other brings the encrypted file. When the second fails, the Send is
    /// removed again.
    public func saveFileSend(request: Data, file: EncryptedSendFile, server: URL, accessToken: String) async throws -> String {
        guard !file.fileName.contains(where: { $0 == "\"" || $0.isNewline }) else {
            throw EngineError.unexpected("The encrypted file name cannot be sent.")
        }
        let (data, status) = try await http.send(HTTPClient.jsonRequest("POST", server, "api/sends/file/v2", body: request,
                                                                        accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let made = JSON.field(object, "SendResponse") as? [String: Any],
              let id = JSON.string(made, "Id"), UUID(uuidString: id) != nil,
              let fileID = (JSON.field(made, "File") as? [String: Any]).flatMap({ JSON.string($0, "Id") }), Self.isPlain(fileID) else {
            throw EngineError.server("The server opened no place for the file.")
        }
        let boundary = "PassVault-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"data\"; filename=\"\(file.fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(file.contents)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        do {
            var upload = try HTTPClient.request("POST", server, Self.sendPath(id, "/file/" + fileID), accessToken: accessToken)
            upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            upload.httpBody = body
            upload.timeoutInterval = 300
            let (answer, uploadStatus) = try await http.sendFile(upload)
            guard (200..<300).contains(uploadStatus) else { throw HTTPClient.refusal(answer, status: uploadStatus) }
        } catch {
            // The Send without its file would give a link that opens nothing.
            try? await deleteSend(id: id, server: server, accessToken: accessToken)
            throw error
        }
        return id.lowercased()
    }

    public func deleteSend(id: String, server: URL, accessToken: String) async throws {
        let (data, status) = try await http.send(HTTPClient.request("DELETE", server, Self.sendPath(id), accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func removeSendPassword(id: String, server: URL, accessToken: String) async throws {
        let (data, status) = try await http.send(HTTPClient.request("PUT", server, Self.sendPath(id, "/remove-password"),
                                                                    accessToken: accessToken))
        if status == 401 { throw EngineError.sessionExpired }
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    public func refresh(server: URL, refreshToken: String) async throws -> TokenRefresh {
        var request = try HTTPClient.request("POST", server, "identity/connect/token")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = JSON.formEncoded([
            ("grant_type", "refresh_token"), ("client_id", ClientIdentity.clientName), ("refresh_token", refreshToken),
        ])
        let (data, status) = try await http.send(request)
        // The server refuses a refresh token with 400 or 401: the session is over.
        if status == 400 || status == 401 { throw EngineError.sessionExpired }
        guard status == 200 else { throw HTTPClient.refusal(data, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let expiresIn = JSON.integer(object, "expires_in"), (1...31_536_000).contains(expiresIn) else {
            throw EngineError.server("The token answer is not readable.")
        }
        let newRefreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TokenRefresh(accessToken: accessToken, refreshToken: newRefreshToken, expiresIn: TimeInterval(expiresIn))
    }
}
