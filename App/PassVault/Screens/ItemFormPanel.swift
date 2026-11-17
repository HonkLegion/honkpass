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
    /// The website and the custom field that are being dragged by their handles.
    @State private var draggedWebsite: Int?
    @State private var draggedField: Int?

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
                if !form.draft.customFields.isEmpty { customFields }
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
            ForEach(Array(rows.enumerated()), id: \.element) { place, index in
                websiteRow(index, place: place, count: rows.count)
                    // host: "tw-p-3 -tw-mx-3", "first:-tw-mt-3"
                    .padding(Metric.space(3))
                    .padding(.horizontal, -Metric.space(3))
                    .padding(.top, place == 0 ? -Metric.space(3) : 0)
                    // cdkDropList: a row that is dragged over another one takes its place.
                    .onDrop(of: [.text], delegate: ReorderDrop(index: index, dragged: $draggedWebsite) { source, target in
                        form.moveWebsite(from: source, to: target)
                    })
            }
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
        let match = Binding(get: { index < login.wrappedValue.websites.count ? login.wrappedValue.websites[index].match : nil },
                            set: { if index < login.wrappedValue.websites.count { login.wrappedValue.websites[index].match = $0 } })
        return VStack(alignment: .leading, spacing: 0) {
            // div "tw-flex tw-flex-1", with "!tw-mb-1" while the match detection shows
            HStack(alignment: .bottom, spacing: 0) {
                BWFormField(label, isFocused: focus == key, bottomMargin: 0) {
                    BWTextInput(text: address).focused($focus, equals: key)
                } suffix: {
                    BWIconButton(isOpen ? .cogF : .cog,
                                 label: BWText[isOpen ? "hideMatchDetectionNoPlaceholder" : "showMatchDetectionNoPlaceholder"],
                                 size: .small) {
                        if isOpen { form.openMatchDetection.remove(index) } else { form.openMatchDetection.insert(index) }
                    }
                    if count > 1 {
                        BWIconButton(.minusCircle, label: BWText["deleteWebsite"], size: .small, kind: .dangerGhost) {
                            login.wrappedValue.websites.remove(at: index)
                            form.openMatchDetection = []
                        }
                    }
                }
                if count > 1 {
                    // div "tw-flex tw-items-center tw-ml-1.5 tw-self-end tw-min-h-10" around the handle.
                    ReorderHandle(label: BWText["reorderToggleButton", label], size: .small, dragged: $draggedWebsite, index: index,
                                  count: count) { source, target in
                        form.moveWebsite(from: source, to: target)
                        focus = "website-handle-\(target)"
                    }
                    .focused($focus, equals: "website-handle-\(index)")
                    .frame(height: Metric.space(10))
                    .padding(.leading, Metric.space(1.5))
                }
            }
            .padding(.bottom, isOpen ? Metric.space(1) : 0)
            if isOpen {
                BWSelect(BWText["matchDetection"], selection: match, options: [
                    .init(nil, BWText["default"]), .init(.baseDomain, BWText["baseDomain"]), .init(.host, BWText["host"]),
                    .init(.exact, BWText["exact"]), .init(.never, BWText["never"]),
                    .init(.startsWith, BWText["startsWith"]), .init(.regularExpression, BWText["regEx"]),
                ], bottomMargin: 0)
                    .padding(.top, Metric.space(4))
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
        let hasFields = !form.draft.customFields.isEmpty
        return section(BWText["additionalOptions"]) {
            BWFormField(BWText["notes"], isFocused: focus == "notes", isTextArea: true) {
                BWTextArea(text: $form.draft.notes, rows: 5).focused($focus, equals: "notes")
            }
            // bit-form-control: "tw-mb-4" unless custom fields follow.
            BWCheckbox(BWText["passwordPrompt"], isOn: $form.draft.asksForMasterPassword)
                .padding(.bottom, hasFields ? 0 : Metric.space(4))
            if !hasFields {
                BWLink(BWText["addField"], startIcon: .plus) { form.fieldDialog = .add }
                    .frame(height: Self.linkLine)
            }
        }
    }

    /// custom-fields.component.html
    private var customFields: some View {
        section(BWText["customFields"]) {
            ForEach(Array(form.draft.customFields.indices), id: \.self) { index in
                customFieldRow(index)
                    // "tw-flex tw-p-3 -tw-mx-3 tw-gap-4", "first:-tw-mt-3"
                    .padding(Metric.space(3))
                    .padding(.horizontal, -Metric.space(3))
                    .padding(.top, index == 0 ? -Metric.space(3) : 0)
                    .onDrop(of: [.text], delegate: ReorderDrop(index: index, dragged: $draggedField) { source, target in
                        form.moveCustomField(from: source, to: target)
                    })
            }
            BWLink(BWText["addField"], startIcon: .plus) { form.fieldDialog = .add }
                .frame(height: Self.linkLine)
        }
    }

    /// A link that stands alone in a card is an inline button on a line of the body text:
    /// the line is 20 pixels high, the link with its "tw-py-0.5" in the middle of it.
    private static let linkLine = TextStyle.body.lineHeight

    @ViewBuilder
    private func customFieldRow(_ index: Int) -> some View {
        let fields = form.draft.customFields
        if index < fields.count {
            let field = fields[index]
            let key = "field-\(index)"
            let value = Binding(get: { index < form.draft.customFields.count ? form.draft.customFields[index].value : .text("") },
                                set: { if index < form.draft.customFields.count { form.draft.customFields[index].value = $0 } })
            HStack(alignment: .center, spacing: Metric.space(4)) {
                Group {
                    switch field.value {
                    case .text:
                        input(field.name, key, Binding(get: { if case .text(let text) = value.wrappedValue { text } else { "" } },
                                                       set: { value.wrappedValue = .text($0) }), isLast: true)
                    case .hidden:
                        input(field.name, key, Binding(get: { if case .hidden(let text) = value.wrappedValue { text } else { "" } },
                                                       set: { value.wrappedValue = .hidden($0) }), isHidden: true, isLast: true)
                    case .boolean:
                        BWCheckbox(field.name, isOn: Binding(get: { if case .boolean(let isOn) = value.wrappedValue { isOn } else { false } },
                                                             set: { value.wrappedValue = .boolean($0) }))
                    case .linked:
                        BWSelect(field.name, selection: Binding(get: { if case .linked(let id) = value.wrappedValue { id } else { 0 } },
                                                                set: { value.wrappedValue = .linked($0) }),
                                 options: LinkedField.options(for: form.draft.type).map { id in
                                     .init(id, LinkedField.labelKey(id).map { BWText[$0] } ?? "")
                                 }, bottomMargin: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // "tw-self-center tw-mt-2"
                BWIconButton(.pencilSquare, label: BWText["editFieldLabel", field.name]) { form.fieldDialog = .edit(index) }
                    .padding(.top, Metric.space(2))
                if fields.count > 1 {
                    ReorderHandle(label: BWText["reorderToggleButton", field.name], size: .regular, dragged: $draggedField,
                                  index: index, count: fields.count) { source, target in
                        form.moveCustomField(from: source, to: target)
                        focus = "field-handle-\(target)"
                    }
                    .focused($focus, equals: "field-handle-\(index)")
                    .padding(.top, Metric.space(2))
                }
            }
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
        if isNameMissing { focus = "name" }
        ItemActions(model: model, navigation: navigation).save(form)
    }
}

/// The dialog that adds a custom field to the form, or renames or removes one.
/// Source: cipher-form/components/custom-fields/add-edit-custom-field-dialog.
struct CustomFieldDialog: View {
    @Bindable var form: ItemForm
    let dialog: ItemForm.FieldDialog
    @State private var kind = Kind.text
    @State private var label: String
    @FocusState private var isLabelFocused: Bool

    enum Kind: Hashable {
        case text, hidden, boolean, linked
    }

    init(form: ItemForm, dialog: ItemForm.FieldDialog) {
        self.form = form
        self.dialog = dialog
        var label = ""
        if case .edit(let index) = dialog, index < form.draft.customFields.count { label = form.draft.customFields[index].name }
        _label = State(initialValue: label)
    }

    private var isAdd: Bool { dialog == .add }

    var body: some View {
        BWDialog(title: BWText[isAdd ? "addField" : "editField"], onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                if isAdd {
                    BWSelect(BWText["fieldType"], selection: $kind, options: kinds, hint: hint)
                }
                BWFormField(BWText["fieldLabel"], isFocused: isLabelFocused,
                            hint: isAdd && kind == .linked ? BWText["linkedFieldLabelHelpText"] : nil, bottomMargin: 0) {
                    BWTextInput(text: $label)
                        .focused($isLabelFocused)
                        .onSubmit(confirm)
                }
            }
        } footer: {
            BWButton(BWText[isAdd ? "add" : "save"], kind: .primary, isBlock: false, action: confirm)
                .disabled(label.isEmpty)
            BWButton(BWText["cancel"], isBlock: false, action: close)
            if case .edit(let index) = dialog {
                Spacer(minLength: 0)
                BWIconButton(.trash, label: BWText["deleteCustomField", label], kind: .dangerGhost) {
                    if index < form.draft.customFields.count { form.draft.customFields.remove(at: index) }
                    close()
                }
            }
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
        switch dialog {
        case .add:
            let value: CustomField.Value = switch kind {
            case .text: .text("")
            case .hidden: .hidden("")
            case .boolean: .boolean(false)
            case .linked: .linked(LinkedField.options(for: form.draft.type).first ?? 0)
            }
            form.draft.customFields.append(CustomField(name: label, value: value))
        case .edit(let index):
            if index < form.draft.customFields.count { form.draft.customFields[index].name = label }
        }
        close()
    }

    private func close() {
        form.fieldDialog = nil
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

/// The handle that moves a row of a list of the form: `cdkDragHandle` on a `bitIconButton` with
/// "bwi-drag-and-drop". The row follows the pointer while the handle is dragged; with the focus on
/// the handle, the up and down arrows move the row by one place, as `handleKeydown` of the reference.
private struct ReorderHandle: View {
    let label: String
    let size: BWIconButton.Size
    @Binding var dragged: Int?
    let index: Int
    let count: Int
    let move: (Int, Int) -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let box = size == .small ? Metric.space(8) : Metric.space(10)
        let icon = size == .small ? 1.25 * Metric.rem : 1.5 * Metric.rem
        IconView(.dragAndDrop, size: icon)
            .frame(width: box, height: box)
            .foregroundStyle(.theme(isHovered || isFocused ? .fgBrand : .fgHeading))
            .background(BWControlShape().fill(.theme(isHovered || isFocused ? .bgHover : .clear)))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .pointerStyle(.grabIdle)
            .help(label)
            .accessibilityLabel(label)
            .focusable()
            .focused($isFocused)
            .onKeyPress(.upArrow) {
                guard index > 0 else { return .ignored }
                move(index, index - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard index < count - 1 else { return .ignored }
                move(index, index + 1)
                return .handled
            }
            .onDrag {
                dragged = index
                return NSItemProvider(object: label as NSString)
            }
    }
}

/// A row of a reordered list as the place a dragged row is dropped on.
private struct ReorderDrop: DropDelegate {
    let index: Int
    @Binding var dragged: Int?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = dragged, source != index else { return }
        move(source, index)
        dragged = index
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
