import Foundation

/// One list of the quick access window, as the popup of the browser extension has them
/// (apps/browser/src/vault/popup/components/vault/vault.component.html).
public struct QuickAccessSection: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// The logins of the web page in front ("autofill suggestions" of the popup), and the
        /// ones of the app in front.
        case suggestions
        case favorites, allItems, searchResults
    }

    public let kind: Kind
    public let items: [VaultItemSummary]
    public var id: Kind { kind }

    public init(kind: Kind, items: [VaultItemSummary]) {
        self.kind = kind
        self.items = items
    }

    /// A row of the window. A favourite stands in two lists, so a row is known by its list
    /// and its item: the keyboard and an open menu are on one of the two rows.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let item: VaultItemSummary
    }

    public var rows: [Row] {
        items.map { Row(id: "\(kind)/\($0.id)", item: $0) }
    }
}

public extension VaultContents {
    /// The compact picker keeps the existing suggestion/favorite ordering and displays each
    /// item once. The section API remains available to clients that show grouped lists.
    func quickAccessRows(search: String, page: String? = nil, app: AppAddress? = nil) -> [QuickAccessSection.Row] {
        var seen = Set<String>()
        var rows: [QuickAccessSection.Row] = []
        for section in quickAccessSections(search: search, page: page, app: app) {
            for item in section.items where seen.insert(item.id).inserted {
                // Ranking changes must not move selection or a menu to another item.
                rows.append(.init(id: item.id, item: item))
            }
        }
        return rows
    }

    /// The lists of the quick access window: with a search text all that it finds in one list;
    /// without one the logins of the page and of the app in front, the favourites and all
    /// items. A list without items is left out, and so are the items of the trash and the
    /// archive and the ones that cannot be decrypted, which have nothing to copy.
    ///
    /// - Parameters:
    ///   - page: the address of the web page in the app in front, when there is one.
    ///   - app: the app in front as its code signature names it, when it is no browser.
    func quickAccessSections(search: String, page: String? = nil, app: AppAddress? = nil) -> [QuickAccessSection] {
        let all = items(in: .allItems, search: search).filter { !$0.isUndecryptable }
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return all.isEmpty ? [] : [QuickAccessSection(kind: .searchResults, items: all)]
        }
        let favorites = all.filter(\.isFavorite)
        return [QuickAccessSection(kind: .suggestions, items: logins(ofPage: page, app: app)),
                QuickAccessSection(kind: .favorites, items: favorites), QuickAccessSection(kind: .allItems, items: all)]
            .filter { !$0.items.isEmpty }
    }
}
