import Foundation

/// The item types of a Bitwarden vault that PassVault shows.
public enum ItemType: String, Sendable, Codable, CaseIterable {
    case login, secureNote, card, identity, sshKey
}

/// A part of an item that a list row can copy or open. The value itself is not in the list.
public enum ItemField: String, Sendable, Codable, CaseIterable {
    case username, password, verificationCode, website
    case cardNumber, cardSecurityCode
    case identityUsername, identityEmail, identityPhone, identityAddress
    /// The private key of an SSH key. A list knows only that an item has a key; the public key
    /// and the fingerprint come with it.
    case sshKey
    case sshPublicKey, sshFingerprint
    case notes
}

public extension ItemField {
    /// A user name and a website are not secrets (`protected: false` in copy-cipher-field.service.ts
    /// of the reference): they are copied without the master password an item may ask for.
    var isPublic: Bool {
        self == .username || self == .identityUsername || self == .website
    }
}

/// What an item list shows about one item. It holds no password, code or key.
public struct VaultItemSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let type: ItemType
    public let name: String
    /// The second line of a list row, for example the user name of a login.
    public let subtitle: String
    public var isFavorite: Bool
    public var folderID: String?
    public var isInTrash: Bool
    /// An archived item shows in the archive only, or in the trash once it is deleted.
    public var isArchived: Bool
    /// The fields this item has. A row offers its quick actions from them.
    public let fields: Set<ItemField>
    /// The brand of a card, for its picture: "Visa", "Mastercard", ...
    public let cardBrand: String?
    /// The host of a login's first website, for its picture: "mail.example.com".
    public let websiteHost: String?
    /// The item asks for the master password again before it opens or gives out protected fields.
    public let asksForMasterPassword: Bool
    /// How many files the item has. A row shows a paper clip for them.
    public var attachmentCount: Int
    /// The item could not be decrypted, so it has no name and cannot be opened. A list shows it
    /// all the same, so that the user learns of it and can delete it.
    public var isUndecryptable: Bool
    /// The websites of a login with the way each is matched to a page. Quick access and
    /// AutoFill find the logins of a page with them.
    public var websites: [ItemDraft.Website]
    /// The passkeys of a login: where each is used and whose it is. No key.
    public var passkeys: [VaultPasskey]
    /// The organization the item belongs to; nil for an item of the user.
    public var organizationID: String?
    /// The collections of the organization the item is in.
    public var collectionIDs: [String]
    /// The user may see the item and may not change it.
    public var isReadOnly: Bool
    /// The user may delete the item and restore it. An item of the user is always theirs to delete.
    public var canDelete: Bool

    public init(id: String, type: ItemType, name: String, subtitle: String = "", isFavorite: Bool = false,
                folderID: String? = nil, isInTrash: Bool = false, isArchived: Bool = false, fields: Set<ItemField> = [],
                cardBrand: String? = nil, websiteHost: String? = nil, asksForMasterPassword: Bool = false,
                attachmentCount: Int = 0, isUndecryptable: Bool = false, websites: [ItemDraft.Website] = [],
                passkeys: [VaultPasskey] = [], organizationID: String? = nil, collectionIDs: [String] = [],
                isReadOnly: Bool = false, canDelete: Bool = true) {
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
        self.isReadOnly = isReadOnly
        self.canDelete = canDelete
        self.passkeys = passkeys
        self.id = id
        self.type = type
        self.name = name
        self.subtitle = subtitle
        self.isFavorite = isFavorite
        self.folderID = folderID
        self.isInTrash = isInTrash
        self.isArchived = isArchived
        self.fields = fields
        self.cardBrand = cardBrand
        self.websiteHost = websiteHost
        self.asksForMasterPassword = asksForMasterPassword
        self.attachmentCount = attachmentCount
        self.isUndecryptable = isUndecryptable
        self.websites = websites
    }

    /// The host that Bitwarden asks a picture for: the address must be http(s), or a bare name with a
    /// dot, and no .onion or .i2p name.
    public static func websiteHost(of address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespaces)
        let candidate: String
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            candidate = text
        } else if !text.contains("://"), text.contains(".") {
            candidate = "https://" + text
        } else {
            return nil
        }
        guard let host = URLComponents(string: candidate)?.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".onion"), !host.hasSuffix(".i2p"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }
}

public struct VaultFolder: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The decrypted list data of an unlocked vault.
public struct VaultContents: Sendable, Codable, Equatable {
    public var items: [VaultItemSummary]
    public var folders: [VaultFolder]
    /// Items the server sent that no list can show: of a type PassVault does not know, or
    /// without an identifier. An item that only failed to decrypt is in `items`, marked as such.
    public var omittedItemCount: Int
    public var lastSync: Date?
    /// The groups of domains that the account counts as one: a login of one of them is a login
    /// of a page of any other. Bitwarden's own groups and the ones the user made.
    public var equivalentDomains: [[String]]
    /// The Sends of the account, without what they carry.
    public var sends: [VaultSendSummary]
    /// The organizations of the account and their collections.
    public var organizations: [VaultOrganization]
    public var collections: [VaultCollection]

    public static let empty = VaultContents(items: [], folders: [])

    public init(items: [VaultItemSummary], folders: [VaultFolder], omittedItemCount: Int = 0, lastSync: Date? = nil,
                equivalentDomains: [[String]] = [], sends: [VaultSendSummary] = [], organizations: [VaultOrganization] = [],
                collections: [VaultCollection] = []) {
        self.organizations = organizations
        self.collections = collections
        self.sends = sends
        self.items = items
        self.folders = folders
        self.omittedItemCount = omittedItemCount
        self.lastSync = lastSync
        self.equivalentDomains = equivalentDomains
    }
}
