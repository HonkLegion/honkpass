import DesignKit
import Engine
import SwiftUI
import UniformTypeIdentifiers
import VaultModel

/// The form of an item in the panel beside the list: a new item, a copy or the change of one.
/// Source: libs/vault/src/vault-item-dialog (the frame and its footer) and libs/vault/src/cipher-form
/// (the sections). No reference pictures yet (docs/reference/README.md, "Still to take").
///
/// The passkey row comes with passkeys (PLAN.md).
struct ItemFormPanel: View {
    let model: AppModel
    let navigation: VaultNavigation
    @Bindable var form: ItemForm
    @FocusState private var focus: String?
    @State private var revealedField: UUID?

    var body: some View {
        // The cross asks before it throws changes away; "cancel" is the answer already.
        BWDrawer(title: title, startsAtEnd: navigation.itemPanelStartsAtEnd,
                 floatingFooter: true, fadingHeader: true, headerBackground: .bgTertiary, layeredHeader: true,
                 onClose: { navigation.leaveForm { navigation.itemForm = nil } }) {
            VStack(alignment: .leading, spacing: 0) {
                itemDetails
                switch form.draft.content {
                case .login:
                    loginDetails
                    websites
                    if !form.appRows.isEmpty { apps }
                case .card:
                    cardDetails
                case .identity:
                    identityDetails
                case .sshKey(let key):
                    sshKey(key)
                case .secureNote:
                    EmptyView()
                }
                additionalOptions
                if !form.fieldIDs.isEmpty || form.removedField != nil { customFields }
                // "Attachments are only available for existing ciphers": bit-item with an arrow.
                if form.mode == .edit, let id = form.draft.id {
                    BWItem(BWText["attachments"]) { navigation.attachmentsItemID = id } start: { EmptyView() }
                        .contentEnd(.angleRight)
                }
            }
            // Return in a field submits the form, as in the reference.
            .onSubmit(save)
        } footer: {
            footer
        }
        .onAppear { if form.mode != .edit { focus = "name" } }
    }

    /// `updateTitle` of vault-item-dialog.component.ts.
    private var title: String {
        let isEdit = form.mode == .edit
        return switch form.draft.type {
        case .login: BWText[isEdit ? "editItemHeaderLoginSentenceCase" : "addItemHeaderLogin"]
        case .card: BWText[isEdit ? "editItemHeaderCardSentenceCase" : "addItemHeaderCard"]
        case .identity: BWText[isEdit ? "editItemHeaderIdentitySentenceCase" : "addItemHeaderIdentity"]
        case .secureNote: BWText[isEdit ? "editItemHeaderNoteSentenceCase" : "addItemHeaderNote"]
        case .sshKey: BWText[isEdit ? "editItemHeaderSshKey" : "addItemHeaderSshKey"]
        }
    }

    // MARK: Building blocks

    /// One `section` of the form: "tw-mb-5", a title over a card.
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(title)
            BWCard { VStack(alignment: .leading, spacing: 0, content: content) }
        }
        .padding(.bottom, Metric.space(5))
    }

    /// A text field of the form. A hidden one has "tw-font-mono" and the button that shows it.
    @ViewBuilder
    private func input(_ label: String, _ key: String, _ text: Binding<String>, isRequired: Bool = false, error: String? = nil,
                       isHidden: Bool = false, isLast: Bool = false, help: BWHelp? = nil) -> some View {
        let margin = isLast ? 0 : Metric.space(4)
        if isHidden {
            BWFormField(label, isFocused: focus == key, bottomMargin: margin, help: help) {
                BWTextInput(text: text, isSecure: !form.revealed.contains(key), isMonospaced: true)
                    .focused($focus, equals: key)
            } suffix: {
                revealButton(key)
            }
        } else {
            BWFormField(label, isRequired: isRequired, isFocused: focus == key, error: error, bottomMargin: margin) {
                BWTextInput(text: text).focused($focus, equals: key)
            }
        }
    }

    /// `bitPasswordInputToggle`
    private func revealButton(_ key: String) -> some View {
        let isRevealed = form.revealed.contains(key)
        return BWIconButton(isRevealed ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
            if isRevealed { form.revealed.remove(key) } else { form.revealed.insert(key) }
        }
    }

    /// A value the form stores as nothing when it is empty.
    private func text(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// "-- Select --", the first option of the selects that may stay empty.
    private var noChoice: String { "-- " + BWText["select"] + " --" }

    // MARK: Item details

    /// item-details-section: the favourite button at the end of the title, then the name and the folder.
    private var itemDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            // bit-section-header: "tw-flex tw-justify-between tw-items-end tw-gap-1 tw-px-1 tw-pb-1"
            HStack(alignment: .bottom, spacing: Metric.space(1)) {
                Text(BWText["itemDetails"])
                    .textStyle(.sm.weight(500))
                    .foregroundStyle(.theme(.textMain))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                BWIconButton(form.draft.isFavorite ? .starF : .star, label: BWText["favorite"], size: .small) {
                    form.draft.isFavorite.toggle()
                }
            }
            .padding(.horizontal, Metric.space(1))
            .padding(.bottom, Metric.space(1))
            BWCard {
                VStack(alignment: .leading, spacing: 0) {
                    input(BWText["itemName"], "name", $form.draft.name, isRequired: true,
                          error: form.showsNameError && isNameMissing ? BWText["inputRequired"] : nil)
                    let organizations = model.state.vault.organizations
                    // The owner of a new item, while the account has an organization; an item of
                    // the vault stays where it is ("assign to collections" moves it).
                    let showsOwner = form.mode != .edit && !organizations.isEmpty
                    BWSelect(BWText["folder"], selection: $form.draft.folderID, options: folderOptions,
                             bottomMargin: showsOwner ? Metric.space(4) : 0)
                    if showsOwner {
                        let owner = Binding(get: { form.draft.organizationID }, set: { id in
                            form.draft.organizationID = id
                            form.draft.collectionIDs = []
                        })
                        BWSelect(BWText["owner"], selection: owner,
                                 options: [.init(nil, model.state.session.account?.email ?? BWText["me"])]
                                     + organizations.map { .init($0.id, $0.name) },
                                 bottomMargin: form.draft.organizationID == nil ? 0 : Metric.space(4))
                        if let organizationID = form.draft.organizationID {
                            CollectionChoice(collections: model.state.vault.assignableCollections(of: organizationID),
                                             chosen: $form.draft.collectionIDs)
                        }
                    }
                }
            }
        }
        .padding(.bottom, Metric.space(5))
    }

    private var isNameMissing: Bool {
        form.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The folders by name, then "no folder", as the folder list of the reference has them.
    private var folderOptions: [BWSelect<String?>.Option] {
        let folders = model.state.vault.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folders.map { .init($0.id, $0.name) } + [.init(nil, BWText["noneFolder"])]
    }

    // MARK: Login

    private var login: Binding<ItemDraft.Login> {
        Binding(get: { if case .login(let login) = form.draft.content { login } else { ItemDraft.Login() } },
                set: { form.draft.content = .login($0) })
    }

    /// login-details-section
    private var loginDetails: some View {
        section(BWText["loginCredentials"]) {
            BWFormField(BWText["username"], isFocused: focus == "username") {
                BWTextInput(text: login.username).focused($focus, equals: "username")
            } suffix: {
                BWIconButton(.generate, label: BWText["generateUsername"], size: .small) {
                    navigation.generator = GeneratorSession(purpose: .username(form), options: model.state.settings.generator)
                }
            }
            BWFormField(BWText["password"], isFocused: focus == "password", bottomMargin: 0) {
                BWTextInput(text: login.password, isSecure: !form.revealed.contains("password"), isMonospaced: true)
                    .focused($focus, equals: "password")
            } suffix: {
                if !login.wrappedValue.password.isEmpty {
                    BWIconButton(.checkCircle, label: BWText["checkPassword"], size: .small) {
                        ItemActions(model: model, navigation: navigation).checkPassword(login.wrappedValue.password)
                    }
                }
                revealButton("password")
                BWIconButton(.generate, label: BWText["generatePassword"], size: .small) {
                    navigation.generator = GeneratorSession(purpose: .password(form), options: model.state.settings.generator)
                }
            }
            // bit-hint: the two parts of the text around the icon of the generator.
            (Text(BWText["useGeneratorHelpTextPartOne"] + " ") + Text(Image(systemName: BWIcon.generate.systemName)).font(.system(size: TextStyle.xs.size))
                + Text(" " + BWText["useGeneratorHelpTextPartTwo"]))
                .textStyle(.xs)
                .foregroundStyle(.theme(.textMuted))
                .padding(.top, Metric.space(2))
                .padding(.bottom, Metric.space(4))
            if let created = login.wrappedValue.passkeyCreated {
                // The passkey of the login: when it was made, and the button that removes it. The
                // login is saved without it; a passkey cannot be typed in.
                BWFormField(BWText["typePasskey"], isFocused: false) {
                    BWTextInput(text: .constant(BWText["dateCreated"] + " " + ItemPanel.short(created)))
                        .disabled(true)
                } suffix: {
                    BWIconButton(.minusCircle, label: BWText["removePasskey"], size: .small, kind: .dangerGhost) {
                        login.wrappedValue.passkeyCreated = nil
                    }
                }
            }
            // The popover "totpPopover": the desktop app cannot take the key from a picture, so "totpHelper".
            input(BWText["authenticatorKey"], "verificationKey", login.verificationKey, isHidden: true, isLast: true,
                  help: BWHelp(isOpen: $form.showsVerificationKeyHelp, label: BWText["learnMoreAboutAuthenticators"],
                               title: BWText["totpHelperTitle"], text: BWText["totpHelper"]))
        }
    }

    /// autofill-options: one row for each website, then the link that adds one. The link is the
    /// one the reference has with its autotype, "add website or app" with a menu of the two
    /// (PLAN.md, "Differences from the reference"). The apps have their section below.
    private var websites: some View {
        let rows = form.websiteRows
        return section(BWText["autofillOptions"]) {
            ReorderRows(ids: rows, label: { index in
                let place = rows.firstIndex(of: index) ?? 0
                return BWText["reorderToggleButton", place == 0 ? BWText["websiteUri"] : BWText["websiteUriCount", String(place + 1)]]
            }, move: { from, to in form.moveWebsite(from: rows[from], to: rows[to]) },
                        focusFollowsIndex: true) { index in
                if let place = rows.firstIndex(of: index) {
                    websiteRow(index, place: place, count: rows.count)
                }
            }
            .padding(.bottom, Metric.space(3))
            BWLink(BWText["addWebsiteOrApp"], startIcon: .plus) { form.isAddWebsiteMenuOpen = true }
                .frame(height: Self.linkLine)
                .disabled(form.isReadingApp)
                .bwMenu(isOpen: $form.isAddWebsiteMenuOpen) {
                    [BWMenuItem(BWText["website"]) {
                        if let added = form.addWebsite() { focus = "website-\(added)" }
                    }, BWMenuItem(BWText["app"]) {
                        chooseApp()
                    }]
                }
        }
    }

    /// The apps of the login: one row for each, with the button that takes it away.
    private var apps: some View {
        let rows = form.appRows
        return section(BWText["app"]) {
            VStack(alignment: .leading, spacing: Metric.space(2)) {
                ForEach(rows, id: \.self) { index in
                    if index < login.wrappedValue.websites.count, let app = login.wrappedValue.websites[index].app {
                        LoginAppRow(app) {
                            BWIconButton(.minusCircle, label: BWText["remove"], size: .small, kind: .dangerGhost) {
                                if index < login.wrappedValue.websites.count { login.wrappedValue.websites.remove(at: index) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "App" offers running applications, with the system file chooser as a fallback.
    private func chooseApp() {
        form.isAppPickerOpen = true
    }

    /// uri-option
    private func websiteRow(_ index: Int, place: Int, count: Int) -> some View {
        let key = "website-\(index)"
        let isOpen = form.openMatchDetection.contains(index)
        let label = place == 0 ? BWText["websiteUri"] : BWText["websiteUriCount", String(place + 1)]
        let address = Binding(get: { index < login.wrappedValue.websites.count ? login.wrappedValue.websites[index].address : "" },
                              set: { if index < login.wrappedValue.websites.count { login.wrappedValue.websites[index].address = $0 } })
        let presented = Binding(get: { form.openMatchDetection.contains(index) }, set: { open in
            if open { form.openMatchDetection = [index] } else { form.openMatchDetection.remove(index) }
        })
        return HStack(alignment: .bottom, spacing: 0) {
            BWFormField(label, isFocused: focus == key, bottomMargin: 0) {
                BWTextInput(text: address).focused($focus, equals: key)
            } suffix: {
                BWIconButton(isOpen ? .cogF : .cog,
                             label: BWText[isOpen ? "hideMatchDetectionNoPlaceholder" : "showMatchDetectionNoPlaceholder"],
                             size: .small) {
                    form.openMatchDetection = [index]
                }
                .popover(isPresented: presented, arrowEdge: .trailing) {
                    if login.wrappedValue.websites.indices.contains(index) {
                        WebsiteMatchPopover(website: login.wrappedValue.websites[index]) { edited in
                            if login.wrappedValue.websites.indices.contains(index) { login.wrappedValue.websites[index] = edited }
                            presented.wrappedValue = false
                        } cancel: { presented.wrappedValue = false }
                    }
                }
                if count > 1 {
                    BWIconButton(.minusCircle, label: BWText["deleteWebsite"], size: .small, kind: .dangerGhost) {
                        login.wrappedValue.websites.remove(at: index)
                        form.openMatchDetection = []
                    }
                }
            }
        }
    }

    // MARK: Card

    private var card: Binding<CardContent> {
        Binding(get: { if case .card(let card) = form.draft.content { card } else { CardContent() } },
                set: { form.draft.content = .card($0) })
    }

    /// card-details-section
    private var cardDetails: some View {
        let brands: [BWSelect<String?>.Option] = [.init(nil, noChoice)]
            + [("Visa", "Visa"), ("Mastercard", "Mastercard"), ("American Express", "Amex"), ("Discover", "Discover"),
               ("Diners Club", "Diners Club"), ("JCB", "JCB"), ("Maestro", "Maestro"), ("UnionPay", "UnionPay"),
               ("RuPay", "RuPay")].map { .init($0.1, $0.0) }
            + [.init("Other", BWText["other"])]
        let monthKeys = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                         "november", "december"]
        let months: [BWSelect<String?>.Option] = [.init(nil, noChoice)] + monthKeys.enumerated().map { index, key in
            .init(String(index + 1), String(format: "%02d - ", index + 1) + BWText[key])
        }
        // `getSectionHeading`: "Visa details" for a brand that is chosen and is not "other".
        return section(card.wrappedValue.namedBrand.map { BWText["cardBrandDetails", $0] } ?? BWText["cardDetails"]) {
            input(BWText["cardholderName"], "cardholderName", text(card.cardholderName))
            input(BWText["number"], "cardNumber", text(card.number), isHidden: true)
            BWSelect(BWText["brand"], selection: card.brand, options: brands)
            // div "tw-flex tw-flex-wrap tw-gap-1"
            HStack(alignment: .top, spacing: Metric.space(1)) {
                BWSelect(BWText["expirationMonth"], selection: card.expirationMonth, options: months)
                input(BWText["expirationYear"], "expirationYear", text(card.expirationYear))
            }
            input(BWText["securityCode"], "securityCode", text(card.securityCode), isHidden: true, isLast: true)
        }
    }

    // MARK: Identity

    private var identity: Binding<IdentityContent> {
        Binding(get: { if case .identity(let identity) = form.draft.content { identity } else { IdentityContent() } },
                set: { form.draft.content = .identity($0) })
    }

    /// identity.component.html: four cards.
    @ViewBuilder
    private var identityDetails: some View {
        // The reference stores the title as the text of the chosen option.
        let titles: [BWSelect<String?>.Option] = [.init(nil, noChoice)]
            + ["mr", "mrs", "ms", "mx", "dr"].map { .init(BWText[$0], BWText[$0]) }
        section(BWText["personalDetails"]) {
            BWSelect(BWText["title"], selection: identity.title, options: titles)
            input(BWText["firstName"], "firstName", text(identity.firstName))
            input(BWText["middleName"], "middleName", text(identity.middleName))
            input(BWText["lastName"], "lastName", text(identity.lastName))
            input(BWText["username"], "identityUsername", text(identity.username))
            input(BWText["company"], "company", text(identity.company), isLast: true)
        }
        section(BWText["identification"]) {
            // The two numbers are hidden with a toggle (`type="password"`); the licence number is not.
            input(BWText["ssn"], "ssn", text(identity.socialSecurityNumber), isHidden: true)
            input(BWText["passportNumber"], "passportNumber", text(identity.passportNumber), isHidden: true)
            input(BWText["licenseNumber"], "licenseNumber", text(identity.licenseNumber), isLast: true)
        }
        section(BWText["contactInfo"]) {
            input(BWText["email"], "email", text(identity.email))
            input(BWText["phone"], "phone", text(identity.phone), isLast: true)
        }
        section(BWText["address"]) {
            input(BWText["address1"], "address1", text(identity.address1))
            input(BWText["address2"], "address2", text(identity.address2))
            input(BWText["address3"], "address3", text(identity.address3))
            input(BWText["cityTown"], "city", text(identity.city))
            input(BWText["stateProvince"], "state", text(identity.state))
            input(BWText["zipPostalCodeLabel"], "postalCode", text(identity.postalCode))
            input(BWText["country"], "country", text(identity.country), isLast: true)
        }
    }

    // MARK: SSH key

    /// sshkey-section: the three parts of the key, read-only, and the button that takes a key
    /// from the clipboard.
    private func sshKey(_ key: SSHKeyContent) -> some View {
        section(BWText["typeSshKey"]) {
            VStack(alignment: .leading, spacing: Metric.space(4)) {
                BWReadOnlyField(BWText["sshPrivateKey"]) {
                    BWFieldValue(key.privateKey, isHidden: !form.revealed.contains("sshPrivateKey"), isMonospaced: true)
                } suffix: {
                    revealButton("sshPrivateKey")
                    BWIconButton(.import, label: BWText["importSshKeyFromClipboard"], size: .small) {
                        ItemActions(model: model, navigation: navigation).importSSHKey(into: form)
                    }
                }
                .environment(\.centersIconArtwork, true)
                BWReadOnlyField(BWText["sshPublicKey"]) { BWFieldValue(key.publicKey) }
                BWReadOnlyField(BWText["sshFingerprint"]) { BWFieldValue(key.fingerprint) }
            }
        }
    }

    // MARK: Additional options and custom fields

    /// additional-options-section
    private var additionalOptions: some View {
        let hasFields = !form.fieldIDs.isEmpty || form.removedField != nil
        return section(BWText["additionalOptions"]) {
            BWFormField(BWText["notes"], isFocused: focus == "notes", isTextArea: true) {
                BWTextArea(text: $form.draft.notes, rows: 5).focused($focus, equals: "notes")
            }
            // bit-form-control: "tw-mb-4" unless custom fields follow.
            BWCheckbox(BWText["passwordPrompt"], isOn: $form.draft.asksForMasterPassword)
                .padding(.bottom, hasFields ? 0 : Metric.space(4))
            if !hasFields {
                BWLink(BWText["addField"], startIcon: .plus) { form.showsAddField = true }
                    .frame(height: Self.linkLine)
            }
        }
    }

    private static let linkLine = TextStyle.body.lineHeight

    private var customFields: some View {
        section(BWText["customFields"]) {
            ReorderRows(ids: form.fieldIDs, label: { id in
                let name = form.fieldIDs.firstIndex(of: id).map { form.draft.customFields[$0].name } ?? ""
                return BWText["reorderToggleButton", name]
            }, move: form.moveCustomField, onGrab: { revealedField = nil }) { id in
                if let index = form.fieldIDs.firstIndex(of: id) { customFieldRow(id, index: index) }
            }
            HStack {
                BWLink(BWText["addField"], startIcon: .plus) { form.showsAddField = true }
                if form.removedField != nil {
                    Spacer()
                    BWLink(BWText["undo"]) { form.undoRemoveField() }
                }
            }
            .padding(.top, Metric.space(3))
        }
        .onChange(of: focus) { old, new in
            if let id = revealedField, old == "clear-\(id)", new != old { revealedField = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if revealedField != nil { revealedField = nil }
        }
        .onDisappear { revealedField = nil }
    }

    private func customFieldRow(_ id: UUID, index: Int) -> some View {
        let field = form.draft.customFields[index]
        let binding = Binding<CustomField>(get: {
            form.fieldIDs.firstIndex(of: id).map { form.draft.customFields[$0] } ?? field
        }, set: { new in
            if let i = form.fieldIDs.firstIndex(of: id) { form.draft.customFields[i] = new }
        })
        let active = ["name-\(id)", "value-\(id)", "clear-\(id)"].contains(focus ?? "")
        let shape = RoundedRectangle(cornerRadius: Metric.fieldCornerRadius)
        return HStack(spacing: Metric.space(2)) {
            VStack(alignment: .leading, spacing: Metric.space(1)) {
                TextField(BWText["fieldLabel"], text: binding.name)
                    .textFieldStyle(.plain).fontWeight(.semibold)
                    .focused($focus, equals: "name-\(id)")
                customValue(id, field: binding)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            BWIconButton(.trash, label: BWText["deleteCustomField", field.name], size: .small, kind: .dangerGhost) {
                revealedField = nil
                form.removeField(id)
            }
        }
        .padding(.leading, Metric.space(3)).padding(.trailing, Metric.space(1))
        .padding(.vertical, Metric.space(2))
        .background(shape.fill(.theme(.bgSecondary)))
        .overlay(shape.strokeBorder(.theme(active ? .borderBrand : .borderBase), lineWidth: active ? 2 : 1).allowsHitTesting(false))
    }

    @ViewBuilder
    private func customValue(_ id: UUID, field: Binding<CustomField>) -> some View {
        switch field.wrappedValue.value {
        case .text, .hidden:
            let hidden = if case .hidden = field.wrappedValue.value { true } else { false }
            let text = Binding<String>(get: {
                switch field.wrappedValue.value {
                case .text(let s), .hidden(let s): s
                default: ""
                }
            }, set: { field.wrappedValue.value = hidden ? .hidden($0) : .text($0) })
            if hidden && revealedField != id {
                BWTextInput(text: text, isSecure: true, isMonospaced: true)
                    .focused($focus, equals: "value-\(id)")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { revealedField = id }
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(field.wrappedValue.name)
            } else {
                BWTextInput(text: text, isMonospaced: hidden)
                    .focused($focus, equals: hidden ? "clear-\(id)" : "value-\(id)")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .onAppear { if hidden && revealedField == id { focus = "clear-\(id)" } }
                    .accessibilityLabel(field.wrappedValue.name)
            }
        case .boolean(let on):
            Toggle(BWText[on ? "yes" : "no"], isOn: Binding(get: {
                if case .boolean(let value) = field.wrappedValue.value { value } else { false }
            }, set: { field.wrappedValue.value = .boolean($0) }))
            .toggleStyle(.checkbox).focused($focus, equals: "value-\(id)")
            .accessibilityLabel(field.wrappedValue.name)
        case .linked(let link):
            Picker(field.wrappedValue.name, selection: Binding(get: {
                if case .linked(let current) = field.wrappedValue.value { current } else { link }
            }, set: { field.wrappedValue.value = .linked($0) })) {
                ForEach(LinkedField.options(for: form.draft.type), id: \.self) { option in
                    Text(LinkedField.labelKey(option).map { BWText[$0] } ?? "").tag(option)
                }
            }
            .pickerStyle(.menu).labelsHidden().buttonStyle(.plain)
            .focused($focus, equals: "value-\(id)")
        }
    }


    // MARK: Footer

    /// The footer of vault-item-dialog in form mode: "save" and "cancel", and for the change of an
    /// item the delete button at the end.
    @ViewBuilder
    private var footer: some View {
        BWButton(BWText["save"], kind: .primary, isBlock: false, action: save)
            .disabled(form.isSaving)
        BWButton(BWText["cancel"], isBlock: false, action: cancel)
        Spacer(minLength: 0)
        if form.mode == .edit, let id = form.draft.id, let item = model.state.vault.items.first(where: { $0.id == id }) {
            BWIconButton(.trash, label: BWText["delete"], kind: .dangerGhost) {
                ItemActions(model: model, navigation: navigation, isPanel: true).delete(item)
            }
        }
    }

    /// The change of an item goes back to its view; a new item and a copy close the panel.
    private func cancel() {
        navigation.itemForm = nil
    }

    private func save() {
        if !isNameMissing, let index = form.draft.customFields.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            focus = "name-\(form.fieldIDs[index])"
            return
        }
        if isNameMissing { focus = "name" }
        ItemActions(model: model, navigation: navigation).save(form)
    }
}

/// The dialog that adds a custom field to the form, or renames or removes one.
/// Source: cipher-form/components/custom-fields/add-edit-custom-field-dialog.
struct CustomFieldDialog: View {
    @Bindable var form: ItemForm
    @State private var kind = Kind.text
    @State private var label = ""
    @FocusState private var isLabelFocused: Bool

    enum Kind: Hashable {
        case text, hidden, boolean, linked
    }

    var body: some View {
        BWDialog(title: BWText["addField"], onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                BWSelect(BWText["fieldType"], selection: $kind, options: kinds, hint: hint)
                BWFormField(BWText["fieldLabel"], isFocused: isLabelFocused,
                            hint: kind == .linked ? BWText["linkedFieldLabelHelpText"] : nil, bottomMargin: 0) {
                    BWTextInput(text: $label)
                        .focused($isLabelFocused)
                        .onSubmit(confirm)
                }
            }
        } footer: {
            BWButton(BWText["add"], kind: .primary, isBlock: false, action: confirm)
                .disabled(label.isEmpty)
            BWButton(BWText["cancel"], isBlock: false, action: close)

        }
        .onAppear { isLabelFocused = true }
        .onExitCommand(perform: close)
    }

    /// A linked field needs a field of the item to show; a note and an SSH key have none.
    private var kinds: [BWSelect<Kind>.Option] {
        var kinds: [BWSelect<Kind>.Option] = [.init(.text, BWText["cfTypeText"]), .init(.hidden, BWText["cfTypeHidden"]),
                                              .init(.boolean, BWText["cfTypeCheckbox"])]
        if !LinkedField.options(for: form.draft.type).isEmpty { kinds.append(.init(.linked, BWText["cfTypeLinked"])) }
        return kinds
    }

    private var hint: String {
        switch kind {
        case .text: BWText["textHelpText"]
        case .hidden: BWText["hiddenHelpText"]
        case .boolean: BWText["checkBoxHelpText"]
        case .linked: BWText["linkedHelpText"]
        }
    }

    private func confirm() {
        guard !label.isEmpty else { return }
        let value: CustomField.Value = switch kind {
        case .text: .text("")
        case .hidden: .hidden("")
        case .boolean: .boolean(false)
        case .linked: .linked(LinkedField.options(for: form.draft.type).first ?? 0)
        }
        form.addField(CustomField(name: label, value: value))
        close()
    }

    private func close() {
        form.showsAddField = false
    }
}

/// The question for the password of an encrypted SSH key on the clipboard.
/// Source: libs/importer/src/components/dialog/sshkey-password-prompt. No reference picture yet.
struct SSHKeyPasswordDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    @Bindable var form: ItemForm
    @State private var password = ""
    @State private var showsPassword = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        BWDialog(title: BWText["enterSshKeyPassword"], onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                // The text stands in the body of the dialog without an element of its own.
                Text(BWText["enterSshKeyPasswordDesc"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // bit-form-field class="tw-mt-6"
                BWFormField(BWText["confirmSshKeyPassword"], isFocused: isFieldFocused) {
                    BWTextInput(text: $password, isSecure: !showsPassword)
                        .focused($isFieldFocused)
                        .onSubmit(confirm)
                } suffix: {
                    BWIconButton(showsPassword ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
                        showsPassword.toggle()
                        isFieldFocused = true
                    }
                }
                .padding(.top, Metric.space(6))
            }
        } footer: {
            BWButton(BWText["importSshKey"], kind: .primary, isBlock: false, action: confirm)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: close)
    }

    /// An empty password gives the import up, as in the reference.
    private func confirm() {
        guard !password.isEmpty else {
            close()
            return
        }
        ItemActions(model: model, navigation: navigation).importSSHKey(into: form, password: password)
        password = ""
    }

    private func close() {
        form.asksForSSHKeyPassword = false
    }
}

private struct WebsiteMatchPopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let website: ItemDraft.Website
    let apply: (ItemDraft.Website) -> Void
    let cancel: () -> Void
    @State private var draft: ItemDraft.Website
    @FocusState private var menuFocused: Bool
    @FocusState private var patternFocused: Bool
    private static let modes: [(WebsiteMatch?, String)] = [
        (nil, "default"), (.baseDomain, "baseDomain"), (.host, "host"), (.exact, "exact"),
        (.never, "never"), (.startsWith, "startsWith"), (.regularExpression, "regEx")
    ]

    init(website: ItemDraft.Website, apply: @escaping (ItemDraft.Website) -> Void, cancel: @escaping () -> Void) {
        self.website = website
        self.apply = apply
        self.cancel = cancel
        _draft = State(initialValue: website)
    }

    private var usesPattern: Bool { draft.match == .regularExpression || draft.match == .startsWith }

    private var rulePreview: (label: String, value: String?) {
        let address = usesPattern ? draft.address : website.address
        switch draft.match ?? .baseDomain {
        case .baseDomain: return (BWText["baseDomain"], WebAddress.domain(of: address))
        case .host: return (BWText["host"], WebAddress.host(of: address))
        case .exact: return (BWText["exact"], address)
        case .startsWith: return (BWText["startsWith"], address)
        case .regularExpression: return (BWText["regEx"], address)
        case .never: return (BWText["doNotAutofill"], nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space(3)) {
            Text(BWText["autofillOptions"])
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            let selection = BWText[Self.modes.first { $0.0 == draft.match }?.1 ?? "default"]
            Menu {
                Picker(BWText["matchDetection"], selection: $draft.match) {
                    ForEach(Self.modes, id: \.1) { mode in
                        Text(BWText[mode.1]).tag(mode.0)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                BWFieldContainer(isFocused: menuFocused) {
                    HStack {
                        Text(selection).textStyle(.body)
                        Spacer(minLength: Metric.space(2))
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, Metric.space(3))
                    .foregroundStyle(.theme(.fgHeading))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .focused($menuFocused)
            .accessibilityLabel(BWText["matchDetection"])
            .accessibilityValue(selection)
            if usesPattern {
                VStack(alignment: .leading, spacing: Metric.space(2)) {
                    let label = BWText[draft.match == .regularExpression ? "regEx" : "websiteUri"]
                    BWFieldLabel(label, isRequired: true)
                    BWFieldContainer(isFocused: patternFocused) {
                        BWTextInput(text: $draft.address, placeholder: draft.match == .regularExpression ? #"^https://shop\.example\.com/"# : "https://shop.example.com/")
                            .padding(.horizontal, Metric.space(3))
                            .foregroundStyle(.theme(.fgHeading))
                            .accessibilityLabel(label)
                            .focused($patternFocused)
                            .disableAutocorrection(true)
                            .onSubmit { confirm() }
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
            let preview = rulePreview
            VStack(alignment: .leading, spacing: Metric.space(1)) {
                if draft.match != .never {
                    Text(BWText["hpWebsiteMatchSummary"])
                }
                Text(verbatim: [preview.label, preview.value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metric.space(3))
            .background(.theme(.bgBrandSofter), in: RoundedRectangle(cornerRadius: Metric.fieldCornerRadius))
            HStack {
                Spacer()
                BWIconButton(.close, label: BWText["cancel"], size: .small, action: cancel)
                    .keyboardShortcut(.cancelAction)
                BWIconButton(.check, label: BWText["save"], size: .small, action: confirm)
                    .disabled(usesPattern && draft.address.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .submitScope()
        .padding(Metric.space(4))
        .frame(width: 330)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: usesPattern)
    }

    private func confirm() {
        guard !usesPattern || !draft.address.isEmpty else { return }
        apply(.init(address: usesPattern ? draft.address : website.address, match: draft.match))
    }
}

private struct ReorderRows<ID: Hashable, Row: View>: View {
    let ids: [ID]
    let label: (ID) -> String
    let move: (Int, Int) -> Void
    var focusFollowsIndex = false
    var onGrab: () -> Void = {}
    @ViewBuilder let row: (ID) -> Row
    @Namespace private var space
    @State private var frames: [ID: CGRect] = [:]
    @GestureState private var drag: Drag?
    @FocusState private var focused: ID?

    private struct Drag {
        let id: ID
        let offset: CGFloat
        let y: CGFloat
    }

    private func destination(_ id: ID, y: CGFloat) -> Int {
        ids.filter { $0 != id && (frames[$0]?.midY ?? .infinity) < y }.count
    }

    var body: some View {
        VStack(spacing: Metric.space(3)) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let moving = drag?.id == id
                let shape = RoundedRectangle(cornerRadius: Metric.fieldCornerRadius)
                HStack(spacing: Metric.space(1.5)) {
                    if ids.count > 1 {
                        ReorderDots()
                            .foregroundStyle(.theme(moving || focused == id ? .fgBrand : .fgHeading))
                            .frame(width: Metric.space(8), height: Metric.space(10))
                            .contentShape(Rectangle())
                            .pointerStyle(.grabIdle)
                            .help(label(id))
                            .accessibilityLabel(label(id))
                            .focusable().focused($focused, equals: id)
                            .focusEffectDisabled()
                            .onKeyPress(.upArrow) { keyboardMove(index, by: -1) }
                            .onKeyPress(.downArrow) { keyboardMove(index, by: 1) }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                                .updating($drag) { event, state, _ in
                                    state = Drag(id: id, offset: event.translation.height, y: event.location.y)
                                }
                                .onChanged { _ in onGrab() }
                                .onEnded { event in
                                    let target = destination(id, y: event.location.y)
                                    if index != target { move(index, target) }
                                })
                    }
                    row(id)
                }
                .opacity(moving ? 0.35 : 1)
                .background {
                    if moving {
                        shape.strokeBorder(.theme(.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .overlay {
                    if let drag, !moving, destination(drag.id, y: drag.y) == index,
                       let from = ids.firstIndex(of: drag.id) {
                        Capsule().fill(.theme(.fgBrand)).frame(height: 3)
                            .offset(y: index < from ? -Metric.space(1.5) : Metric.space(1.5))
                            .frame(maxHeight: .infinity, alignment: index < from ? .top : .bottom)
                    }
                }
                .onGeometryChange(for: CGRect.self) { [space] in $0.frame(in: .named(space)) } action: { frames[id] = $0 }
                .onDisappear { frames.removeValue(forKey: id) }
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let drag, let frame = frames[drag.id] {
                    let top = min(max(0, frame.minY + drag.offset), max(0, geometry.size.height - frame.height))
                    RoundedRectangle(cornerRadius: Metric.fieldCornerRadius)
                        .fill(.theme(.fgBrand).opacity(0.12))
                        .strokeBorder(.theme(.borderBrand), lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: top)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .coordinateSpace(name: space)
    }

    private func keyboardMove(_ index: Int, by step: Int) -> KeyPress.Result {
        let target = index + step
        guard ids.indices.contains(target) else { return .ignored }
        let focusAfterMove = focusFollowsIndex ? ids[target] : ids[index]
        move(index, target)
        focused = focusAfterMove
        return .handled
    }
}
