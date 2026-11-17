import Foundation

/// What the generator makes.
public enum GeneratorKind: String, Sendable, Codable, CaseIterable {
    case password, passphrase, username
}

/// The options of a generated password. The defaults and the limits are the ones of Bitwarden
/// (libs/tools/generator/core/src/metadata/password/random-password.ts).
public struct PasswordOptions: Sendable, Codable, Equatable {
    public var length = 14
    public var uppercase = true
    public var lowercase = true
    public var numbers = true
    public var special = false
    public var minNumbers = 1
    public var minSpecial = 0
    public var avoidAmbiguous = false

    public static let lengthRange = 5...128
    public static let recommendedLength = 14
    public static let minimumRange = 0...9

    public init() {}

    /// The options as a generator can take them: every number inside its limits, a least number
    /// only for a kind of character that is included, at least one kind included, and a length
    /// that has room for the least numbers.
    public var normalized: PasswordOptions {
        var options = self
        options.minNumbers = numbers ? min(max(minNumbers, Self.minimumRange.lowerBound), Self.minimumRange.upperBound) : 0
        options.minSpecial = special ? min(max(minSpecial, Self.minimumRange.lowerBound), Self.minimumRange.upperBound) : 0
        if !uppercase, !lowercase, !numbers, !special { options.lowercase = true }
        let needed = options.minNumbers + options.minSpecial + (options.uppercase ? 1 : 0) + (options.lowercase ? 1 : 0)
        options.length = min(max(length, Self.lengthRange.lowerBound, needed), Self.lengthRange.upperBound)
        return options
    }
}

/// The options of a generated passphrase (eff-word-list.ts of the same folder).
public struct PassphraseOptions: Sendable, Codable, Equatable {
    public var words = 6
    public var separator = "-"
    public var capitalize = false
    public var includeNumber = false

    public static let wordsRange = 3...20
    public static let recommendedWords = 6

    public init() {}

    /// The number of words inside its limits and a separator of one character at most.
    public var normalized: PassphraseOptions {
        var options = self
        options.words = min(max(words, Self.wordsRange.lowerBound), Self.wordsRange.upperBound)
        options.separator = String(separator.prefix(1))
        return options
    }
}

/// The options of a generated user name. A forwarded email alias is not here: it asks services
/// outside the account's server.
public struct UsernameOptions: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case randomWord, plusAddressedEmail, catchallEmail
    }

    public var kind = Kind.randomWord
    public var capitalize = false
    public var includeNumber = false
    /// The address a plus addressed email is made from.
    public var email = ""
    /// The domain of a catch-all address.
    public var domain = ""
    /// A catch-all address starts with the name of the website it is made for, when the
    /// generator knows one; else, and by default, with random characters.
    public var catchallUsesWebsiteName = false

    public init() {}

    /// Options that an older version saved lack what was added since; they have the default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .randomWord
        capitalize = try container.decodeIfPresent(Bool.self, forKey: .capitalize) ?? false
        includeNumber = try container.decodeIfPresent(Bool.self, forKey: .includeNumber) ?? false
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        catchallUsesWebsiteName = try container.decodeIfPresent(Bool.self, forKey: .catchallUsesWebsiteName) ?? false
    }

    /// The name of a website as the reference takes it for an address: the host of the address.
    public static func hostname(ofWebsite website: String?) -> String? {
        guard let text = website?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let host = URLComponents(string: text)?.host ?? URLComponents(string: "https://" + text)?.host
        return host?.isEmpty == false ? host : nil
    }
}

/// The generator options of an account, kept with its settings.
public struct GeneratorOptions: Sendable, Codable, Equatable {
    public var kind = GeneratorKind.password
    public var password = PasswordOptions()
    public var passphrase = PassphraseOptions()
    public var username = UsernameOptions()

    public init() {}
}

/// One request to the generator.
public enum GeneratorRequest: Sendable, Equatable {
    case password(PasswordOptions)
    case passphrase(PassphraseOptions)
    /// `website`: the website of the item the user name is made for, when there is one.
    case username(UsernameOptions, website: String? = nil)
}

/// A value the generator has made, as its history keeps it.
public struct GeneratedValue: Sendable, Codable, Equatable {
    public var value: String
    public var kind: GeneratorKind
    public var date: Date

    public init(value: String, kind: GeneratorKind, date: Date) {
        self.value = value
        self.kind = kind
        self.date = date
    }
}

/// An earlier password of a login, or an earlier value of a hidden field ("name: value").
public struct PasswordHistoryEntry: Sendable, Codable, Equatable {
    public var password: String
    public var lastUsed: Date

    public init(password: String, lastUsed: Date) {
        self.password = password
        self.lastUsed = lastUsed
    }
}
