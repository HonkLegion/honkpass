import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The open vault: side navigation, header, search and the table of items.
/// Reference: docs/reference/vault-*.png. Source: apps/desktop/src/app/layout and
/// apps/desktop/src/vault/app/vault-v3 (the layout without the "VFO1" flag).
///
/// Parts that PassVault does not have yet are shown disabled (PLAN.md, allowed deviations).
struct VaultScreen: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation
    let preferences: AppPreferences
    let account: Account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The row whose checkbox the pointer is over.
    @State private var hoveredCheckboxItemID: String?
    /// The list is higher than its area: its scrollbar takes room beside the table.
    @State private var listScrolls = false
    /// Keep the column until its outgoing transition ends. A new presentation replaces the token.
    @State private var panelSpaceReservation: UUID?
    @State private var panelOpacity = 1.0
    @State private var presentedPanel: PanelContent?

    private enum PanelID: Equatable {
        case item(String), editor(ObjectIdentifier), send(ObjectIdentifier)
    }

    private enum PanelContent {
        case item(String), editor(ItemForm), send(SendForm)

        var id: PanelID {
            switch self {
            case .item(let id): .item(id)
            case .editor(let form): .editor(ObjectIdentifier(form))
            case .send(let form): .send(ObjectIdentifier(form))
            }
        }
    }

    private var activePanel: PanelContent? {
        if let form = navigation.sendForm { return .send(form) }
        if let form = navigation.itemForm { return .editor(form) }
        return navigation.openItemID.map(PanelContent.item)
    }

    /// The ticked rows that the list shows now.
    private var checkedItems: [VaultItemSummary] {
        guard !navigation.checkedItemIDs.isEmpty else { return [] }
        return items.filter { navigation.checkedItemIDs.contains($0.id) }
    }

    private var vault: VaultContents { model.state.vault }
    private var hasPanel: Bool {
        navigation.openItemID != nil || navigation.itemForm != nil || navigation.sendForm != nil
    }
    private var panelAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.22) }
    private var panelTransition: AnyTransition {
        .asymmetric(insertion: panelSpaceReservation == nil ? .opacity : .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity)
    }
    private var items: [VaultItemSummary] {
        vault.items(in: navigation.filter, owner: navigation.owner, search: navigation.search, sort: navigation.sort)
    }

    /// The strip of the ground of the navigation that stays at the right and at the bottom of
    /// the panel, and the radius of the corners of the panel: PassVault's own (PLAN.md,
    /// "Differences from the reference"). DesignKit holds the shared window geometry.
    private static let frame = Metric.windowInset
    private static let panelRadius = Metric.panelRadius

    /// bit-layout: the side navigation, the main content and, while an item is open, its panel
    /// (libs/components/src/layout/layout.component.ts). The main content keeps its least
    /// width: in a window too narrow for all three the navigation closes to its rail first,
    /// then the panel gets narrower, and at last it lies over the list. The content and the
    /// panel of an item are one panel with rounded corners on the ground of the navigation.
    var body: some View {
        GeometryReader { geometry in
            let wanted = hasPanel || panelSpaceReservation != nil ? BWLayout.drawerMaxWidth : 0
            // What the three columns share: the window without the strip at its right.
            let room = max(geometry.size.width - Self.frame, 0)
            let layout = BWLayout(window: room, size: navigation.sideNavigation, drawer: wanted)
            let panelWidth = layout.drawer
            let mainWidth = layout.main + panelWidth * (1 - panelOpacity)
            HStack(spacing: 0) {
                if layout.navigationOverlays {
                    // The place of the rail, under the navigation that lies over the content.
                    Color.clear.frame(width: layout.navigation)
                } else {
                    sideNavigation
                        .frame(width: layout.navigation)
                        // The rail's intrinsic background must not cover the panel's rounded edge.
                        .clipped()
                        .overlay(alignment: .trailing) { SideNavigationResizeHandle(size: $navigation.sideNavigation) }
                        // The handle lies half over the main content.
                        .zIndex(1)
                }
                HStack(spacing: 0) {
                    if mainWidth > 0 {
                        if navigation.page == .sends {
                            SendList(model: model, navigation: navigation, account: account, width: mainWidth)
                                .frame(width: mainWidth)
                        } else {
                            main(width: mainWidth)
                                .frame(width: mainWidth)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    ZStack(alignment: .trailing) {
                        if let panel = activePanel ?? presentedPanel {
                            switch panel {
                            case .send(let form):
                                SendPanel(model: model, navigation: navigation, form: form)
                                    .frame(width: panelWidth)
                                    .id(ObjectIdentifier(form))
                            case .editor(let form):
                                ItemFormPanel(model: model, navigation: navigation, form: form)
                                    .frame(width: panelWidth)
                                    .id(ObjectIdentifier(form))
                                    .transition(panelTransition)
                            case .item(let itemID):
                                ItemPanel(model: model, navigation: navigation, itemID: itemID)
                                    .frame(width: panelWidth)
                                    // Another item starts with everything hidden again.
                                    .id(itemID)
                                    .transition(panelTransition)
                            }
                        }
                    }
                    .animation(panelAnimation, value: navigation.itemForm != nil)
                    .animation(panelAnimation, value: navigation.openItemID != nil)
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.theme(.bgTertiary))
                    .clipped()
                    .offset(x: panelWidth * (1 - panelOpacity))
                    .opacity(panelOpacity)
                    .allowsHitTesting(hasPanel)
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.panelRadius))
                .padding(.trailing, Self.frame)
                .padding(.bottom, Self.frame)
            }
            // The ground of the navigation, which shows around the corners of the panel and at
            // its right and its bottom.
            .background(.theme(.navBgPrimary))
            .animation(panelAnimation, value: navigation.isSideNavigationCollapsed)
            .environment(\.bwWindowWidth, geometry.size.width)
            .onChange(of: activePanel?.id, initial: true) {
                if let activePanel {
                    presentedPanel = activePanel
                    panelSpaceReservation = UUID()
                    withAnimation(panelAnimation) { panelOpacity = 1 }
                } else {
                    let reservation = panelSpaceReservation
                    withAnimation(panelAnimation, completionCriteria: .removed) {
                        panelOpacity = 0
                    } completion: {
                        guard !hasPanel, panelSpaceReservation == reservation else { return }
                        panelSpaceReservation = nil
                        presentedPanel = nil
                    }
                }
            }
            // A navigation that the user opened where it has no column: it lies over the
            // content, on the backdrop of a dialog, and a click on the backdrop closes it.
            .overlay(alignment: .leading) {
                if layout.navigationOverlays {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.theme(.bgOverlay))
                            .contentShape(Rectangle())
                            .onTapGesture { navigation.sideNavigation.toggle() }
                        sideNavigation
                            .frame(width: min(navigation.sideNavigation.displayWidth, geometry.size.width))
                            .overlay(alignment: .trailing) { SideNavigationResizeHandle(size: $navigation.sideNavigation) }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(panelAnimation, value: layout.navigationOverlays)
            // The navigation is fitted again when the window, the panel or its own width changes.
            .onChange(of: [room, wanted, navigation.sideNavigation.width], initial: true) {
                navigation.sideNavigation.fit(window: room, drawer: wanted)
            }
            .onChange(of: mainWidth > 0) { wasVisible, isVisible in
                // Recreating the list header restores its search field's focus.
                if !wasVisible, isVisible, navigation.page == .vault { navigation.searchFocusRequest += 1 }
            }
            .onChange(of: navigation.searchFocusRequest) {
                guard navigation.page == .vault, mainWidth == 0 else { return }
                // Command-F must reach the list when a narrow panel covers it. A dirty
                // editor keeps the existing confirmation before anything is discarded.
                navigation.leaveForm {
                    navigation.itemForm = nil
                    navigation.openItemID = nil
                }
            }
        }
    }

    // MARK: Side navigation

    private var sideNavigation: some View {
        SideNavigation(isCollapsed: navigation.isSideNavigationCollapsed, onHome: {
            navigation.leaveForm {
                navigation.itemForm = nil
                navigation.sendForm = nil
                navigation.openItemID = nil
                navigation.page = .vault
                navigation.filter = .allItems
                navigation.owner = .all
                navigation.search = ""
                navigation.checkedItemIDs = []
            }
        }) {
            // The group is highlighted only on the rail; open, its children show what is chosen.
            NavItem(BWText["vault"], icon: .vault, isActive: navigation.isSideNavigationCollapsed && navigation.page == .vault,
                    chevron: navigation.isVaultGroupOpen ? .open : .closed,
                    onToggle: { navigation.isVaultGroupOpen.toggle() }) {
                select(.allItems)
            }
            if navigation.isVaultGroupOpen {
                // The filters of the vault have "forceActiveStyles" from the chosen filter, not from
                // the page: they stay marked while the Sends show (docs/reference/send-*.png).
                NavItem(BWText["allVaults"], icon: .grid, depth: 1, isActive: navigation.owner == .all,
                        chevron: navigation.isOwnerListOpen ? .open : .closed,
                        onToggle: { navigation.isOwnerListOpen.toggle() }) {
                    select(owner: .all)
                }
                if navigation.isOwnerListOpen {
                    NavItem(BWText["myVault"], icon: .user, depth: 2, isActive: navigation.owner == .user) {
                        select(owner: .user)
                    }
                    // organization-filter: one row for each organization of the account.
                    ForEach(vault.organizations) { organization in
                        NavItem(organization.name, icon: .business, depth: 2, isActive: navigation.owner == .organization(organization.id)) {
                            select(owner: .organization(organization.id))
                        }
                    }
                }
                NavItem(BWText["allItems"], icon: .grid, depth: 1, isActive: isAllItemsChosen,
                        chevron: navigation.isTypeListOpen ? .open : .closed,
                        onToggle: { navigation.isTypeListOpen.toggle() }) {
                    select(.allItems)
                }
                if navigation.isTypeListOpen {
                    filterItem("favorites", .star, .favorites)
                    filterItem("typeLogin", .globe, .type(.login))
                    filterItem("typeCard", .creditCard, .type(.card))
                    filterItem("typeIdentity", .idCard, .type(.identity))
                    filterItem("typeSecureNote", .stickyNote, .type(.secureNote))
                    filterItem("typeSshKey", .key, .type(.sshKey))
                }
                filterItem("archiveNoun", .archive, .archive, depth: 1)
                filterItem("trash", .trash, .trash, depth: 1)
                NavItem(BWText["folders"], icon: .folder, depth: 1, chevron: navigation.isFolderListOpen ? .open : .closed,
                        onToggle: { navigation.isFolderListOpen.toggle() }) { navigation.isFolderListOpen.toggle() }
                if navigation.isFolderListOpen {
                    // app-folder-filter: a folder with folders under it is a group that its arrow
                    // opens; a click on its name shows its own items.
                    ForEach(visibleFolders, id: \.node.id) { row in
                        let isOpen = navigation.openFolderIDs.contains(row.node.id)
                        NavItem(row.node.name, icon: .folder, depth: row.depth, isActive: navigation.filter == .folder(row.node.id),
                                chevron: row.node.children.isEmpty ? nil : (isOpen ? .open : .closed),
                                onToggle: {
                                    if isOpen { navigation.openFolderIDs.remove(row.node.id) } else { navigation.openFolderIDs.insert(row.node.id) }
                                }) {
                            select(.folder(row.node.id))
                        } trailing: {
                            NavIconButton(.pencil, label: BWText["editFolder"]) { navigation.folderDialog = .edit(row.node.folder) }
                        }
                    }
                    NavItem(BWText["noneFolder"], icon: .folder, depth: 2, isActive: navigation.filter == .folder(nil)) {
                        select(.folder(nil))
                    }
                }
                // collection-filter: the collections of the organizations, when the account has any.
                if !vault.collections.isEmpty {
                    NavItem(BWText["collections"], icon: .collectionShared, depth: 1,
                            chevron: navigation.isCollectionListOpen ? .open : .closed,
                            onToggle: { navigation.isCollectionListOpen.toggle() }) { navigation.isCollectionListOpen.toggle() }
                    if navigation.isCollectionListOpen {
                        ForEach(vault.collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { collection in
                            NavItem(collection.name, icon: .collectionShared, depth: 2,
                                    isActive: navigation.filter == .collection(collection.id)) {
                                select(.collection(collection.id))
                            }
                        }
                    }
                }
            }
            // send-filters-nav.component.html: the group of the Sends with its two types. A click on
            // the group shows all of them.
            let showsSends = navigation.page == .sends
            NavItem(BWText["send"], icon: .send, isActive: navigation.isSideNavigationCollapsed && showsSends,
                    chevron: navigation.isSendListOpen ? .open : .closed,
                    onToggle: { navigation.isSendListOpen.toggle() }) {
                navigation.showSends(nil)
            }
            if navigation.isSendListOpen {
                NavItem(BWText["allSends"], icon: .send, depth: 1, isActive: showsSends && navigation.sendFilter == nil) { navigation.showSends(nil) }
                NavItem(BWText["sendTypeText"], icon: .fileText, depth: 1, isActive: showsSends && navigation.sendFilter == .text) {
                    navigation.showSends(.text)
                }
                NavItem(BWText["sendTypeFile"], icon: .file, depth: 1, isActive: showsSends && navigation.sendFilter == .file) {
                    navigation.showSends(.file)
                }
            }
            // The generator of the reference is a dialog over the vault.
            NavItem(BWText["generator"], icon: .generate) {
                navigation.generator = GeneratorSession(purpose: .standalone, options: model.state.settings.generator)
            }
            NavItem(BWText["importNoun"], icon: .import) { navigation.isImporting = true }
            NavItem(BWText["exportNoun"], icon: .download) { navigation.isExporting = true }
        } footer: {
            accountButton
        }
    }

    /// The folders of the tree that show now, each with its depth in the side navigation.
    private var visibleFolders: [(node: FolderNode, depth: Int)] {
        func rows(_ nodes: [FolderNode], depth: Int) -> [(node: FolderNode, depth: Int)] {
            nodes.flatMap { node in
                [(node, depth)] + (navigation.openFolderIDs.contains(node.id) ? rows(node.children, depth: depth + 1) : [])
            }
        }
        return rows(vault.folderTree, depth: 2)
    }

    private func filterItem(_ key: String, _ icon: BWIcon, _ filter: VaultFilter, depth: Int = 2) -> some View {
        NavItem(BWText[key], icon: icon, depth: depth, isActive: navigation.filter == filter) { select(filter) }
    }

    private func select(_ filter: VaultFilter) {
        navigation.showVault(filter)
    }

    /// "All items" of type-filter.component.html is marked while no type is chosen: a folder
    /// and a collection leave the type alone (docs/reference/vault-folder-*.png).
    private var isAllItemsChosen: Bool {
        switch navigation.filter {
        case .allItems, .folder, .collection: true
        case .favorites, .type, .archive, .trash: false
        }
    }

    /// organization-filter: another owner keeps the type and leaves the folder and the
    /// collection (`selectedOrganizationNode` of routed-vault-filter-bridge.model.ts), and
    /// the vault shows.
    private func select(owner: VaultOwner) {
        switch navigation.filter {
        case .folder, .collection: navigation.showVault(.allItems, owner: owner)
        case .allItems, .favorites, .type, .archive, .trash: navigation.showVault(navigation.filter, owner: owner)
        }
    }

    // MARK: Main area

    private func main(width: CGFloat) -> some View {
        // The table has what "tw-px-6" and the scrollbar leave of the main content. The owner
        // column has "tw-hidden @xl:tw-table-cell": it is there while the table is 36 rem wide.
        let tableWidth = width - 2 * Metric.space(6) - (listScrolls ? BWScrollbar.width : 0)
        let showsOwner = tableWidth >= 36 * Metric.rem
        return VStack(spacing: 0) {
            header
            BWScrollView(onScroll: { listScrolls = $0.isScrollable }) {
                // "tw-mb-4 tw-px-6"; the viewport has "tw-pb-[9rem]" while the bar of bulk actions is there.
                table(showsOwner: showsOwner, width: tableWidth)
                    .padding(.horizontal, Metric.space(6))
                    .padding(.bottom, Metric.space(4) + (checkedItems.isEmpty ? 0 : 9 * Metric.rem))
            }
            .overlay(alignment: .top) { BWHeaderFade() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // main: "tw-bg-background"
        .background(.theme(.bgPrimary))
        // bit-bulk-actions-bar: in the middle of the bottom of the list, over its rows.
        .overlay(alignment: .bottom) {
            if !checkedItems.isEmpty {
                BWBulkActionsBar(count: checkedItems.count, onClear: { navigation.checkedItemIDs = [] }, actions: bulkActions)
            }
        }
    }

    /// `visibleActions` of vault-batch-action.component.ts with the rules of vault-batch-bar.service.ts
    /// for a personal vault: "add to folder" and the archive outside the trash, "restore" in it.
    private var bulkActions: [BWBulkActionsBar.Action] {
        let chosen = checkedItems
        let actions = ItemActions(model: model, navigation: navigation)
        let inTrash = navigation.filter == .trash
        // An item that cannot be decrypted can only be deleted.
        let canChange = !chosen.contains(where: \.isUndecryptable)
        var bar: [BWBulkActionsBar.Action] = []
        if !inTrash, canChange {
            bar.append(.init(BWText["addToFolder"], icon: .folder) { actions.bulkMoveToFolder(chosen) })
            if !chosen.contains(where: \.isArchived) {
                bar.append(.init(BWText["archiveVerb"], icon: .archive) { actions.bulkArchive(chosen) })
            } else if chosen.allSatisfy(\.isArchived) {
                bar.append(.init(BWText["unArchive"], icon: .unarchive) { actions.bulkUnarchive(chosen) })
            }
        }
        if inTrash, canChange {
            bar.append(.init(BWText["restore"], icon: .undo) { actions.bulkRestore(chosen) })
        }
        bar.append(.init(BWText[inTrash ? "permanentlyDelete" : "delete"], icon: .trash) { actions.bulkDelete(chosen) })
        return bar
    }

    /// The opaque list title shares the detail header's height.
    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            // h1 bitTypography="h1" noMargin. Its "!tw-text-3xl" wins over "tw-leading-10".
            Text(BWText["vault"])
                .textStyle(.h1)
                .foregroundStyle(.theme(.textMain))
                .fixedSize()
            Spacer(minLength: Metric.space(4))
            BWSearchField(text: $navigation.search, placeholder: BWText[navigation.searchPlaceholderKey],
                          takesFocus: true, focusRequest: navigation.searchFocusRequest, isSmall: true)
                .frame(minWidth: 0, maxWidth: Metric.windowSearchWidth)
        }
        .padding(.horizontal, Metric.space(6))
        .frame(minHeight: Metric.panelHeaderHeight)
        .background(.theme(.bgPrimary))
        .clipped()
    }

    /// The account at the bottom of the side navigation, which opens the menu of the accounts
    /// (app-account-switcher-v2, which the reference has in the header).
    private var accountButton: some View {
        AccountNavButton(model: model, account: account, opensMenu: navigation.accountMenuStartsOpen)
    }

    // MARK: Table

    private static let checkboxColumn: CGFloat = Metric.space(10)
    private static let ownerColumn: CGFloat = Metric.space(40)
    private static let optionsColumn: CGFloat = Metric.space(56)

    /// The width of the options column: "tw-w-56". In a table too narrow for it, beside an open
    /// item, the auto layout of the reference takes the missing width from this column: the
    /// name cell keeps its paddings, its icon and the gap after it
    /// (docs/reference/item-login-*.png).
    private func optionsColumn(in width: CGFloat, showsOwner: Bool) -> CGFloat {
        if width < 30 * Metric.rem { return Metric.space(30) }
        let nameCell = 2 * Metric.space(3) + 29 + Metric.space(2)
        let rest = width - Self.checkboxColumn - (showsOwner ? Self.ownerColumn : 0) - nameCell
        return min(Self.optionsColumn, max(0, rest))
    }

    /// bit-table: thead "tw-border-b-2 tw-border-border-base tw-font-medium tw-text-muted", cells "tw-p-3",
    /// rows "tw-border-b tw-border-border-base" and 76.5 pixels high.
    private func table(showsOwner: Bool, width: CGFloat) -> some View {
        let items = items
        let optionsColumn = optionsColumn(in: width, showsOwner: showsOwner)
        return LazyVStack(spacing: 0) {
            tableHeader(items: items, showsOwner: showsOwner, optionsColumn: optionsColumn)
            Rectangle().fill(.theme(.borderBase)).frame(height: 2)
            ForEach(items) { item in
                // One child per item lets the lazy stack count rows without building their contents.
                VStack(spacing: 0) {
                    row(item, showsOwner: showsOwner, optionsColumn: optionsColumn)
                    if item.id != items.last?.id {
                        Rectangle().fill(.theme(.borderBase)).frame(height: 1)
                    }
                }
            }
            // The empty state comes after the table and its "tw-mb-4".
            if items.isEmpty { emptyState.padding(.top, Metric.space(4)) }
        }
    }

    private func tableHeader(items: [VaultItemSummary], showsOwner: Bool, optionsColumn: CGFloat) -> some View {
        HStack(spacing: 0) {
            checkboxCell(BWCheckboxBox(isOn: Binding(get: { !items.isEmpty && items.allSatisfy { navigation.checkedItemIDs.contains($0.id) } },
                                                     set: { navigation.checkedItemIDs = $0 ? Set(items.map(\.id)) : [] }),
                                       label: BWText["selectAll"])
                .disabled(items.isEmpty))
            // The title does not break: in a narrow table it reaches out of its column.
            sortableHeader(BWText["name"], .name)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if showsOwner {
                sortableHeader(BWText["owner"], .owner)
                    .frame(width: Self.ownerColumn, alignment: .leading)
            }
            Text(BWText["options"])
                .textStyle(TextStyle(size: TextStyle.body.size, lineHeight: TextStyle.base.lineHeight, weight: 500))
                .padding(Metric.space(3))
                .frame(width: optionsColumn, alignment: .trailing)
        }
        .foregroundStyle(.theme(.textMuted))
        // The header row is 43.5 pixels high (measured in docs/reference/vault-all-items-*.png).
        .frame(height: 43.5)
    }

    /// td "tw-p-3" "tw-w-10" around a checkbox with "!-tw-ms-px"; the box sits 1.5 pixels above the
    /// middle of the row (measured).
    private func checkboxCell(_ checkbox: some View) -> some View {
        checkbox
            .padding(.leading, Metric.space(3) - 1)
            .offset(y: -1.5)
            .frame(width: Self.checkboxColumn, alignment: .leading)
    }

    /// bitSortable: a button with the label and an icon after "tw-ms-2", in a one pixel transparent border.
    /// The icon is "bwi-up-down-btn" until the column sorts the list, then "bwi-up-solid" or "bwi-down-solid".
    /// A click on another column sorts upwards; a click on the same column turns the order.
    private func sortableHeader(_ label: String, _ column: VaultSort.Column) -> some View {
        let active = navigation.sort?.column == column ? navigation.sort : nil
        return Button {
            navigation.sort = .afterClick(on: column, from: navigation.sort)
        } label: {
            // The icon has "tw-ms-2" after the space that follows the label.
            HStack(spacing: Metric.space(2) + 0.28 * TextStyle.body.size) {
                Text(label).lineLimit(1).textStyle(.body.weight(500))
                IconView(active.map { $0.isAscending ? .upSolid : .downSolid } ?? .upDownBtn, size: TextStyle.body.size)
            }
            .fixedSize()
            .padding(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .padding(Metric.space(3))
    }

    private func row(_ item: VaultItemSummary, showsOwner: Bool, optionsColumn: CGFloat) -> some View {
        HStack(spacing: 0) {
            checkboxCell(BWCheckboxBox(isOn: Binding(get: { navigation.checkedItemIDs.contains(item.id) },
                                                     set: { isOn in
                                                         if isOn {
                                                             navigation.checkedItemIDs.insert(item.id)
                                                         } else {
                                                             navigation.checkedItemIDs.remove(item.id)
                                                         }
                                                     }),
                                       label: item.name)
                .onHover { isOver in
                    if isOver { hoveredCheckboxItemID = item.id } else if hoveredCheckboxItemID == item.id { hoveredCheckboxItemID = nil }
                })
            // td "tw-flex tw-items-center tw-gap-2"
            HStack(spacing: Metric.space(2)) {
                itemIcon(item)
                VStack(alignment: .leading, spacing: 0) {
                    // button bitLink "tw-leading-snug" with the "tw-py-0.5" of a link.
                    HStack(alignment: .center, spacing: 0) {
                        // An item that could not be decrypted has no name; its row says so and
                        // opens the dialog that names it.
                        BWLink(item.isUndecryptable ? BWText["errorCannotDecrypt"] : item.name,
                               lineHeight: 1.375 * TextStyle.body.size) {
                            guard !item.isUndecryptable else {
                                navigation.decryptionFailureItemID = item.id
                                return
                            }
                            navigation.perform(on: item) {
                                // Another item takes the place of an open form, which asks first when it has changes.
                                navigation.leaveForm {
                                    navigation.itemForm = nil
                                    navigation.openItemID = item.id
                                }
                            }
                        }
                        if item.attachmentCount > 0 {
                            // i "bwi bwi-paperclip tw-ml-2 tw-leading-normal"
                            IconView(.paperclip, size: TextStyle.body.size)
                                .foregroundStyle(.theme(.textMain))
                                .padding(.leading, Metric.space(2))
                                .help(BWText["attachments"])
                        }
                    }
                        .padding(.vertical, Metric.space(0.5))
                    if !item.subtitle.isEmpty {
                        // span "tw-text-sm tw-text-muted" on its own line of the cell, which is 21 pixels high.
                        Text(item.subtitle)
                            .lineLimit(1)
                            .textStyle(TextStyle(size: TextStyle.sm.size, lineHeight: TextStyle.base.lineHeight))
                            .foregroundStyle(.theme(.textMuted))
                    }
                }
            }
            .padding(Metric.space(3))
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsOwner {
                // app-org-badge: the name of the organization, or "me" for an item of the personal vault.
                BWChip(vault.organizationName(of: item) ?? BWText["me"])
                    .padding(Metric.space(3))
                    .frame(width: Self.ownerColumn, alignment: .leading)
            }
            // td bitCell "tw-text-right tw-whitespace-nowrap" with the "tw-p-3" of a cell.
            quickActions(item, isCompact: optionsColumn < Self.optionsColumn)
                .padding(.trailing, Metric.space(3))
                .frame(width: optionsColumn, alignment: .trailing)
        }
        .frame(height: 76.5)
        // "has-[input[type=checkbox]:hover]:tw-bg-bg-brand-softer" and "has-[input[type=checkbox]:checked]:tw-bg-bg-brand-soft".
        // Under the pointer the softer one shows for a ticked row too (docs/reference/vault-row-checked-*.png).
        .background(.theme((hoveredCheckboxItemID ?? navigation.pointerOnCheckboxItemID) == item.id ? .bgBrandSofter
            : navigation.checkedItemIDs.contains(item.id) ? .bgBrandSoft : .clear))
    }

    /// app-vault-icon: the picture of a card brand, else the icon of the type with "bwi-lg" in "tw-text-muted".
    /// The desktop styles give it a box of 34 by 36 pixels with "margin-left: -5px" (apps/desktop/src/scss/misc.scss).
    /// A login shows the picture of its website: img "tw-rounded-md" "tw-size-6", and the icon until it is there.
    private func itemIcon(_ item: VaultItemSummary) -> some View {
        ItemRowIcon(model: model, item: item)
            .frame(width: 34, height: 36)
            .padding(.leading, -5)
    }

    static func icon(for type: ItemType) -> BWIcon {
        ItemRowIcon.icon(for: type)
    }

    /// The last cell of vault-cipher-row: the launch button of a login with a website, the quick copy
    /// buttons of vault-item-copy-actions, then the menu button. The launch and the menu button have
    /// the default size; the copy buttons are small.
    /// A button for a field the item does not have is disabled, as in the reference.
    private func quickActions(_ item: VaultItemSummary, isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            if item.isUndecryptable {
                // `decryptionFailure`: the menu with "delete" and nothing else.
                EmptyView()
            } else if item.type == .login, item.fields.contains(.website) {
                BWIconButton(.externalLink, label: BWText["launchWebsite"]) { launch(item) }
            }
            // showCopyActions: an item in the trash or in the archive has no copy buttons.
            if !item.isInTrash, !item.isArchived, !item.isUndecryptable {
                ItemCopyActions(model: model, navigation: navigation, item: item,
                                showsQuickCopy: preferences.showsQuickCopyActions && !isCompact)
            }
            BWIconButton(.ellipsisV, label: BWText["moreOptions"]) { navigation.openMenuItemID = item.id }
                .bwMenu(isOpen: Binding(get: { navigation.openMenuItemID == item.id },
                                        set: { if !$0 { navigation.openMenuItemID = nil } })) { menuItems(item) }
        }
        .environment(\.iconButtonGlyphSize, Metric.vaultActionIconSize)
        .environment(\.iconButtonHoverSize, Metric.vaultActionHoverSize)
    }

    /// The `bit-menu` of vault-cipher-row.component.html for an item of the personal vault.
    private func menuItems(_ item: VaultItemSummary) -> [BWMenuItem] {
        let actions = ItemActions(model: model, navigation: navigation)
        if item.isUndecryptable {
            return [BWMenuItem(BWText[item.isInTrash ? "permanentlyDelete" : "delete"], icon: .trash, kind: .danger,
                               iconPlace: .startSlot) { actions.delete(item) }]
        }
        var items = [
            BWMenuItem(BWText[item.isFavorite ? "unfavorite" : "favorite"], icon: .star) { actions.toggleFavorite(item) },
            // The reference shows "edit" for an item in the trash too, where its form saves nothing; PassVault has no form there.
            BWMenuItem(BWText["edit"], icon: .pencilSquare, isEnabled: !item.isInTrash && !item.isReadOnly) { actions.edit(item) },
            BWMenuItem(BWText["attachments"], icon: .paperclip, isEnabled: !item.isInTrash && !item.isReadOnly) {
                actions.showAttachments(item)
            },
        ]
        if !item.isInTrash {
            // An item of an organization is copied only by one who may change it.
            if !item.isReadOnly { items.append(BWMenuItem(BWText["clone"], icon: .files) { actions.clone(item) }) }
            // "Assign to collections": while the account has an organization, for an item the user may change.
            if !vault.organizations.isEmpty, !item.isReadOnly {
                items.append(BWMenuItem(BWText["assignToCollections"], icon: .collectionShared) { actions.assignToCollections(item) })
            }
            items.append(item.isArchived
                ? BWMenuItem(BWText["unArchive"], icon: .unarchive) { actions.unarchive(item) }
                : BWMenuItem(BWText["archiveVerb"], icon: .archive) { actions.archive(item) })
        } else {
            items.append(BWMenuItem(BWText["restore"], icon: .undo) { actions.restore(item) })
        }
        if item.canDelete {
            items.append(BWMenuItem(BWText[item.isInTrash ? "permanentlyDelete" : "delete"], icon: .trash, kind: .danger,
                                    iconPlace: .startSlot) { actions.delete(item) })
        }
        return items
    }

    /// Opens the first website of a login in the browser.
    private func launch(_ item: VaultItemSummary) {
        Task {
            guard let website = try? await model.item(id: item.id).value(of: .website),
                  let url = LoginContent.launchURL(ofWebsite: website) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// emptyState$ in vault.component.ts.
    private var emptyState: some View {
        let (illustration, title, description): (Illustration.Name, String, String) =
            if !navigation.search.trimmingCharacters(in: .whitespaces).isEmpty {
                (.noResults, "noSearchResults", "clearFiltersOrTryAnother")
            } else {
                switch navigation.filter {
                case .trash: (.emptyTrash, "noItemsInTrash", "noItemsInTrashDesc")
                case .favorites: (.favorites, "emptyFavorites", "emptyFavoritesDesc")
                case .archive: (.itemTypes, "noItemsInArchive", "noItemsInArchiveDesc")
                default: (.itemTypes, "noItemsInVault", "emptyVaultDescription")
                }
            }
        // showAddCipherBtn: not for the trash, the favourites and the archive.
        let showsNewButton = ![VaultFilter.trash, .favorites, .archive].contains(navigation.filter)
        return StatusLockup(illustration: illustration, title: BWText[title], description: BWText[description]) {
            if showsNewButton {
                // vault-new-cipher-menu with buttonType "secondary" and no icon: "add item". It is the
                // menu of the strip at the top and opens there, so that one menu serves both.
                BWButton(BWText["addItem"], isBlock: false) { navigation.isNewMenuOpen = true }
            }
        }
    }
}
