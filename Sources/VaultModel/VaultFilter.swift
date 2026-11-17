import Foundation

/// What a vault list shows. Every client filters with the same rules.
public enum VaultFilter: Sendable, Hashable {
    case allItems
    case favorites
    case type(ItemType)
    case archive
    case trash
    /// One folder. `nil` is "No folder".
    case folder(String?)
    /// One collection of an organization.
    case collection(String)
}

/// The order of a vault list after a click on a column title. Without one the list is in name order.
public struct VaultSort: Sendable, Hashable {
    public enum Column: Sendable, Hashable {
        case name, owner
    }

    /// The order by one column.
    public struct Key: Sendable, Hashable {
        public var column: Column
        public var isAscending: Bool

        public init(column: Column, isAscending: Bool) {
            self.column = column
            self.isAscending = isAscending
        }
    }

    public var column: Column
    public var isAscending: Bool
    /// The orders the list had before this one, the oldest first, each of another column.
    /// The reference sorts the rows as they lie (`TableDataSource.sortData`), so rows that
    /// are equal in the new order keep the order they had.
    public var earlier: [Key]

    public init(column: Column, isAscending: Bool, earlier: [Key] = []) {
        self.column = column
        self.isAscending = isAscending
        self.earlier = earlier
    }

    /// The order after a click on a column title (`bitSortable`): the same column turns
    /// round, another column sorts upwards over the order that was there.
    public static func afterClick(on column: Column, from sort: VaultSort?) -> VaultSort {
        guard let sort else { return VaultSort(column: column, isAscending: true) }
        guard sort.column != column else {
            return VaultSort(column: column, isAscending: !sort.isAscending, earlier: sort.earlier)
        }
        // Rows that are equal in this column were equal in its earlier order too: it says nothing more.
        let earlier = (sort.earlier + [Key(column: sort.column, isAscending: sort.isAscending)]).filter { $0.column != column }
        return VaultSort(column: column, isAscending: true, earlier: earlier)
    }
}

public extension VaultContents {
    /// The items of a filter that match the search text, sorted by name unless `sort` says otherwise.
    /// Items in the trash appear in the trash only, archived items in the archive or the trash.
    func items(in filter: VaultFilter, owner: VaultOwner = .all, search: String = "", sort: VaultSort? = nil) -> [VaultItemSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let byName = items
            .filter { item in
                switch owner {
                case .all: true
                case .user: item.organizationID == nil
                case .organization(let id): item.organizationID == id
                }
            }
            .filter { item in
                // createFilterFunction of the reference: the trash holds every deleted item, the
                // archive the archived ones that are not deleted, and no other list shows either.
                switch filter {
                case .trash: return item.isInTrash
                case .archive: return item.isArchived && !item.isInTrash
                default: break
                }
                guard !item.isInTrash, !item.isArchived else { return false }
                return switch filter {
                case .allItems, .trash, .archive: true
                case .favorites: item.isFavorite
                case .type(let type): item.type == type
                case .folder(let id): item.folderID == id
                case .collection(let id): item.collectionIDs.contains(id)
                }
            }
            .filter { item in
                needle.isEmpty
                    || item.name.localizedCaseInsensitiveContains(needle)
                    || item.subtitle.localizedCaseInsensitiveContains(needle)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let sort else { return byName }
        // Each order is laid over the one before it, the oldest first: equal rows stay as they lie.
        return (sort.earlier + [VaultSort.Key(column: sort.column, isAscending: sort.isAscending)]).reduce(byName) { rows, key in
            rows.sorted { first, second in
                let order = switch key.column {
                case .name: first.name.localizedCaseInsensitiveCompare(second.name)
                // `sortByOwner` compares the identifiers of the organizations, not their names.
                // The items of the user have none and come first.
                case .owner: (first.organizationID ?? "").localizedCaseInsensitiveCompare(second.organizationID ?? "")
                }
                return order == (key.isAscending ? .orderedAscending : .orderedDescending)
            }
        }
    }
}
