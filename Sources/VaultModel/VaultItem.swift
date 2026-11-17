import Foundation

/// One item with all its fields, decrypted. A client asks the engine for it when it shows the item
/// and keeps it no longer than that.
public struct VaultItem: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var notes: String?
    public var isFavorite: Bool
    public var folderID: String?
    public var isInTrash: Bool
    public var isArchived: Bool
    /// The item asks for the master password again before it shows or copies protected fields.
    public var asksForMasterPassword: Bool
    public var content: ItemContent
    public var customFields: [CustomField]
    public var created: Date
    public var revised: Date
    public var passwordRevised: Date?
    public var passwordHistoryCount: Int
    /// The files of the item. Their content stays on the server until one is asked for.
    public var attachments: [ItemAttachment]

    public var type: ItemType { content.type }

    public init(id: String, name: String, notes: String? = nil, isFavorite: Bool = false, folderID: String? = nil,
                isInTrash: Bool = false, isArchived: Bool = false, asksForMasterPassword: Bool = false, content: ItemContent,
                customFields: [CustomField] = [], created: Date, revised: Date, passwordRevised: Date? = nil,
                passwordHistoryCount: Int = 0, attachments: [ItemAttachment] = []) {
        self.id = id
        self.name = name
        self.notes = notes
        self.isFavorite = isFavorite
        self.folderID = folderID
        self.isInTrash = isInTrash
        self.isArchived = isArchived
        self.asksForMasterPassword = asksForMasterPassword
        self.content = content
        self.customFields = customFields
        self.created = created
        self.revised = revised
        self.passwordRevised = passwordRevised
        self.passwordHistoryCount = passwordHistoryCount
        self.attachments = attachments
    }
}

/// One file of an item, as a list shows it.
public struct ItemAttachment: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var fileName: String
    /// The size as the server words it: "1.5 KB".
    public var sizeName: String
    /// false for a file of the old kind, which is encrypted with the key of its item. The
    /// reference offers "fix encryption" for it in place of the download.
    public var hasOwnKey: Bool

    public init(id: String, fileName: String, sizeName: String, hasOwnKey: Bool = true) {
        self.id = id
        self.fileName = fileName
        self.sizeName = sizeName
        self.hasOwnKey = hasOwnKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        sizeName = try container.decode(String.self, forKey: .sizeName)
        hasOwnKey = try container.decodeIfPresent(Bool.self, forKey: .hasOwnKey) ?? true
    }
}

/// A file of an item with its content, decrypted. A client asks the engine for it to save it.
public struct AttachmentFile: Sendable, Equatable {
    public var fileName: String
    public var data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public enum ItemContent: Sendable, Codable, Equatable {
    case login(LoginContent)
    case card(CardContent)
    case identity(IdentityContent)
    case secureNote
    case sshKey(SSHKeyContent)

    public var type: ItemType {
        switch self {
        case .login: .login
        case .card: .card
        case .identity: .identity
        case .secureNote: .secureNote
        case .sshKey: .sshKey
        }
    }
}

public struct LoginContent: Sendable, Codable, Equatable {
    public var username: String?
    public var password: String?
    /// The secret of the verification codes stays in the engine; ask it for the current code.
    public var hasVerificationCode: Bool
    public var websites: [String]
    /// When the passkey of the login was made. nil for a login without a passkey.
    public var passkeyCreated: Date?

    public init(username: String? = nil, password: String? = nil, hasVerificationCode: Bool = false, websites: [String] = [],
                passkeyCreated: Date? = nil) {
        self.username = username
        self.password = password
        self.hasVerificationCode = hasVerificationCode
        self.websites = websites
        self.passkeyCreated = passkeyCreated
    }
}

public struct CardContent: Sendable, Codable, Equatable {
    public var cardholderName: String?
    public var brand: String?
    public var number: String?
    public var expirationMonth: String?
    public var expirationYear: String?
    public var securityCode: String?

    public init(cardholderName: String? = nil, brand: String? = nil, number: String? = nil,
                expirationMonth: String? = nil, expirationYear: String? = nil, securityCode: String? = nil) {
        self.cardholderName = cardholderName
        self.brand = brand
        self.number = number
        self.expirationMonth = expirationMonth
        self.expirationYear = expirationYear
        self.securityCode = securityCode
    }
}

public struct IdentityContent: Sendable, Codable, Equatable {
    public var title: String?
    public var firstName: String?
    public var middleName: String?
    public var lastName: String?
    public var username: String?
    public var company: String?
    public var socialSecurityNumber: String?
    public var passportNumber: String?
    public var licenseNumber: String?
    public var email: String?
    public var phone: String?
    public var address1: String?
    public var address2: String?
    public var address3: String?
    public var city: String?
    public var state: String?
    public var postalCode: String?
    public var country: String?

    public init() {}
}

public struct SSHKeyContent: Sendable, Codable, Equatable {
    public var privateKey: String
    public var publicKey: String
    public var fingerprint: String

    public init(privateKey: String, publicKey: String, fingerprint: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.fingerprint = fingerprint
    }
}

public struct CustomField: Sendable, Codable, Equatable {
    public enum Value: Sendable, Codable, Equatable {
        case text(String)
        case hidden(String)
        case boolean(Bool)
        /// A field that shows another field of the item: Bitwarden's number of that field (`LinkedField`).
        case linked(Int)
    }

    public var name: String
    public var value: Value

    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }
}

/// A time-based one-time code and how many seconds one code lives.
public struct VerificationCode: Sendable, Codable, Equatable {
    public var code: String
    public var period: Int

    public init(code: String, period: Int) {
        self.code = code
        self.period = period
    }
}

public extension VaultItem {
    /// The text of one field, as a copy action takes it. nil when the item has no such field.
    /// The verification code is not here: the engine computes it.
    func value(of field: ItemField) -> String? {
        let value: String? = switch (field, content) {
        case (.username, .login(let login)): login.username
        case (.password, .login(let login)): login.password
        case (.website, .login(let login)): login.pages.first
        case (.cardNumber, .card(let card)): card.number
        case (.cardSecurityCode, .card(let card)): card.securityCode
        case (.identityUsername, .identity(let identity)): identity.username
        case (.identityEmail, .identity(let identity)): identity.email
        case (.identityPhone, .identity(let identity)): identity.phone
        case (.identityAddress, .identity(let identity)): identity.fullAddress
        case (.sshKey, .sshKey(let key)): key.privateKey
        case (.sshPublicKey, .sshKey(let key)): key.publicKey
        case (.sshFingerprint, .sshKey(let key)): key.fingerprint
        case (.notes, _): notes
        default: nil
        }
        return value?.isEmpty == false ? value : nil
    }
}

public extension IdentityContent {
    /// The address as the item view shows it: the street lines, then "city, state, postal code",
    /// then the country, each on its own line. A missing city or postal code is a dash when
    /// another part of that line is there.
    var fullAddress: String? {
        func filled(_ text: String?) -> String? {
            text?.trimmingCharacters(in: .whitespaces).isEmpty == false ? text : nil
        }
        var cityLine: String?
        if filled(city) != nil || filled(state) != nil || filled(postalCode) != nil {
            cityLine = [filled(city) ?? "-", filled(state), filled(postalCode) ?? "-"].compactMap { $0 }.joined(separator: ", ")
        }
        let lines = [filled(address1), filled(address2), filled(address3), cityLine, filled(country)].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "Title First Middle Last"
    var fullName: String? {
        let parts = [title, firstName, middleName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
