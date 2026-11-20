import Testing
import VaultModel

/// The rules that say whether a website of a login is a web page: the ones of Bitwarden.
@Suite struct WebsiteMatchingTests {
    private func site(_ address: String, _ match: WebsiteMatch? = nil) -> ItemDraft.Website {
        ItemDraft.Website(address: address, match: match)
    }

    @Test func secureWebsitesRequireASecurePageWhenTheSchemeIsKnown() {
        for match in [WebsiteMatch.baseDomain, .host] {
            let saved = site("  https://login.example.com  ", match)
            #expect(!saved.matches(page: "http://login.example.com"))
            #expect(saved.matches(page: "https://login.example.com"))
            #expect(saved.matches(page: "login.example.com"))
            #expect(site("http://login.example.com", match).matches(page: "http://login.example.com"))
        }
    }

    @Test func theBaseDomainIsWhatOneOwnerRegistered() {
        #expect(WebAddress.domain(of: "https://www.example.com/login?next=1") == "example.com")
        #expect(WebAddress.domain(of: "shop.example.co.uk") == "example.co.uk")
        // The private part of the list: every user of such a host has a domain of their own.
        #expect(WebAddress.domain(of: "https://alice.github.io/site") == "alice.github.io")
        // "*.ck" makes "b.ck" a public suffix, and "!www.ck" takes "www.ck" out of it.
        #expect(WebAddress.domain(of: "https://a.b.ck") == "a.b.ck")
        #expect(WebAddress.domain(of: "https://b.ck") == nil)
        #expect(WebAddress.domain(of: "https://www.ck") == "www.ck")
        // An ending the list does not know counts as one label.
        #expect(WebAddress.domain(of: "https://intranet.corp.example-unknown-tld") == "corp.example-unknown-tld")
        // A public suffix alone, and what is no web address.
        #expect(WebAddress.domain(of: "https://co.uk") == nil)
        #expect(WebAddress.domain(of: "data:text/plain,hello") == nil)
        #expect(WebAddress.domain(of: "about:blank") == nil)
        #expect(WebAddress.domain(of: "  ") == nil)
        // The local host and an address of numbers are their own domain.
        #expect(WebAddress.domain(of: "http://localhost:8642/alive") == "localhost")
        #expect(WebAddress.domain(of: "https://192.168.1.10:8443/admin") == "192.168.1.10")
        // An international name is the same in both of its spellings.
        #expect(WebAddress.domain(of: "https://www.xn--0zwm56d.com") == WebAddress.domain(of: "https://测试.com"))
        #expect(WebAddress.domain(of: "https://EXAMPLE.com.") == "example.com")
    }

    @Test func aWebsiteMatchesAPageOfItsBaseDomainUnlessItSaysOtherwise() {
        #expect(site("https://www.example.com/login").matches(page: "https://shop.example.com/cart"))
        #expect(site("example.com").matches(page: "https://example.com/"))
        #expect(!site("https://example.co.uk").matches(page: "https://evil.co.uk/"))
        #expect(!site("https://alice.github.io").matches(page: "https://bob.github.io/"))
        #expect(site("http://localhost:8642").matches(page: "http://localhost:3000/login"))
        #expect(site("https://xn--0zwm56d.com").matches(page: "https://测试.com/"))
        #expect(!site("https://example.com").matches(page: "https://example.org/"))
        #expect(!site("").matches(page: "https://example.com/"))
        #expect(!site("https://example.com").matches(page: ""))
        // The domains the account counts as one.
        #expect(!site("https://youtube.com").matches(page: "https://accounts.google.com/"))
        #expect(site("https://youtube.com").matches(page: "https://accounts.google.com/", equivalentDomains: ["youtube.com", "google.com"]))
        // A host that others write pages for is not a page of its domain.
        #expect(site("https://google.com").matches(page: "https://mail.google.com/"))
        #expect(!site("https://google.com").matches(page: "https://script.google.com/macros"))
    }

    @Test func theLoginsOfAPageAreTheOnesWithAWebsiteThatMatchesIt() {
        let contents = VaultContents(items: [
            VaultItemSummary(id: "1", type: .login, name: "Shop", websites: [.init(address: "https://shop.example.com/login")]),
            VaultItemSummary(id: "2", type: .login, name: "Admin", websites: [.init(address: "https://admin.example.com", match: .host)]),
            VaultItemSummary(id: "3", type: .login, name: "Video", isFavorite: true, websites: [.init(address: "https://youtube.com")]),
            VaultItemSummary(id: "4", type: .login, name: "Old shop", isInTrash: true, websites: [.init(address: "https://example.com")]),
            VaultItemSummary(id: "5", type: .login, name: "Never", websites: [.init(address: "https://example.com", match: .never)]),
            VaultItemSummary(id: "6", type: .card, name: "Card"),
            VaultItemSummary(id: "7", type: .login, name: "No website"),
        ], folders: [], equivalentDomains: [["youtube.com", "google.com"], ["example.net", "example.org"]])

        #expect(contents.logins(ofPage: "https://www.example.com/").map(\.name) == ["Shop"])
        #expect(contents.logins(ofPage: "https://admin.example.com/users").map(\.name) == ["Admin", "Shop"])
        #expect(contents.logins(ofPage: "https://accounts.google.com/signin").map(\.name) == ["Video"])
        #expect(contents.logins(ofPage: "https://example.org/").isEmpty)
        #expect(contents.equivalentDomains(ofPage: "https://www.google.com/") == ["youtube.com", "google.com"])
        #expect(contents.equivalentDomains(ofPage: "https://example.com/").isEmpty)

        // Quick access puts them first, and only without a search.
        let lists = contents.quickAccessSections(search: "", page: "https://www.example.com/")
        #expect(lists.map(\.kind) == [.suggestions, .favorites, .allItems])
        #expect(lists[0].rows.map(\.id) == ["suggestions/1"])
        #expect(contents.quickAccessSections(search: "", page: "https://example.org/").map(\.kind) == [.favorites, .allItems])
        #expect(contents.quickAccessSections(search: "", page: nil).map(\.kind) == [.favorites, .allItems])
        #expect(contents.quickAccessSections(search: "shop", page: "https://www.example.com/").map(\.kind) == [.searchResults])
    }

    @Test func theOtherWaysOfMatchingAreTheOnesOfBitwarden() {
        // Host: the name and the port.
        #expect(site("https://sub.example.com:8443", .host).matches(page: "https://sub.example.com:8443/a"))
        #expect(!site("https://sub.example.com:8443", .host).matches(page: "https://sub.example.com/a"))
        #expect(!site("https://sub.example.com", .host).matches(page: "https://other.example.com/"))
        #expect(site("https://example.com:443", .host).matches(page: "https://example.com/"))
        // Exact and "starts with" compare the addresses as they are written.
        #expect(site("https://example.com/login", .exact).matches(page: "https://example.com/login"))
        #expect(!site("https://example.com/login", .exact).matches(page: "https://example.com/login?x=1"))
        #expect(site("https://example.com/app", .startsWith).matches(page: "https://example.com/app/settings"))
        #expect(!site("https://example.com/app", .startsWith).matches(page: "https://example.com/"))
        // A regular expression, whatever the case; one that cannot be read matches nothing.
        #expect(site("^https://[a-z]+\\.example\\.com/", .regularExpression).matches(page: "https://SHOP.example.com/x"))
        #expect(!site("^https://[a-z]+\\.example\\.com/", .regularExpression).matches(page: "https://example.org/"))
        #expect(!site("([", .regularExpression).matches(page: "https://example.com/"))
        // Never.
        #expect(!site("https://example.com", .never).matches(page: "https://example.com/"))
        // The way of the account stands in for an address that names none.
        #expect(!site("https://www.example.com").matches(page: "https://shop.example.com/", defaultMatch: .host))
    }
}
