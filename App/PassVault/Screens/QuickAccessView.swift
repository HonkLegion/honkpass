import DesignKit
import Engine
import SwiftUI
import VaultModel

/// A compact picker on one native glass surface. Search and ranking still come from the
/// existing model; the controller retains the fill and authorization flow.
struct QuickAccessView: View {
    struct Actions {
        let close: @MainActor () -> Void
        let showMainWindow: @MainActor () -> Void
        let openItem: @MainActor (String) -> Void
        /// Runs an action of an item in the main window, which has the form and the questions.
        let inMainWindow: @MainActor (@escaping @MainActor (ItemActions) -> Void) -> Void
        /// Fills the field of the app in front with a field of an item. The panel closes for it.
        let fill: @MainActor (ItemField, VaultItemSummary) -> Void
        /// A key of the panel: an arrow, Return or Escape. false while a menu or a question has the keyboard.
        let key: @MainActor (QuickAccessPanelController.Key) -> Bool
        /// "Fill" of a row: its one field, or the menu of its fields.
        let chooseFill: @MainActor (QuickAccessSection.Row) -> Void
        /// A field to fill was chosen.
        let requestFill: @MainActor (ItemField, VaultItemSummary) -> Void
        /// The answer to the question before a fill.
        let answerFill: @MainActor (QuickAccessState.FillAnswer) -> Void
        /// Opens the locked vault with Touch ID, here in the panel.
        let unlockWithTouchID: @MainActor () -> Void
        let resize: @MainActor (CGFloat) -> Void
    }

    let model: AppModel
    @Bindable var state: QuickAccessState
    @Bindable var navigation: VaultNavigation
    let actions: Actions

    /// The row the pointer is over: it shows "fill", as the row the keyboard is on.
    @State private var hoveredRowID: String?

    /// A menu of a row is open, or a question: they have the keyboard.
    private var isBusy: Bool {
        navigation.openMenuItemID != nil || navigation.openCopyMenuItemID != nil || navigation.protectedAction != nil
            || state.fillMenuRowID != nil || state.pendingFill != nil
    }

    private var rows: [QuickAccessSection.Row] {
        model.state.vault.quickAccessRows(search: state.search, page: state.target?.website, app: state.target?.app)
    }
    var body: some View {
        if state.isPresented {
            let rows = rows
            presentedContent(rows: rows)
        }
    }

    private func desiredHeight(rowCount: Int) -> CGFloat {
        QuickAccessStyle.panelHeight(rowCount: rowCount, isUnlocked: model.state.session.isUnlocked,
                                    showsQuestion: state.pendingFill != nil || navigation.protectedAction != nil)
    }

    private func presentedContent(rows: [QuickAccessSection.Row]) -> some View {
        return Group {
            switch model.state.session {
            case .unlocked:
                vault(rows: rows)
            case .locked(let account):
                // Touch ID opens the vault here: it needs nothing typed. The master password and
                // the PIN are on the lock screen of the main window.
                StatusLockup(illustration: .gooseKey, title: BWText["yourVaultIsLockedV2"], description: account.email) {
                    if model.state.biometrics.canUnlock {
                        VStack(spacing: Metric.space(2)) {
                            BWButton(BWText["unlockWithTouchId"], kind: .primary, isBlock: false, action: actions.unlockWithTouchID)
                                .disabled(state.isAskingForTouchID || model.state.activity != nil)
                            BWButton(BWText["unlock"], isBlock: false, action: actions.showMainWindow)
                        }
                    } else {
                        BWButton(BWText["unlock"], kind: .primary, isBlock: false, action: actions.showMainWindow)
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if model.state.activity == .unlocking {
                        LoginProgressScreen(phase: model.state.authenticationPhase ?? .authenticating)
                    }
                }
            case .loggedOut:
                StatusLockup(illustration: .gooseKey, title: BWText["loggedOut"], description: BWText["loginPageEmailEntryScreenTitle"]) {
                    BWButton(BWText["logIn"], kind: .primary, isBlock: false, action: actions.showMainWindow)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The nonactivating panel can have the keyboard while another app stays active.
        .environment(\.controlActiveState, state.hasKeyboard ? .key : .inactive)
        .bwMenuHost(usesNativeGlass: true)
        // The master password of an item that asks for it, before a protected field is copied.
        .overlay {
            if navigation.protectedAction != nil, model.state.session.isUnlocked {
                MasterPasswordPrompt(model: model, navigation: navigation)
            }
        }
        // "Confirm autofill", before a value leaves for the app in front.
        .overlay {
            if let pending = state.pendingFill, model.state.session.isUnlocked {
                fillQuestion(pending)
            }
        }
        // "value copied", as the popup says it.
        .overlay(alignment: .top) {
            ToastStack(center: navigation.toasts)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metric.quickAccessCornerRadius))
        .ignoresSafeArea()
        // A closed menu or question gives the keyboard back to the search field.
        .onChange(of: isBusy) { _, isBusy in
            if !isBusy { state.focusRequest += 1 }
        }
        .onChange(of: desiredHeight(rowCount: rows.count), initial: true) { _, height in actions.resize(height) }
        // The keys of the panel are the controller's, which also gets them when no view has the keyboard.
        .onKeyPress(.downArrow) { actions.key(.down) ? .handled : .ignored }
        .onKeyPress(.upArrow) { actions.key(.up) ? .handled : .ignored }
        .onKeyPress(.return) { actions.key(.enter) ? .handled : .ignored }
        .onKeyPress(.escape) { actions.key(.escape) ? .handled : .ignored }
    }

    private func vault(rows: [QuickAccessSection.Row]) -> some View {
        // Compute the list and selection once, not again for every row and its buttons.
        let selected = rows.first { $0.id == state.selectedRowID } ?? rows.first
        // A scene or an already-open menu can address another row. Keep its anchor alive.
        let actionRow = rows.first { $0.id == navigation.openMenuItemID || $0.id == navigation.openCopyMenuItemID } ?? selected
        return VStack(spacing: 0) {
            QuickAccessSearchField(text: $state.search, focusRequest: state.focusRequest)
            targetContext
            if rows.isEmpty {
                // vaultState Empty and NoResults
                let isSearch = !state.search.trimmingCharacters(in: .whitespaces).isEmpty
                StatusLockup(illustration: isSearch ? .noResults : .vault,
                             title: BWText[isSearch ? "noItemsMatchSearch" : "yourVaultIsEmpty"],
                             description: BWText[isSearch ? "clearFiltersOrTryAnother" : "emptyVaultDescription"]) { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                BWScrollView(scrollTarget: selected.map { BWScrollTarget(id: $0.id) }) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            resultRow(row, isSelected: row.id == selected?.id)
                                .onHover { hoveredRowID = $0 ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID) }
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .clipped()
            }
            footer(actionRow, count: rows.count)
        }
    }

    private var targetContext: some View {
        HStack(spacing: 8) {
            if let target = state.target {
                Image(systemName: "macwindow").accessibilityHidden(true)
                Text(BWText["honkpassQuickFillTarget", target.appName])
                    .lineLimit(1)
                    .help(target.appName)
                Spacer(minLength: 16)
                if let website = target.website {
                    Text(URL(string: website)?.host() ?? website)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(website)
                }
            } else {
                Text(BWText["honkpassQuickAccess"])
                Spacer()
            }
        }
        .font(QuickAccessStyle.subtitle)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metric.quickAccessInset)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, Metric.quickAccessInset) }
    }

    private func subtitle(_ item: VaultItemSummary) -> String {
        guard !model.state.vault.organizations.isEmpty else { return item.subtitle }
        let owner = item.organizationID == nil ? BWText["myVault"]
            : (model.state.vault.organizationName(of: item) ?? BWText["organization"])
        return item.subtitle.isEmpty ? "(\(owner))" : "\(item.subtitle) (\(owner))"
    }

    private func resultRow(_ row: QuickAccessSection.Row, isSelected: Bool) -> some View {
        let item = row.item
        let fields = QuickAccessState.fillFields(of: item)
        let active = isSelected || hoveredRowID == row.id || state.fillMenuRowID == row.id
        let canFill = !fields.isEmpty
        let returnFills = state.fillsLoginForm(with: item) || (state.target?.takesValue == true && canFill)
        return HStack(spacing: 16) {
            Button {
                state.selectedRowID = row.id
            } label: {
                HStack(spacing: 12) {
                    ItemRowIcon(model: model, item: item)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(QuickAccessStyle.title).foregroundStyle(.primary)
                            .lineLimit(1).help(item.name)
                        let subtitle = subtitle(item)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(QuickAccessStyle.subtitle).foregroundStyle(.secondary)
                                .lineLimit(1).help(subtitle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button {
                state.selectedRowID = row.id
                if canFill { actions.chooseFill(row) } else { actions.openItem(item.id) }
            } label: {
                HStack(spacing: 8) {
                    Text(BWText[canFill ? "fill" : "view"])
                    if isSelected, canFill == returnFills { Image(systemName: "return").accessibilityHidden(true) }
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .bwMenu(isOpen: Binding(get: { state.fillMenuRowID == row.id },
                                    set: { if !$0 { state.fillMenuRowID = nil } })) {
                fields.map { field in
                    BWMenuItem(BWText[ItemCopier.toastKey(for: field)]) { actions.requestFill(field, item) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metric.quickAccessRowHeight)
        .background(RoundedRectangle(cornerRadius: Metric.quickAccessRowRadius)
            .fill(isSelected ? QuickAccessStyle.selection : (hoveredRowID == row.id ? QuickAccessStyle.hover : .clear)))
    }

    private func footer(_ row: QuickAccessSection.Row?, count: Int) -> some View {
        HStack(spacing: 16) {
            Text(BWText["honkpassQuickItemCount", "\(count)"])
            Spacer(minLength: 8)
            Text(BWText["honkpassQuickChoose"])
            if let row {
                if row.item.type == .login, row.item.fields.contains(.website) {
                    BWIconButton(.externalLink, label: BWText["launchWebsite"], size: .small) {
                        ItemCopier(model: model, navigation: navigation).launch(row.item)
                    }
                }
                ItemCopyActions(model: model, navigation: navigation, item: row.item, showsQuickCopy: false, menuID: row.id)
                BWIconButton(.ellipsisV, label: BWText["moreOptions"], size: .small) { navigation.openMenuItemID = row.id }
                    .bwMenu(isOpen: Binding(get: { navigation.openMenuItemID == row.id },
                                            set: { if !$0 { navigation.openMenuItemID = nil } })) { moreOptions(row.item) }
            }
            Button(action: actions.close) { Text("esc  " + BWText["close"]) }
                .buttonStyle(.plain)
        }
        .font(QuickAccessStyle.caption)
        .foregroundStyle(.secondary)
        .environment(\.iconButtonGlyphSize, Metric.vaultActionIconSize)
        .environment(\.iconButtonHoverSize, Metric.vaultActionHoverSize)
        .padding(.horizontal, Metric.quickAccessInset)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    /// The `bit-menu` of item-more-options.component.html for an item of the personal vault. The
    /// favourite mark changes here; the form and the questions of the other items are in the
    /// main window, which comes forward for them.
    private func moreOptions(_ item: VaultItemSummary) -> [BWMenuItem] {
        [
            BWMenuItem(BWText[item.isFavorite ? "unfavorite" : "favorite"]) {
                ItemActions(model: model, navigation: navigation).toggleFavorite(item)
            },
            BWMenuItem(BWText["edit"]) { actions.inMainWindow { $0.edit(item) } },
            BWMenuItem(BWText["clone"]) { actions.inMainWindow { $0.clone(item) } },
            BWMenuItem(BWText["archiveVerb"]) { actions.inMainWindow { $0.archive(item) } },
            BWMenuItem(BWText["delete"], kind: .danger) { actions.inMainWindow { $0.delete(item) } },
        ]
    }

    // MARK: Fill

    /// The question before a fill into a page that is not one of the login: the dialog of the
    /// popup (apps/browser/src/vault/popup/components/vault/autofill-confirmation-dialog). It
    /// names the websites the login has and the page in front, and offers "autofill and save this
    /// site", "autofill only" and "cancel". Here it is asked for an app that is no browser too:
    /// the app is named in place of a page, and there is no website to save. Its keys are the
    /// controller's: the arrows move over the answers, Return takes the marked one, Escape cancels.
    private func fillQuestion(_ pending: QuickAccessState.PendingFill) -> some View {
        let page = state.target?.website
        let isApp = page == nil
        // The address of an app is kept among the websites and is none.
        let saved = pending.item.websites.filter { !$0.address.isEmpty && $0.app == nil }
        // `FULL_URI_MATCH_STRATEGIES`: with such a rule the whole addresses are shown, else the hosts.
        let showsWhole = saved.contains { [.startsWith, .regularExpression, .exact].contains($0.match) }
        func shown(_ address: String) -> String {
            showsWhole ? address : (URL(string: address)?.host() ?? VaultItemSummary.websiteHost(of: address) ?? address)
        }
        let neverMatches = page.map { page in saved.contains { $0.match == .never && shown($0.address) == shown(page) } } ?? false
        let title = isApp ? "honkpassConfirmAppFill" : (neverMatches ? "loginNeverMatchTitle" : (saved.isEmpty ? "loginHasNoSiteSaved" : "siteDoesntMatch"))
        let text = isApp ? "honkpassConfirmAppFillDescription" : (saved.isEmpty ? "loginNoSiteDesc"
            : (neverMatches ? "loginNeverMatchDesc" : (saved.count == 1 ? "loginSingleSiteDesc" : "loginMultipleSitesDesc"))
        )
        let answers = state.fillAnswers
        return BWDialog(title: BWText[title], onClose: { actions.answerFill(.cancel) }) {
            VStack(alignment: .leading, spacing: 0) {
                // p bitTypography="body2"
                Text(isApp ? BWText["honkpassConfirmAppFillDescription", pending.item.name] : BWText[text])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMain))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isApp, !saved.isEmpty {
                    siteLabel(saved.count == 1 ? BWText["savedWebsite"] : BWText.text("savedWebsites", ["\(saved.count)"]))
                        .padding(.top, Metric.space(4))
                    ForEach(Array(saved.prefix(3).enumerated()), id: \.offset) { _, website in
                        BWStatusCallout(shown(website.address), kind: .success, icon: .globe)
                            .padding(.bottom, -Metric.space(2))
                    }
                    Color.clear.frame(height: Metric.space(2))
                }
                siteLabel(BWText[isApp ? "honkpassCurrentApp" : "currentWebsite"])
                    .padding(.top, saved.isEmpty ? Metric.space(5) : Metric.space(3))
                BWStatusCallout(page.map(shown) ?? state.target?.appName ?? "", kind: neverMatches ? .success : .warning, icon: isApp ? .desktop : .globe)
                if isApp, let app = state.target?.app {
                    Text(app.address).textStyle(.xs).foregroundStyle(.theme(.textMuted))
                        .textSelection(.enabled)
                }
                // "tw-flex tw-justify-center tw-flex-col tw-gap-3 tw-mt-6"
                VStack(spacing: Metric.space(3)) {
                    if answers.contains(.saveAndFill) {
                        answerButton(BWText["autofillAndSaveThisSite"], .saveAndFill, kind: .primary)
                    }
                    if answers.contains(.saveAppAndFill) {
                        answerButton(BWText["honkpassFillAndSaveApp"], .saveAppAndFill, kind: .primary)
                    }
                    answerButton(BWText[answers.contains(.saveAndFill) || answers.contains(.saveAppAndFill) ? "autofillOnly" : "autofillVerb"], .fill, kind: .secondary)
                    BWLink(BWText["cancel"], size: TextStyle.sm.size, weight: 500, colour: .textMain) { actions.answerFill(.cancel) }
                        .padding(.top, Metric.space(2))
                        .overlay(alignment: .bottom) {
                            if state.markedFillAnswer == .cancel { Rectangle().fill(.theme(.borderFocus)).frame(height: 1) }
                        }
                }
                .padding(.top, Metric.space(2))
            }
        } footer: {
            EmptyView()
        }
    }

    /// p "tw-text-muted tw-text-xs tw-uppercase tw-font-medium"
    private func siteLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .textStyle(.xs.weight(500))
            .foregroundStyle(.theme(.textMuted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Metric.space(2))
    }

    /// A button of the question. The one the keyboard is on has the ring of the focus.
    private func answerButton(_ title: String, _ answer: QuickAccessState.FillAnswer, kind: BWButton.Kind) -> some View {
        return BWButton(title, kind: kind) { actions.answerFill(answer) }
            .overlay(BWControlShape()
                .strokeBorder(.theme(state.markedFillAnswer == answer ? .borderFocus : .clear), lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false))
    }
}
