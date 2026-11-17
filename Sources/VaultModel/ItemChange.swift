import Foundation

/// A change of an item that needs no new content. The server changes the item itself, so
/// nothing is encrypted for it.
public enum ItemChange: Sendable, Codable, Hashable {
    case favorite(Bool)
    /// Into a folder; nil takes the item out of its folder.
    case moveToFolder(String?)
    case archive, unarchive
    case moveToTrash, restore
    /// Removes an item of the trash for ever.
    case deletePermanently
}

public extension VaultItemSummary {
    /// Whether the change applies to the item as it is, by the rules of the reference
    /// (vault-cipher-row.component.ts and cipher-action.service.ts).
    func allows(_ change: ItemChange) -> Bool {
        // An item that cannot be decrypted can only be deleted, as in the reference.
        if isUndecryptable {
            switch change {
            case .moveToTrash: return !isInTrash
            case .deletePermanently: return isInTrash
            default: return false
            }
        }
        // The favourite mark, the folder and the archive of an item of an organization are the
        // user's own; deleting and restoring it needs the right of the organization.
        return switch change {
        case .favorite(let isFavorite): isFavorite != self.isFavorite
        case .moveToFolder: !isInTrash
        case .archive: !isInTrash && !isArchived
        case .unarchive: !isInTrash && isArchived
        case .moveToTrash: !isInTrash && canDelete
        case .restore, .deletePermanently: isInTrash && canDelete
        }
    }
}

public extension VaultContents {
    /// The list after the change of one item. An unknown item changes nothing.
    mutating func apply(_ change: ItemChange, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch change {
        case .favorite(let isFavorite): items[index].isFavorite = isFavorite
        case .moveToFolder(let folderID): items[index].folderID = folderID
        case .archive: items[index].isArchived = true
        case .unarchive: items[index].isArchived = false
        case .moveToTrash: items[index].isInTrash = true
        // A restored item goes back to where it was: an archived one to the archive.
        case .restore: items[index].isInTrash = false
        case .deletePermanently: items.remove(at: index)
        }
    }
}
