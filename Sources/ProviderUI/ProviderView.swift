import DesignKit
import SwiftUI
import VaultModel

/// AutoFill shares the editor's title, controls and scroll edges. The system owns its window.
public struct ProviderView: View {
    @Bindable private var model: ProviderModel
    @State private var showsPin = false
    @State private var focusRequest = 0
    @State private var isAtTop = true
    @State private var headerHeight = Metric.panelHeaderHeight
    @State private var searchHeight = Metric.space(18)
    @FocusState private var isPinFocused: Bool

    public init(model: ProviderModel) {
        self.model = model
    }

    public var body: some View {
        content
            .padding(.top, scrollsUnderHeader ? 0 : headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.theme(.bgTertiary))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ProviderHeader(title: BWText[titleKey], close: model.cancel)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    if hasSearch {
                        BWSearchField(text: $model.search, placeholder: BWText["search"], takesFocus: true, focusRequest: focusRequest)
                            .padding(.horizontal, Metric.space(4))
                            .padding(.bottom, Metric.space(3))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchHeight = $0 }
                    }
                    Color.clear.frame(height: Metric.headerFadeHeight).allowsHitTesting(false)
                }
                .background {
                    BWLayeredHeaderBackground(background: .bgTertiary, isAtTop: isAtTop, headerHeight: topInset)
                }
            }
            .onChange(of: model.screen) { isAtTop = true }
        // "Overwrite passkey?", the question of fido2-create before a passkey is replaced.
        .overlay {
            if model.overwriting != nil {
                BWSimpleDialog(kind: .warning, title: BWText["overwritePasskey2"], text: BWText["alreadyContainsPasskey"],
                               onAnswer: model.answerOverwrite)
            }
        }
        .onKeyPress(.downArrow) { key { model.move(1) } }
        .onKeyPress(.upArrow) { key { model.move(-1) } }
        .onKeyPress(.return) { key(model.chooseSelected) }
        .onKeyPress(.escape) {
            model.cancel()
            return .handled
        }
        .onExitCommand(perform: model.cancel)
        .onAppear(perform: model.start)
    }

    private var hasSearch: Bool {
        if case .list = model.screen { return true }
        return false
    }

    private var topInset: CGFloat { headerHeight + (hasSearch ? searchHeight : 0) }

    private var scrollsUnderHeader: Bool {
        switch model.screen {
        case .list, .passkeys: true
        case .passkeyTargets: !model.targets.isEmpty
        default: false
        }
    }

    /// A key of a list. The other screens keep their keys, and so does an open question.
    private func key(_ action: () -> Void) -> KeyPress.Result {
        guard model.overwriting == nil else { return .ignored }
        switch model.screen {
        case .list, .passkeys, .passkeyTargets:
            action()
            return .handled
        default:
            return .ignored
        }
    }

    /// The titles of the reference's windows for passkeys; the list of logins is PassVault's own.
    private var titleKey: String {
        switch model.request {
        case .chooseLogin, .login: "autofillNoun"
        case .choosePasskey, .passkey: "passkeyLogin2"
        case .newPasskey: "savePasskey"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .loading:
            // The reference draws nothing until its list is there.
            Color.clear
        case .unavailable:
            StatusLockup(illustration: .gooseKey, title: BWText["honkpassAutoFillUnavailable"],
                         description: BWText["honkpassAutoFillUnavailableDescription"]) {
                BWButton(BWText["honkpassOpenMainWindow"], kind: .primary, isBlock: false, action: model.openApp)
            }
        case .loggedOut:
            StatusLockup(illustration: .gooseKey, title: BWText["loggedOut"],
                         description: model.problem == .tooManyWrongPins ? BWText["tooManyInvalidPinEntryAttemptsLoggingOut"]
                             : BWText["loginPageEmailEntryScreenTitle"]) {
                BWButton(BWText["logIn"], kind: .primary, isBlock: false, action: model.openApp)
            }
        case .locked(let account, withPin: true, let withTouchID):
            pinForm(account: account, withTouchID: withTouchID)
        case .locked(let account, withPin: false, withTouchID: true):
            // Touch ID opens the vault from here; the other ways are in the app.
            StatusLockup(illustration: .gooseKey, title: BWText["yourVaultIsLockedV2"], description: touchIDProblem ?? account ?? "") {
                VStack(spacing: Metric.space(2)) {
                    touchIDButton(kind: .primary, isBlock: false)
                    BWButton(BWText["unlock"], isBlock: false, action: model.openApp)
                }
            }
        case .locked(let account, withPin: false, withTouchID: false):
            // Without a PIN the app unlocks: the button brings it to the front.
            StatusLockup(illustration: .gooseKey, title: BWText["yourVaultIsLockedV2"], description: touchIDProblem ?? account ?? "") {
                BWButton(BWText["unlock"], kind: .primary, isBlock: false, action: model.openApp)
            }
        case .list:
            list
        case .passkeys:
            passkeyList
        case .noPasskeys:
            StatusLockup(illustration: .noResults, title: BWText["noPasskeysFoundForThisApplication"], description: "") {
                BWButton(BWText["close"], kind: .primary, isBlock: false, action: model.closeNotice)
            }
        case .passkeyTargets:
            targetList
        case .passkeyExists:
            // fido2-excluded-ciphers.component.html
            StatusLockup(illustration: .noResults, title: BWText["passkeyAlreadyExists"],
                         description: BWText["applicationDoesNotSupportDuplicates"]) {
                BWButton(BWText["close"], kind: .primary, isBlock: false, action: model.closeNotice)
            }
        }
    }

    // MARK: Passkeys

    /// fido2-vault.component.html: the logins that have a passkey of the website, each with the
    /// badge "select".
    private var passkeyList: some View {
        let selectedID = model.selectedRowID
        return BWScrollView(scrollTarget: selectedID.map { BWScrollTarget(id: $0) }, topInset: topInset,
                            onScroll: { isAtTop = $0.isAtTop }) {
            LazyVStack(spacing: 0) {
                // bit-section-header: h2 bitTypography="h6", while there is a passkey to choose.
                if !model.passkeys.isEmpty { BWSectionHeader(BWText["chooseCipherForPasskeyAuth"]) }
                ForEach(model.passkeys) { passkey in
                    row(passkey.name, passkey.username, badge: "select", id: passkey.id,
                        isProtected: passkey.asksForMasterPassword, selectedID: selectedID) {
                        model.choose(passkey)
                    }
                }
            }
            // bit-section "tw-p-4"
            .padding(Metric.space(4))
        }
    }

    /// fido2-create.component.html: the logins of the website, each with the badge "save", and
    /// the row "save as new login" after them. Without a login of the website the window says
    /// so and has the one button that saves the passkey as a new login.
    @ViewBuilder private var targetList: some View {
        if model.targets.isEmpty {
            StatusLockup(illustration: .gooseKey, title: BWText["noMatchingLoginsForSite"], description: registrationContext) {
                BWButton(BWText["savePasskeyNewLogin"], kind: .primary, isBlock: false) { model.save(into: nil) }
            }
        } else {
            targetRows
        }
    }

    private var registrationContext: String {
        guard case .newPasskey(let request) = model.request else { return "" }
        return [request.rpID, request.userName].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var targetRows: some View {
        let selectedID = model.selectedRowID
        return BWScrollView(scrollTarget: selectedID.map { BWScrollTarget(id: $0) }, topInset: topInset,
                            onScroll: { isAtTop = $0.isAtTop }) {
            LazyVStack(spacing: 0) {
                BWSectionHeader(BWText["chooseCipherForPasskeySave"])
                ForEach(model.targets) { login in
                    row(login.name, login.username, badge: "save", id: login.itemID,
                        isProtected: login.asksForMasterPassword, selectedID: selectedID) {
                        model.save(into: login)
                    }
                }
                BWItem(BWText["saveNewPasskey"], isFocused: selectedID == ProviderModel.newLoginRow, isBrand: true) {
                    model.save(into: nil)
                } start: {
                    EmptyView()
                }
                .id(ProviderModel.newLoginRow)
            }
            .padding(Metric.space(4))
        }
    }

    /// bit-item with app-vault-icon, the name, the subtitle and a badge at the end. The
    /// extension asks no server for the icon of a website: every login has the globe.
    private func row(_ name: String, _ username: String, badge: String, id: String, isProtected: Bool,
                     selectedID: String?,
                     action: @escaping () -> Void) -> some View {
        BWItem(name, secondary: username.isEmpty ? nil : username, height: 52, isFocused: id == selectedID,
               truncates: true, action: action) {
            IconView(.globe, size: TextStyle.body.size * 4 / 3)
                .foregroundStyle(.theme(.textMuted))
                .frame(width: Metric.space(7), alignment: .leading)
        } end: {
            if !isProtected {
                BWBadge(BWText[badge])
                    .padding(.trailing, Metric.space(3))
                    .allowsHitTesting(false)
            }
        }
        // A login that asks for the master password again is used from the app only.
        .disabled(isProtected)
        .opacity(isProtected ? 0.5 : 1)
        .id(id)
    }

    // MARK: The locked vault

    /// The PIN form of the lock screen (libs/key-management-ui/src/lock/components/lock.component.html):
    /// the field "PIN" and the button "unlock" under the title and the account.
    private func pinForm(account: String?, withTouchID: Bool) -> some View {
        VStack(spacing: 0) {
            Text(BWText["yourVaultIsLockedV2"])
                .textStyle(.h4.weight(600))
                .foregroundStyle(.theme(.fgHeading))
            Text(account ?? "")
                .textStyle(.sm)
                .foregroundStyle(.theme(.fgBody))
                .padding(.top, Metric.space(1))
                .padding(.bottom, Metric.space(5))
            // input type="password" class="tw-font-mono" required
            BWFormField(BWText["pin"], isRequired: true, isFocused: isPinFocused, error: pinProblem) {
                BWTextInput(text: $model.pin, isSecure: !showsPin, isMonospaced: true)
                    .focused($isPinFocused)
                    .onSubmit(model.submitPin)
            } suffix: {
                BWIconButton(showsPin ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                    showsPin.toggle()
                    isPinFocused = true
                }
            }
            BWButton(BWText["unlock"], kind: .primary, action: model.submitPin)
                .disabled(model.isBusy)
            if withTouchID {
                // The form of the PIN on the lock screen: "or", then the button of Touch ID.
                Text(BWText["or"]).textStyle(.body).padding(.vertical, Metric.space(3))
                touchIDButton(kind: .secondary, isBlock: true)
            }
            if let touchIDProblem {
                Text(touchIDProblem).textStyle(.sm).foregroundStyle(.theme(.fgDanger)).padding(.top, Metric.space(3))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 22 * Metric.rem)
        .padding(Metric.space(4))
        .onAppear { isPinFocused = true }
    }

    /// "Unlock with Touch ID": the app has the system ask.
    private func touchIDButton(kind: BWButton.Kind, isBlock: Bool) -> some View {
        BWButton(BWText["unlockWithTouchId"], kind: kind, isBlock: isBlock, action: model.unlockWithTouchID)
            .disabled(model.isBusy)
    }

    /// Touch ID did not open the vault: the text of the toast of the lock screen.
    private var touchIDProblem: String? {
        model.problem == .touchIDFailed ? BWText["couldNotCompleteBiometrics"] : nil
    }

    private var pinProblem: String? {
        switch model.problem {
        case .pinRequired: BWText["pinRequired"]
        case .wrongPin: BWText["invalidPin"]
        default: nil
        }
    }

    // MARK: The list

    private var list: some View {
        let sections = model.sections
        let selectedID = model.selectedRowID
        return VStack(spacing: 0) {
            if sections.isEmpty {
                StatusLockup(illustration: .noResults,
                             title: BWText[model.isSearching ? "noItemsMatchSearch" : "noItemsInList"],
                             description: model.isSearching ? BWText["clearFiltersOrTryAnother"] : "") { EmptyView() }
                    .frame(maxHeight: .infinity)
                    .padding(.top, topInset)
            } else {
                BWScrollView(scrollTarget: selectedID.map { BWScrollTarget(id: $0) }, topInset: topInset,
                             onScroll: { isAtTop = $0.isAtTop }) {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            rows(of: section, isLast: section.id == sections.last?.id, selectedID: selectedID)
                        }
                    }
                    .padding(.horizontal, Metric.space(4))
                    .padding(.top, Metric.space(4))
                    .padding(.bottom, Metric.space(4))
                }
            }
        }
    }

    /// app-vault-list-items-container of the popup: the header "tw-pl-1 tw-mb-0.5" with the title
    /// as h6 and the number of items at its end, then the rows; "tw-mb-5" between two lists.
    private func rows(of section: ProviderModel.Section, isLast: Bool, selectedID: String?) -> some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(BWText[Self.titleKey(section.kind)])
                    .textStyle(.sm.weight(500))
                    .foregroundStyle(.theme(.textMain))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Metric.space(2))
                Text("\(section.logins.count)")
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
            }
            .padding(.leading, Metric.space(1))
            .padding(Metric.space(0.5))
            .padding(.bottom, Metric.space(0.5) + Metric.space(1))
            ForEach(section.logins) { login in
                row(login.name, login.username, badge: "fill", id: login.itemID,
                    isProtected: login.asksForMasterPassword, selectedID: selectedID) {
                    model.choose(login)
                }
            }
        }
        .padding(.bottom, isLast ? 0 : Metric.space(5) - Metric.space(1.5))
    }

    private static func titleKey(_ kind: ProviderModel.Section.Kind) -> String {
        switch kind {
        case .suggestions: "autofillSuggestions"
        case .allItems: "allItems"
        case .searchResults: "searchResults"
        }
    }
}

/// One title and Close action, aligned with the editor's header.
public struct ProviderHeader: View {
    private let title: String
    private let close: () -> Void

    public init(title: String, close: @escaping () -> Void) {
        self.title = title
        self.close = close
    }

    public var body: some View {
        HStack(spacing: Metric.space(2)) {
            Text(title)
                .textStyle(.h3)
                .foregroundStyle(.theme(.textMain))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            BWIconButton(.close, label: BWText["close"], action: close)
        }
        .padding(.vertical, Metric.space(2))
        .padding(.horizontal, Metric.space(4))
        .frame(minHeight: Metric.panelHeaderHeight)
    }
}

/// What the extension shows when the user has turned it on in the settings of the system: the
/// message of the reference's extension ("autofillConfigurationMessage").
public struct ProviderConfigurationView: View {
    public init() {}

    public var body: some View {
        Text(BWText["autofillConfigurationMessage"])
            .textStyle(.base)
            .foregroundStyle(.theme(.textMain))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.theme(.bgTertiary))
    }
}
