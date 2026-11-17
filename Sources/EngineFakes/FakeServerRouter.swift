import Engine
import Foundation
import VaultModel

/// Several fake servers behind one port, each at its address: for tests with more than one
/// account. A request to an address without a server finds nobody.
public struct FakeServerRouter: ServerPort {
    private let servers: [URL: FakeServer]

    public init(_ servers: [URL: FakeServer]) {
        self.servers = servers
    }

    private func at(_ server: URL) throws -> FakeServer {
        guard let found = servers[server] else { throw EngineError.serverUnreachable }
        return found
    }

    public func prelogin(server: URL, email: String) async throws -> Prelogin {
        try await at(server).prelogin(server: server, email: email)
    }

    public func logIn(_ request: LoginRequest) async throws -> LoginOutcome {
        try await at(request.server).logIn(request)
    }

    public func sendTwoStepEmail(_ request: LoginRequest) async throws {
        try await at(request.server).sendTwoStepEmail(request)
    }

    public func requestPasswordHint(server: URL, email: String) async throws {
        try await at(server).requestPasswordHint(server: server, email: email)
    }

    public func isKnownDevice(server: URL, email: String, deviceIdentifier: String) async throws -> Bool {
        try await at(server).isKnownDevice(server: server, email: email, deviceIdentifier: deviceIdentifier)
    }

    public func sync(server: URL, accessToken: String) async throws -> Data {
        try await at(server).sync(server: server, accessToken: accessToken)
    }

    public func refresh(server: URL, refreshToken: String) async throws -> TokenRefresh {
        try await at(server).refresh(server: server, refreshToken: refreshToken)
    }

    public func websiteIcon(server: URL, host: String) async throws -> Data {
        try await at(server).websiteIcon(server: server, host: host)
    }

    public func write(_ write: ItemWrite, itemID: String, server: URL, accessToken: String) async throws {
        try await at(server).write(write, itemID: itemID, server: server, accessToken: accessToken)
    }

    public func write(_ write: ItemBulkWrite, itemIDs: [String], server: URL, accessToken: String) async throws {
        try await at(server).write(write, itemIDs: itemIDs, server: server, accessToken: accessToken)
    }

    public func save(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        try await at(server).save(request: request, itemID: itemID, server: server, accessToken: accessToken)
    }

    public func share(request: Data, itemID: String?, server: URL, accessToken: String) async throws -> String {
        try await at(server).share(request: request, itemID: itemID, server: server, accessToken: accessToken)
    }

    public func setCollections(_ collectionIDs: [String], itemID: String, server: URL, accessToken: String) async throws {
        try await at(server).setCollections(collectionIDs, itemID: itemID, server: server, accessToken: accessToken)
    }

    public func saveFolder(id: String?, encryptedName: String, server: URL, accessToken: String) async throws -> String {
        try await at(server).saveFolder(id: id, encryptedName: encryptedName, server: server, accessToken: accessToken)
    }

    public func importVault(request: Data, server: URL, accessToken: String) async throws {
        try await at(server).importVault(request: request, server: server, accessToken: accessToken)
    }

    public func deleteFolder(id: String, server: URL, accessToken: String) async throws {
        try await at(server).deleteFolder(id: id, server: server, accessToken: accessToken)
    }

    public func addAttachment(_ attachment: EncryptedAttachment, itemID: String, server: URL, accessToken: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await at(server).addAttachment(attachment, itemID: itemID, server: server, accessToken: accessToken,
                                           progress: progress)
    }

    public func attachmentContents(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws -> Data {
        try await at(server).attachmentContents(itemID: itemID, attachmentID: attachmentID, server: server, accessToken: accessToken)
    }

    public func deleteAttachment(itemID: String, attachmentID: String, server: URL, accessToken: String) async throws {
        try await at(server).deleteAttachment(itemID: itemID, attachmentID: attachmentID, server: server, accessToken: accessToken)
    }

    public func saveSend(request: Data, sendID: String?, server: URL, accessToken: String) async throws -> String {
        try await at(server).saveSend(request: request, sendID: sendID, server: server, accessToken: accessToken)
    }

    public func saveFileSend(request: Data, file: EncryptedSendFile, server: URL, accessToken: String) async throws -> String {
        try await at(server).saveFileSend(request: request, file: file, server: server, accessToken: accessToken)
    }

    public func deleteSend(id: String, server: URL, accessToken: String) async throws {
        try await at(server).deleteSend(id: id, server: server, accessToken: accessToken)
    }

    public func removeSendPassword(id: String, server: URL, accessToken: String) async throws {
        try await at(server).removeSendPassword(id: id, server: server, accessToken: accessToken)
    }
}
