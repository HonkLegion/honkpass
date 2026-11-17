import Foundation

/// One folder in the tree of the side navigation.
public struct FolderNode: Sendable, Equatable, Identifiable {
    /// The folder as the vault has it, with its whole name.
    public let folder: VaultFolder
    /// The part of the name that the tree shows at this place.
    public let name: String
    public var children: [FolderNode]

    public var id: String { folder.id }
}

public extension VaultContents {
    /// The folders as Bitwarden nests them: a "/" in a name puts the folder under the folder
    /// that is named by the part before it, when there is one. "Social/Forums" lies under
    /// "Social" as "Forums"; without a folder "Social" it stays "Social/Forums".
    /// (`buildFolderTree` and `ServiceUtils.nestedTraverse` of the reference.)
    var folderTree: [FolderNode] {
        let named = folders.map { folder -> (folder: VaultFolder, parts: [String]) in
            var name = Substring(folder.name)
            while name.hasPrefix("/") { name = name.dropFirst() }
            while name.hasSuffix("/") { name = name.dropLast() }
            return (folder, name.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        var roots: [FolderNode] = []
        // A parent has fewer parts than its children, so it is placed before them. The reference
        // gets the same from the order of the whole names; the order of each level follows below.
        for entry in named.sorted(by: { $0.parts.count < $1.parts.count }) {
            Self.place(entry.folder, parts: entry.parts, at: 0, in: &roots)
        }
        return Self.sorted(roots)
    }

    /// Every level in the order of the names it shows.
    private static func sorted(_ nodes: [FolderNode]) -> [FolderNode] {
        nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { node in
            FolderNode(folder: node.folder, name: node.name, children: sorted(node.children))
        }
    }

    private static func place(_ folder: VaultFolder, parts: [String], at index: Int, in nodes: inout [FolderNode]) {
        guard index < parts.count else { return }
        let part = parts[index]
        if index == parts.count - 1 {
            nodes.append(FolderNode(folder: folder, name: part, children: []))
        } else if let parent = nodes.firstIndex(where: { $0.name == part }) {
            place(folder, parts: parts, at: index + 1, in: &nodes[parent].children)
        } else {
            // No folder of that name here: the part and the next one are one name at this level.
            let joined = [part + "/" + parts[index + 1]] + parts[(index + 2)...]
            place(folder, parts: joined, at: 0, in: &nodes)
        }
    }
}
