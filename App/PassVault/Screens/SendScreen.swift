import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The Sends in the main area: the header with the button "new", the search and the table.
/// Source: apps/desktop/src/app/tools/send/send.component.html and, in libs/tools/send/send-ui,
/// send-list, send-search, send-table and new-send-dropdown-v2. The picture is
/// docs/reference/send-*.png, the list without a Send.
struct SendList: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation
    let account: Account
    let width: CGFloat

    private var all: [VaultSendSummary] { model.state.vault.sends }
    private var shown: [VaultSendSummary] {
        all.shown(type: navigation.sendFilter, search: navigation.sendSearch, sort: navigation.sendSort)
    }
    private var actions: SendActions { SendActions(model: model, navigation: navigation) }
    private var isSearching: Bool { !navigation.sendSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    /// div "tw-m-4 tw-p-4" around the header and the list.
    private static let margin = Metric.space(6)

    var body: some View {
        // "@lg/send-table:tw-table-cell tw-hidden": the dates show while the table is 32 rem wide.
        let showsDate = width - 2 * Self.margin >= 32 * Metric.rem
        let rows = shown
        let columns = columns(for: rows, showsDate: showsDate, in: width - 2 * Self.margin)
        return VStack(spacing: 0) {
            header
            // showSearchBar: hidden while there is no Send and nothing is searched for.
            if !all.isEmpty || isSearching {
                BWSearchField(text: $navigation.sendSearch, placeholder: BWText["search"], takesFocus: true,
                              focusRequest: navigation.searchFocusRequest)
                    .padding(.horizontal, Self.margin)
            }
            BWScrollView {
                LazyVStack(spacing: 0) {
                    tableHeader(columns)
                    Rectangle().fill(.theme(.borderBase)).frame(height: 2)
                    ForEach(rows) { send in
                        VStack(spacing: 0) {
                            row(send, columns)
                            if send.id != rows.last?.id { Rectangle().fill(.theme(.borderBase)).frame(height: 1) }
                        }
                    }
                    if rows.isEmpty { emptyState }
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.margin)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.theme(.bgPrimary))
    }

    /// The Sends use the same header height and horizontal inset as the vault list.
    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(BWText["send"])
                .textStyle(.h1)
                .foregroundStyle(.theme(.textMain))
            Spacer(minLength: Metric.space(2))
        }
        .padding(.horizontal, Self.margin)
        .frame(minHeight: Metric.panelHeaderHeight)
    }

    // MARK: Table

    /// The widths of the columns; `date` is nil while the dates do not show.
    private struct Columns {
        var name: CGFloat
        var date: CGFloat?
        var options: CGFloat
    }

    private static let cellPadding = 2 * Metric.space(3)
    private static let titleStyle = TextStyle.body.weight(500)
    /// A `th` without a class of its own is bold, as a browser draws it (measured in docs/reference/send-*.png).
    private static let optionsTitleStyle = TextStyle(size: TextStyle.body.size, lineHeight: TextStyle.base.lineHeight, weight: 700)
    /// "tw-ms-2" between the title of a column and its icon. The template of the Sends writes
    /// the title of the dates on a line of its own, which leaves a space before the icon; the
    /// title of the names has none.
    private static func titleIconGap(hasSpace: Bool) -> CGFloat {
        Metric.space(2) + (hasSpace ? 0.28 * TextStyle.body.size : 0)
    }
    private static let typeIcon = 1.25 * Metric.rem
    private static let markIcon = TextStyle.body.size

    /// bit-table lays its columns out by their content ("table-layout: auto"), so the widths
    /// come from the titles and the rows: without a Send the three titles share the table
    /// (docs/reference/send-*.png). The cell of the menu has "tw-w-0", which keeps its column
    /// as narrow as its title. A name that is too long is cut, where the reference breaks it.
    private func columns(for rows: [VaultSendSummary], showsDate: Bool, in width: CGFloat) -> Columns {
        func title(_ label: String, hasSpace: Bool) -> CGFloat {
            Self.cellPadding + 2 + Self.titleStyle.width(of: label) + Self.titleIconGap(hasSpace: hasSpace) + TextStyle.body.size
        }
        let now = Date()
        let nameStyle = TextStyle(size: TextStyle.body.size, lineHeight: TextStyle.body.size, weight: 600)
        let fixedNameParts = Self.cellPadding + Self.typeIcon + Metric.space(2)
        var name = BWTableLayout.Column(title(BWText["name"], hasSpace: false))
        var date = BWTableLayout.Column(title(BWText["deletionDate"], hasSpace: true))
        var options = BWTableLayout.Column(Self.cellPadding + Self.optionsTitleStyle.width(of: BWText["options"]))
        for send in rows {
            let marks = CGFloat(marks(of: send, at: now).count) * (Metric.space(2) + Self.markIcon)
            name.minimum = max(name.minimum, fixedNameParts + marks)
            name.maximum = max(name.maximum, fixedNameParts + nameStyle.width(of: send.name) + marks)
            if showsDate {
                let day = Self.cellPadding + TextStyle.sm.width(of: ItemPanel.medium(send.deletionDate))
                date = BWTableLayout.Column(max(date.maximum, day))
            }
            options = BWTableLayout.Column(max(options.maximum, Self.cellPadding + BWIconButton.Size.small.box), hasOwnWidth: true)
        }
        let widths = BWTableLayout.widths(of: showsDate ? [name, date, options] : [name, options], in: width)
        return Columns(name: widths[0], date: showsDate ? widths[1] : nil, options: widths[widths.count - 1])
    }

    private func tableHeader(_ columns: Columns) -> some View {
        HStack(spacing: 0) {
            sortableHeader(BWText["name"], .name, hasSpace: false)
                .frame(width: columns.name, alignment: .leading)
            if let date = columns.date {
                sortableHeader(BWText["deletionDate"], .deletionDate, hasSpace: true)
                    .frame(width: date, alignment: .leading)
            }
            Text(BWText["options"])
                .lineLimit(1)
                .textStyle(Self.optionsTitleStyle)
                .padding(Metric.space(3))
                .frame(width: columns.options, alignment: .leading)
        }
        .foregroundStyle(.theme(.textMuted))
        .frame(height: 43.5)
    }

    /// bitSortable, as in the table of the vault; the list starts sorted by name.
    private func sortableHeader(_ label: String, _ column: SendSort.Column, hasSpace: Bool) -> some View {
        let isActive = navigation.sendSort.column == column
        return Button {
            navigation.sendSort = SendSort(column: column, isAscending: isActive ? !navigation.sendSort.isAscending : true)
        } label: {
            HStack(spacing: Self.titleIconGap(hasSpace: hasSpace)) {
                Text(label).lineLimit(1).textStyle(Self.titleStyle)
                IconView(isActive ? (navigation.sendSort.isAscending ? .upSolid : .downSolid) : .upDownBtn, size: TextStyle.body.size)
            }
            .fixedSize()
            .padding(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .padding(Metric.space(3))
    }

    /// tr bitRow: the icon of the type, the name as a link, the marks of the Send, its day of
    /// deletion and the menu. A click on the name or the day opens the Send.
    private func row(_ send: VaultSendSummary, _ columns: Columns) -> some View {
        let now = Date()
        return HStack(spacing: 0) {
            // td: div "tw-flex tw-gap-2 tw-items-center"
            HStack(spacing: Metric.space(2)) {
                // bit-icon "bwi-lg tw-text-muted"
                IconView(send.type == .file ? .file : .fileText, size: Self.typeIcon)
                    .foregroundStyle(.theme(.textMuted))
                BWLink(send.name) { actions.open(send) }
                    .accessibilityLabel(([send.name] + marks(of: send, at: now).map(\.text)).joined(separator: ", "))
                ForEach(marks(of: send, at: now), id: \.text) { mark in
                    IconView(mark.icon, size: Self.markIcon)
                        .foregroundStyle(.theme(.textMain))
                        .help(mark.text)
                }
            }
            .padding(Metric.space(3))
            .frame(width: columns.name, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { actions.open(send) }
            if let date = columns.date {
                // small bitTypography="body2" in a "tw-text-muted" cell
                Text(ItemPanel.medium(send.deletionDate))
                    .lineLimit(1)
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
                    .padding(Metric.space(3))
                    .frame(width: date, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.open(send) }
            }
            // td "tw-w-0 tw-text-right"
            BWIconButton(.ellipsisV, label: BWText["options"], size: .small) { navigation.openSendMenuID = send.id }
                .bwMenu(isOpen: Binding(get: { navigation.openSendMenuID == send.id },
                                        set: { if !$0 { navigation.openSendMenuID = nil } })) { menuItems(send) }
                .padding(Metric.space(3))
                .frame(width: columns.options, alignment: .trailing)
        }
    }

    /// The icons after the name, each with the text of its tooltip.
    private func marks(of send: VaultSendSummary, at time: Date) -> [(icon: BWIcon, text: String)] {
        var marks: [(icon: BWIcon, text: String)] = []
        if send.hasPassword { marks.append((.lock, BWText["passwordProtected"])) }
        if send.isDisabled { marks.append((.exclamationTriangle, BWText["sendNotCompliantWithYourOrgsPolicy"])) }
        if send.isExpired(at: time) { marks.append((.clock, BWText["expired"])) }
        if send.isMaxAccessCountReached { marks.append((.exclamationTriangle, BWText["maxAccessCountReached"])) }
        if send.isPendingDeletion(at: time) { marks.append((.trash, BWText["pendingDeletion"])) }
        return marks
    }

    private func menuItems(_ send: VaultSendSummary) -> [BWMenuItem] {
        var items = [BWMenuItem(BWText["copySendLink"], icon: .clone) { actions.copyLink(of: send.id) }]
        if send.hasPassword {
            items.append(BWMenuItem(BWText["removePassword"], icon: .close) { actions.removePassword(of: send.id) })
        }
        items.append(BWMenuItem(BWText["delete"], icon: .trash, kind: .danger, iconPlace: .startSlot) { actions.delete(send.id) })
        return items
    }

    /// send-list.component.html: nothing found by the search, or no Send of the type or at all.
    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            StatusLockup(illustration: .noSend, title: BWText["sendsTitleNoSearchResults"],
                         description: BWText["sendsBodyNoSearchResults"]) { EmptyView() }
        } else {
            StatusLockup(illustration: .noSend, title: BWText["sendsTitleNoItems"], description: BWText["sendsBodyNoItems"]) {
                // tools-new-send-dropdown-v2 with buttonType "secondary": "create Send". It is the menu
                // of the strip at the top and opens there, so that one menu serves both.
                BWButton(BWText["createSendV2"], isBlock: false) { navigation.isNewSendMenuOpen = true }
            }
        }
    }
}
