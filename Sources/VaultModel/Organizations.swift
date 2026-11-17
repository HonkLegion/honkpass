import Foundation

/// An organization the account is a member of.
public struct VaultOrganization: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A collection of an organization: the place its items are shared in.
public struct VaultCollection: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let organizationID: String
    public let name: String
    /// The user can see the items of the collection and cannot put one in or take one out.
    public var isReadOnly: Bool

    public init(id: String, organizationID: String, name: String, isReadOnly: Bool = false) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.isReadOnly = isReadOnly
    }
}

/// Whose items a list shows: "all vaults", "my vault", or the vault of one organization.
public enum VaultOwner: Sendable, Hashable {
    case all
    case user
    case organization(String)
}

public extension VaultContents {
    /// The collections of an organization the user can put an item in, by name.
    func assignableCollections(of organizationID: String) -> [VaultCollection] {
        collections.filter { $0.organizationID == organizationID && !$0.isReadOnly }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The name of the organization of an item; nil for an item of the user.
    func organizationName(of item: VaultItemSummary) -> String? {
        item.organizationID.flatMap { id in organizations.first { $0.id == id }?.name }
    }
}
