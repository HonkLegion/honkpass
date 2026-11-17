import Testing
import VaultModel

@Suite struct FolderTreeTests {
    private func tree(_ names: [String]) -> [FolderNode] {
        VaultContents(items: [], folders: names.enumerated().map { VaultFolder(id: "f\($0.offset)", name: $0.element) }).folderTree
    }

    /// The tree as text: one line for each node, two spaces for each level.
    private func outline(_ nodes: [FolderNode], depth: Int = 0) -> [String] {
        nodes.flatMap { [String(repeating: "  ", count: depth) + $0.name] + outline($0.children, depth: depth + 1) }
    }

    @Test func foldersWithoutASlashAreAFlatListInNameOrder() {
        #expect(outline(tree(["Work", "shopping", "Archive"])) == ["Archive", "shopping", "Work"])
    }

    @Test func aSlashPutsAFolderUnderTheFolderNamedBeforeIt() {
        // Names that sort alike in English and in Czech, where "ch" is a letter after "h".
        let nodes = tree(["Social/Forums/Tech", "Social", "Work", "Social/Forums", "Social/Blogs"])
        #expect(outline(nodes) == ["Social", "  Blogs", "  Forums", "    Tech", "Work"])
        // A node keeps the folder with its whole name.
        #expect(nodes[0].children[1].folder.name == "Social/Forums")
        #expect(nodes[0].children[1].children[0].folder.name == "Social/Forums/Tech")
    }

    @Test func withoutAParentFolderTheNameStaysWhole() {
        #expect(outline(tree(["Social/Forums", "Work"])) == ["Social/Forums", "Work"])
        // The grandparent is there, the parent is not: the two last parts are one name under it.
        #expect(outline(tree(["Social", "Social/Forums/Tech"])) == ["Social", "  Forums/Tech"])
    }

    @Test func slashesAtTheEndsDoNotCount() {
        #expect(outline(tree(["/Social/", "Social/Forums/"])) == ["Social", "  Forums"])
    }
}
