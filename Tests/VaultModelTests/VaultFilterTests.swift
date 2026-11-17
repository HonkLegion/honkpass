import Testing
import VaultModel

@Suite struct VaultFilterTests {
    let contents = VaultContents(
        items: [
            VaultItemSummary(id: "1", type: .login, name: "Example Mail", subtitle: "test.user@example.com", isFavorite: true),
            VaultItemSummary(id: "2", type: .card, name: "Example Card", subtitle: "Visa, *4242"),
            VaultItemSummary(id: "3", type: .login, name: "example shop", subtitle: "shopper", folderID: "f1"),
            VaultItemSummary(id: "4", type: .login, name: "Example Deleted Login", isFavorite: true, folderID: "f1", isInTrash: true),
            VaultItemSummary(id: "5", type: .secureNote, name: "Árvíz note"),
        ],
        folders: [VaultFolder(id: "f1", name: "Shopping")])

    private func names(_ filter: VaultFilter, search: String = "") -> [String] {
        contents.items(in: filter, search: search).map(\.name)
    }

    @Test func theQuickAccessListsAreTheFavouritesAndAllItemsOrTheSearchResults() {
        let lists = contents.quickAccessSections(search: "")
        #expect(lists.map(\.kind) == [.favorites, .allItems])
        // The deleted favourite is in neither list.
        #expect(lists[0].items.map(\.name) == ["Example Mail"])
        #expect(lists[1].items.map(\.name) == ["Árvíz note", "Example Card", "Example Mail", "example shop"])
        // The favourite is a row of its own in each list.
        #expect(lists[0].rows.map(\.id) == ["favorites/1"])
        #expect(lists[1].rows.map(\.id) == ["allItems/5", "allItems/2", "allItems/1", "allItems/3"])

        let found = contents.quickAccessSections(search: " shop ")
        #expect(found.map(\.kind) == [.searchResults])
        #expect(found[0].items.map(\.name) == ["example shop"])
        #expect(contents.quickAccessSections(search: "zzzz").isEmpty)

        // No favourites: one list. An item that cannot be decrypted is in none.
        let plain = VaultContents(items: [
            VaultItemSummary(id: "1", type: .login, name: "Example Mail"),
            VaultItemSummary(id: "2", type: .login, name: "", isUndecryptable: true),
            VaultItemSummary(id: "3", type: .login, name: "Example Archived", isArchived: true),
        ], folders: [])
        #expect(plain.quickAccessSections(search: "").map(\.kind) == [.allItems])
        #expect(plain.quickAccessSections(search: "").first?.items.map(\.id) == ["1"])
        #expect(VaultContents(items: [], folders: []).quickAccessSections(search: "").isEmpty)
    }

    @Test func allItemsAreSortedByNameWithoutTheTrash() {
        #expect(names(.allItems) == ["Árvíz note", "Example Card", "Example Mail", "example shop"])
    }

    @Test func compactQuickAccessKeepsRankingAndListsEachItemOnce() {
        let rows = contents.quickAccessRows(search: "")
        #expect(rows.map(\.item.id) == ["1", "5", "2", "3"])
        #expect(rows.first?.id == "1")
        #expect(contents.quickAccessRows(search: "shop").map(\.id) == ["3"])
        #expect(contents.quickAccessRows(search: "unmatched").isEmpty)

        var vault = contents
        vault.items[0].websites = [.init(address: "https://mail.example.test")]
        let suggestions = vault.quickAccessRows(search: "", page: "https://mail.example.test/login")
        #expect(suggestions.first?.id == rows.first?.id)
        #expect(suggestions.filter { $0.item.id == "1" }.count == 1)
        #expect(Set(suggestions.map(\.item.id)) == Set(rows.map(\.item.id)))
        vault.items[0].isFavorite = false
        #expect(vault.quickAccessRows(search: "Mail").first?.id == rows.first?.id)
    }

    @Test func aClickOnTheNameColumnTurnsTheOrder() {
        let down = contents.items(in: .allItems, sort: VaultSort(column: .name, isAscending: false)).map(\.name)
        #expect(down == ["example shop", "Example Mail", "Example Card", "Árvíz note"])
        let up = contents.items(in: .allItems, sort: VaultSort(column: .name, isAscending: true)).map(\.name)
        #expect(up == names(.allItems))
    }

    @Test func anOrderByOwnerKeepsTheOrderThatWasThereForTheRowsOfOneOwner() {
        let vault = VaultContents(items: [
            VaultItemSummary(id: "1", type: .login, name: "Alpha"),
            VaultItemSummary(id: "2", type: .login, name: "Bravo", organizationID: "org-b"),
            VaultItemSummary(id: "3", type: .login, name: "Cedar"),
            VaultItemSummary(id: "4", type: .login, name: "Delta", organizationID: "org-a"),
            VaultItemSummary(id: "5", type: .login, name: "Echo", organizationID: "org-b"),
        ], folders: [])
        func names(_ sort: VaultSort?) -> [String] { vault.items(in: .allItems, sort: sort).map(\.name) }

        // Name, name again: downwards. Then the owner: the items of the user first, then the
        // organizations by their identifiers, and each group still downwards by name.
        var sort = VaultSort.afterClick(on: .name, from: nil)
        #expect(names(sort) == ["Alpha", "Bravo", "Cedar", "Delta", "Echo"])
        sort = .afterClick(on: .name, from: sort)
        #expect(names(sort) == ["Echo", "Delta", "Cedar", "Bravo", "Alpha"])
        sort = .afterClick(on: .owner, from: sort)
        #expect(sort.column == .owner && sort.isAscending)
        #expect(names(sort) == ["Cedar", "Alpha", "Delta", "Echo", "Bravo"])
        // The owner again turns the groups round and leaves the rows of a group as they lie.
        sort = .afterClick(on: .owner, from: sort)
        #expect(names(sort) == ["Echo", "Bravo", "Delta", "Cedar", "Alpha"])
        // Back to the name: upwards, and no earlier order of the name is kept.
        sort = .afterClick(on: .name, from: sort)
        #expect(names(sort) == ["Alpha", "Bravo", "Cedar", "Delta", "Echo"])
        #expect(sort.earlier == [VaultSort.Key(column: .owner, isAscending: false)])
        // The owner with no order before it: the rows of a group are in name order.
        #expect(names(.afterClick(on: .owner, from: nil)) == ["Alpha", "Cedar", "Delta", "Bravo", "Echo"])
    }

    @Test func theTrashHoldsOnlyDeletedItems() {
        #expect(names(.trash) == ["Example Deleted Login"])
        #expect(names(.favorites) == ["Example Mail"])
        #expect(names(.folder("f1")) == ["example shop"])
    }

    @Test func anArchivedItemShowsInTheArchiveOnlyAndInTheTrashOnceDeleted() {
        var contents = contents
        contents.apply(.archive, to: "1")
        #expect(contents.items(in: .archive).map(\.name) == ["Example Mail"])
        #expect(!contents.items(in: .allItems).map(\.name).contains("Example Mail"))
        #expect(contents.items(in: .favorites).isEmpty)
        #expect(contents.items(in: .type(.login)).map(\.name) == ["example shop"])

        contents.apply(.moveToTrash, to: "1")
        #expect(contents.items(in: .archive).isEmpty)
        #expect(contents.items(in: .trash).map(\.name) == ["Example Deleted Login", "Example Mail"])
        // A restored item goes back to the archive.
        contents.apply(.restore, to: "1")
        #expect(contents.items(in: .archive).map(\.name) == ["Example Mail"])
    }

    @Test func aChangeAppliesOnlyToAnItemInTheRightState() {
        let mail = contents.items[0], deleted = contents.items[3]
        #expect(mail.allows(.favorite(false)) && !mail.allows(.favorite(true)))
        #expect(mail.allows(.archive) && !mail.allows(.unarchive))
        #expect(mail.allows(.moveToTrash) && !mail.allows(.restore) && !mail.allows(.deletePermanently))
        #expect(deleted.allows(.restore) && deleted.allows(.deletePermanently))
        #expect(!deleted.allows(.moveToTrash) && !deleted.allows(.archive) && !deleted.allows(.unarchive))

        var contents = contents
        contents.apply(.deletePermanently, to: "4")
        #expect(contents.items.map(\.id) == ["1", "2", "3", "5"])
        contents.apply(.favorite(false), to: "missing")
        #expect(contents.items.count == 4)
    }

    @Test func filtersByTypeAndFolder() {
        #expect(names(.type(.login)) == ["Example Mail", "example shop"])
        #expect(names(.type(.identity)).isEmpty)
        #expect(names(.folder(nil)) == ["Árvíz note", "Example Card", "Example Mail"])
        #expect(names(.archive).isEmpty)
    }

    @Test func theHostOfAWebsiteFollowsBitwardensRule() {
        #expect(VaultItemSummary.websiteHost(of: "https://Mail.Example.com/login?x=1") == "mail.example.com")
        #expect(VaultItemSummary.websiteHost(of: "http://intranet.example.local") == "intranet.example.local")
        #expect(VaultItemSummary.websiteHost(of: "shop.example.com/path") == "shop.example.com")
        #expect(VaultItemSummary.websiteHost(of: "localhost") == nil)
        #expect(VaultItemSummary.websiteHost(of: "androidapp://com.example.app") == nil)
        #expect(VaultItemSummary.websiteHost(of: "https://hidden.onion") == nil)
        #expect(VaultItemSummary.websiteHost(of: "") == nil)
    }

    @Test func searchLooksInTheNameAndTheSubtitleWithoutCase() {
        #expect(names(.allItems, search: "MAIL") == ["Example Mail"])
        #expect(names(.allItems, search: "visa") == ["Example Card"])
        #expect(names(.allItems, search: "  shop ") == ["example shop"])
        #expect(names(.allItems, search: "zzzz-no-results").isEmpty)
        #expect(names(.trash, search: "deleted") == ["Example Deleted Login"])
    }
}
