import Foundation

/// An app of macOS that a login belongs to, as it stands among the websites of the login:
/// "osxapp://com.example.Mail:ABCDE12345". The first part is the identifier of the bundle of
/// the app and the second who signed it: the team identifier of its developer, or "apple" for
/// an app that Apple signed itself. An app is known by both, as its code signature has them;
/// a name can be taken by any app.
public struct AppAddress: Sendable, Codable, Hashable {
    /// How the address of an app begins. Bitwarden has "iosapp://" and "androidapp://" so.
    public static let prefix = "osxapp://"
    /// The developer of the apps that Apple signs itself; they have no team identifier.
    public static let apple = "apple"

    public let bundleID: String
    public let developer: String

    /// nil for a bundle identifier or a developer that an app cannot have. Both stand in a
    /// requirement on a code signature as they are, so nothing else is taken.
    public init?(bundleID: String, developer: String) {
        guard Self.isBundleID(bundleID), developer == Self.apple || Self.isTeamID(developer) else { return nil }
        self.bundleID = bundleID
        self.developer = developer
    }

    /// The app of an address of a login. nil for any other address: a website.
    public init?(_ address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Self.prefix) else { return nil }
        let rest = text.dropFirst(Self.prefix.count)
        // A bundle identifier has no colon: the last one is before the developer.
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        self.init(bundleID: String(rest[..<colon]), developer: String(rest[rest.index(after: colon)...]))
    }

    /// The address as it is kept among the websites of a login.
    public var address: String {
        Self.prefix + bundleID + ":" + developer
    }

    /// Apple signed the app itself.
    public var isOfApple: Bool { developer == Self.apple }

    /// Parts of letters, digits, "-" and "_" with dots between them, two parts at least.
    private static func isBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { isLetterOrDigit($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
        }
    }

    /// Ten capital letters and digits.
    private static func isTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
}

public extension ItemDraft.Website {
    /// The app this address names. nil for a website.
    var app: AppAddress? { AppAddress(address) }

    /// The row of a login for an app. It is saved with the match "never": another client of
    /// Bitwarden takes the address for one of the web, and so offers the login on no page.
    init(app: AppAddress) {
        self.init(address: app.address, match: .never)
    }
}

public extension LoginContent {
    /// The addresses of the login that are websites, in their order.
    var pages: [String] { websites.filter { AppAddress($0) == nil } }

    /// The apps of the login, in their order and each once.
    var apps: [AppAddress] {
        var seen: Set<AppAddress> = []
        return websites.compactMap(AppAddress.init).filter { seen.insert($0).inserted }
    }
}

public extension VaultContents {
    /// The logins of an app, in name order: the ones that have its address. Not the items of
    /// the trash and the archive.
    func logins(ofApp app: AppAddress) -> [VaultItemSummary] {
        items(in: .type(.login)).filter { item in
            !item.isUndecryptable && item.websites.contains { $0.app == app }
        }
    }

    /// The logins that belong where the user is: the ones of the web page in front, then the
    /// ones of the app in front that are not among them.
    func logins(ofPage page: String?, app: AppAddress?) -> [VaultItemSummary] {
        let ofPage = page.map(logins(ofPage:)) ?? []
        let ofApp = app.map(logins(ofApp:)) ?? []
        return ofPage + ofApp.filter { item in !ofPage.contains { $0.id == item.id } }
    }
}
