import Foundation
import Testing
import VaultModel

/// The address that ties a login to an app of macOS: "osxapp://" with the bundle identifier
/// of the app and its developer.
@Suite struct AppAddressTests {
    private let mail = "osxapp://com.example.Mail:ABCDE12345"

    @Test func anAddressNamesTheBundleAndTheDeveloperOfAnApp() throws {
        let app = try #require(AppAddress(mail))
        #expect(app.bundleID == "com.example.Mail" && app.developer == "ABCDE12345" && !app.isOfApple)
        #expect(app.address == mail)
        #expect(AppAddress(bundleID: "com.example.Mail", developer: "ABCDE12345") == app)
        // What Apple signed itself has no team.
        let ofApple = try #require(AppAddress("  osxapp://com.apple.TextEdit:apple\n"))
        #expect(ofApple.isOfApple && ofApple.address == "osxapp://com.apple.TextEdit:apple")
        // The letters of an identifier count as they are written.
        #expect(AppAddress("osxapp://com.example.mail:ABCDE12345") != app)
        #expect(AppAddress(bundleID: "org.example.some-tool_2", developer: "0123456789") != nil)
    }

    @Test func whatIsNoAddressOfAnAppIsAWebsite() {
        for other in ["https://example.com", "example.com", "iosapp://com.example.Mail", "androidapp://com.example.mail",
                      "desktopapp://Mail", "osxapp://", "osxapp://com.example.Mail", "osxapp://com.example.Mail:",
                      "osxapp://:ABCDE12345", "OSXAPP://com.example.Mail:ABCDE12345", ""] {
            #expect(AppAddress(other) == nil, "\(other)")
        }
        // A developer is a team of ten capital letters and digits, or Apple.
        for developer in ["abcde12345", "ABCDE1234", "ABCDE123456", "Apple", "ABCDE-2345", ""] {
            #expect(AppAddress(bundleID: "com.example.Mail", developer: developer) == nil, "\(developer)")
        }
        // An identifier has two parts at least, of letters, digits, "-" and "_". Nothing that
        // could change the meaning of a requirement on a code signature is taken.
        for bundle in ["Mail", "com..Mail", ".com.example", "com.example.", "com.example.Ma il", "com.example.Mail/x",
                       "com.example.Mail\" or anchor apple or identifier \"x.y", "com.exämple.Mail", "com.example:Mail"] {
            #expect(AppAddress(bundleID: bundle, developer: "ABCDE12345") == nil, "\(bundle)")
        }
    }

    @Test func anAddressOfAnAppIsThePageOfNoBrowser() throws {
        let app = try #require(AppAddress(mail))
        // The row a login gets for an app is matched "never", for the other clients of Bitwarden.
        #expect(ItemDraft.Website(app: app) == ItemDraft.Website(address: mail, match: .never))
        #expect(ItemDraft.Website(app: app).app == app)
        #expect(ItemDraft.Website(address: "https://example.com").app == nil)
        // Whatever its match says, it is no website here.
        for match in [nil, WebsiteMatch.baseDomain, .host, .startsWith, .exact, .regularExpression, .never] {
            let site = ItemDraft.Website(address: mail, match: match)
            #expect(!site.matches(page: mail), "\(String(describing: match))")
            #expect(!site.matches(page: "https://example.mail/"))
            #expect(!site.matches(page: mail + "/more"))
        }
    }

    @Test func theAddressesOfALoginAreItsWebsitesAndItsApps() throws {
        let app = try #require(AppAddress(mail)), other = try #require(AppAddress("osxapp://com.apple.mail:apple"))
        let login = LoginContent(websites: ["https://example.com", mail, "example.org", other.address, mail])
        #expect(login.pages == ["https://example.com", "example.org"])
        // Each app once, in the order of the login.
        #expect(login.apps == [app, other])
        // "Copy website" copies a website, never the address of an app.
        let appOnly = VaultItem(id: "1", name: "Example", content: .login(LoginContent(websites: [mail])), created: Date(),
                                revised: Date())
        #expect(appOnly.value(of: .website) == nil)
        let both = VaultItem(id: "2", name: "Example", content: .login(LoginContent(websites: [mail, "https://example.com"])),
                             created: Date(), revised: Date())
        #expect(both.value(of: .website) == "https://example.com")
    }

    @Test func theLoginsOfAnAppAreTheOnesThatHaveItsAddress() throws {
        let app = try #require(AppAddress(mail))
        let otherDeveloper = try #require(AppAddress("osxapp://com.example.Mail:ZZZZZ99999"))
        func login(_ id: String, _ name: String, _ addresses: [String], isInTrash: Bool = false, isArchived: Bool = false,
                   isFavorite: Bool = false) -> VaultItemSummary {
            VaultItemSummary(id: id, type: .login, name: name, subtitle: "user", isFavorite: isFavorite, isInTrash: isInTrash,
                             isArchived: isArchived, fields: [.username, .password],
                             websites: addresses.map { address in
                                 AppAddress(address).map { ItemDraft.Website(app: $0) } ?? ItemDraft.Website(address: address)
                             })
        }
        let vault = VaultContents(items: [
            login("1", "Example Mail", ["https://mail.example.com", mail]),
            login("2", "Example Work Mail", [mail]),
            login("3", "Example Web Only", ["https://mail.example.com"]),
            login("4", "Example Other Developer", [otherDeveloper.address]),
            login("5", "Example Deleted", [mail], isInTrash: true),
            login("6", "Example Archived", [mail], isArchived: true),
            VaultItemSummary(id: "7", type: .login, name: "", isUndecryptable: true, websites: [ItemDraft.Website(app: app)]),
        ], folders: [])

        // The same identifier signed by another developer is another app.
        #expect(vault.logins(ofApp: app).map(\.id) == ["1", "2"])
        #expect(vault.logins(ofApp: otherDeveloper).map(\.id) == ["4"])
        // Where the user is: the logins of the page first, then the ones of the app, each once.
        #expect(vault.logins(ofPage: "https://mail.example.com/inbox", app: app).map(\.id) == ["1", "3", "2"])
        #expect(vault.logins(ofPage: nil, app: app).map(\.id) == ["1", "2"])
        #expect(vault.logins(ofPage: "https://mail.example.com/inbox", app: nil).map(\.id) == ["1", "3"])
        #expect(vault.logins(ofPage: nil, app: nil).isEmpty)

        // Quick access suggests them, as it suggests the logins of a page.
        let lists = vault.quickAccessSections(search: "", app: app)
        #expect(lists.map(\.kind) == [.suggestions, .allItems])
        #expect(lists[0].items.map(\.id) == ["1", "2"])
        #expect(vault.quickAccessSections(search: "").map(\.kind) == [.allItems])

        // The AutoFill of the system gets websites only: a login of apps alone is not offered there.
        #expect(vault.passwordIdentities.map(\.itemID) == ["1", "3"])
        #expect(vault.passwordIdentities.allSatisfy { $0.website == "https://mail.example.com" })
        // Not even when another client saved the address of the app with another match.
        let unmarked = VaultContents(items: [
            VaultItemSummary(id: "8", type: .login, name: "Example", subtitle: "user", fields: [.username, .password],
                             websites: [ItemDraft.Website(address: mail)]),
        ], folders: [])
        #expect(unmarked.passwordIdentities.isEmpty)
        #expect(unmarked.logins(ofApp: app).map(\.id) == ["8"])
    }
}
