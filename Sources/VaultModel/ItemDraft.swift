import Foundation

/// What the form of an item holds: everything of an item that the user can change.
///
/// The parts PassVault has no form for (passkeys, attachments, the password history) are not
/// here. The engine keeps them when it saves the draft of an existing item.
public struct ItemDraft: Sendable, Codable, Equatable {
    /// nil for an item that does not exist yet.
    public var id: String?
    /// The revision of the item the draft was made from. A save is refused when the item has
    /// changed since, so that the draft never overwrites a change it has not seen.
    public var revised: Date?
    public var name: String
    public var folderID: String?
    public var isFavorite: Bool
    public var asksForMasterPassword: Bool
    public var notes: String
    public var content: Content
    public var customFields: [CustomField]
    /// The organization of the item; nil for an item of the user. A new item is made in it; an
    /// item of the vault stays where it is, whatever its form says.
    public var organizationID: String?
    /// The collections a new item of an organization is put in.
    public var collectionIDs: [String]

    public enum Content: Sendable, Codable, Equatable {
        case login(Login)
        case card(CardContent)
        case identity(IdentityContent)
        case secureNote
        case sshKey(SSHKeyContent)
    }

    public struct Login: Sendable, Codable, Equatable {
        public var username: String
        public var password: String
        /// The key of the verification codes (the "authenticator key"), or its otpauth address.
        public var verificationKey: String
        public var websites: [Website]
        /// When the passkey of the login was made. The form shows it and can only remove it:
        /// nil saves the login without its passkey.
        public var passkeyCreated: Date?

        public init(username: String = "", password: String = "", verificationKey: String = "", websites: [Website] = [],
                    passkeyCreated: Date? = nil) {
            self.username = username
            self.password = password
            self.verificationKey = verificationKey
            self.websites = websites
            self.passkeyCreated = passkeyCreated
        }
    }

    public struct Website: Sendable, Codable, Hashable {
        public var address: String
        /// nil is the default of the account.
        public var match: WebsiteMatch?

        public init(address: String, match: WebsiteMatch? = nil) {
            self.address = address
            self.match = match
        }
    }

    public var type: ItemType {
        switch content {
        case .login: .login
        case .card: .card
        case .identity: .identity
        case .secureNote: .secureNote
        case .sshKey: .sshKey
        }
    }

    public init(id: String? = nil, revised: Date? = nil, name: String, folderID: String? = nil, isFavorite: Bool = false,
                asksForMasterPassword: Bool = false, notes: String = "", content: Content, customFields: [CustomField] = [],
                organizationID: String? = nil, collectionIDs: [String] = []) {
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
        self.id = id
        self.revised = revised
        self.name = name
        self.folderID = folderID
        self.isFavorite = isFavorite
        self.asksForMasterPassword = asksForMasterPassword
        self.notes = notes
        self.content = content
        self.customFields = customFields
    }

    /// The empty form of a new item.
    public init(new type: ItemType, folderID: String? = nil) {
        let content: Content = switch type {
        case .login: .login(Login())
        case .card: .card(CardContent())
        case .identity: .identity(IdentityContent())
        case .secureNote: .secureNote
        case .sshKey: .sshKey(SSHKeyContent(privateKey: "", publicKey: "", fingerprint: ""))
        }
        self.init(name: "", folderID: folderID, content: content)
    }

    /// The form of a copy of this item: a new item with the same content and another name.
    public func copy(named name: String) -> ItemDraft {
        var copy = self
        copy.id = nil
        copy.revised = nil
        copy.name = name
        return copy
    }
}

/// How the address of a page is compared with a website of a login. The numbers are Bitwarden's.
public enum WebsiteMatch: Int, Sendable, Codable, CaseIterable {
    case baseDomain = 0, host = 1, startsWith = 2, exact = 3, regularExpression = 4, never = 5
}

/// The fields of an item that a linked custom field can show. The numbers are Bitwarden's
/// (libs/common/src/vault/enums/linked-id-type.enum.ts).
public enum LinkedField {
    /// The key of Bitwarden's text for a field, as the views of the reference name it.
    public static func labelKey(_ id: Int) -> String? {
        labelKeys[id]
    }

    /// The fields an item of this type offers, in the order of the reference.
    public static func options(for type: ItemType) -> [Int] {
        switch type {
        case .login: [100, 101]
        case .card: [300, 305, 304, 301, 302, 303]
        case .identity: [400, 416, 401, 418, 417, 413, 409, 412, 414, 415, 410, 411, 402, 403, 404, 405, 406, 407, 408]
        case .secureNote, .sshKey: []
        }
    }

    private static let labelKeys: [Int: String] = [
        100: "username", 101: "password",
        300: "cardholderName", 301: "expirationMonth", 302: "expirationYear", 303: "securityCode", 304: "brand", 305: "number",
        400: "title", 401: "middleName", 402: "address1", 403: "address2", 404: "address3", 405: "cityTown",
        406: "stateProvince", 407: "zipPostalCodeLabel", 408: "country", 409: "company", 410: "email", 411: "phone",
        412: "ssn", 413: "username", 414: "passportNumber", 415: "licenseNumber", 416: "firstName", 417: "lastName",
        418: "fullName",
    ]
}
