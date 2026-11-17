import Foundation

/// The account PassVault is logged in to on one Vaultwarden server.
public struct Account: Sendable, Codable, Hashable, Identifiable {
    /// The user identifier the server assigned.
    public let id: String
    public let email: String
    public let serverURL: URL

    public init(id: String, email: String, serverURL: URL) {
        self.id = id
        self.email = email
        self.serverURL = serverURL
    }
}
