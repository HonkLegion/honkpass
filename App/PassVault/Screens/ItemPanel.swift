import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The panel of one item beside the list: all its fields, read-only, with the reveal and copy buttons.
/// Reference: docs/reference/item-*.png. Source: libs/vault/src/vault-item-dialog (the frame and its
/// footer) and libs/vault/src/cipher-view (the sections).
///
/// The reference asks for the master password when a protected item opens, not for each field in it.
/// "Edit" puts the form of the item in the place of this panel (ItemFormPanel).
struct ItemPanel: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemID: String

    @State private var item: VaultItem?

    /// The hidden fields that are shown in clear.
    private var revealed: Set<String> { navigation.revealedFields }

    private struct LoadKey: Hashable {
        let id: String
        let sync: Date?
    }

    var body: some View {
        BWDrawer(title: title, startsAtEnd: navigation.itemPanelStartsAtEnd, floatingFooter: true, fadingHeader: true,
                 onClose: { navigation.openItemID = nil }) {
            if let item {
                sections(item)
            }
        } footer: {
            footer
        }
        // The reference moves the focus from the search field to the opened panel.
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
        // A sync can change the open item.
        .task(id: LoadKey(id: itemID, sync: model.state.vault.lastSync)) {
            do {
                item = try await model.item(id: itemID)
            } catch EngineError.itemNotReadable {
                // A part of the item did not decrypt: nothing of it is shown, and a dialog says why.
                if navigation.openItemID == itemID {
                    navigation.openItemID = nil
                    navigation.decryptionFailureItemID = itemID
                }
            } catch {
                // The item is gone, or the vault is locked.
                if navigation.openItemID == itemID { navigation.openItemID = nil }
            }
        }
    }

    private var summary: VaultItemSummary? {
        model.state.vault.items.first { $0.id == itemID }
    }

    /// The title of vault-item-dialog.component.ts in view mode.
    private var title: String {
        switch item?.type ?? summary?.type {
        case .login: BWText["viewItemHeaderLoginSentenceCase"]
        case .card: BWText["viewItemHeaderCardSentenceCase"]
        case .identity: BWText["viewItemHeaderIdentitySentenceCase"]
        case .secureNote: BWText["viewItemHeaderNoteSentenceCase"]
        case .sshKey: BWText["viewItemHeaderSshKey"]
        case nil: ""
        }
    }

    // MARK: Sections

    /// The order of cipher-view.component.html. Every section has "tw-mb-5"; the item history has none.
    @ViewBuilder
    private func sections(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            details(item).padding(.bottom, Metric.space(5))
            switch item.content {
            case .login(let login):
                if login.username?.isEmpty == false || login.password?.isEmpty == false || login.hasVerificationCode
                    || login.passkeyCreated != nil {
                    credentials(login)
                }
                if !login.pages.isEmpty { websites(login.pages) }
                if !login.apps.isEmpty { apps(login.apps) }
            case .card(let card):
                self.card(card)
            case .identity(let identity):
                self.identity(identity)
            case .sshKey(let key):
                sshKey(key)
            case .secureNote:
                EmptyView()
            }
            if let notes = item.notes, !notes.isEmpty { self.notes(notes) }
            if !item.customFields.isEmpty { customFields(item.customFields) }
            if !item.attachments.isEmpty { attachments(item) }
            history(item)
        }
    }

    /// One `section` of the item view: an optional title over a card.
    private func section(_ title: String?, hasMargin: Bool = true, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { BWSectionHeader(title) }
            BWCard(content: content)
        }
        .padding(.bottom, hasMargin ? Metric.space(5) : 0)
    }

    /// The form fields of one card, "tw-mb-4" apart.
    private func fields(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metric.space(4), content: content)
    }

    // MARK: Item details

    /// item-details-v2: the picture and the name, then where the item is.
    private func details(_ item: VaultItem) -> some View {
        section(nil, hasMargin: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    // A box of 40 pixels around app-vault-icon. The desktop styles give the icon
                    // "margin-left: -5px", which leaves it half a pixel left of the box.
                    picture(item)
                        .frame(width: 36, height: 36)
                        .frame(width: 40, height: 40, alignment: .leading)
                        .offset(x: -0.5)
                    // h2 bitTypography="h4" "tw-ml-2 tw-mt-2 tw-flex-1 tw-break-all tw-line-clamp-2" with the "tw-mb-2" of h4.
                    Text(item.name)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .textStyle(.h4)
                        .foregroundStyle(.theme(.textMain))
                        .padding(.vertical, Metric.space(2))
                        .padding(.leading, Metric.space(2))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // div "tw-flex tw-flex-col tw-mt-2 md:tw-flex-row md:tw-flex-wrap" with one
                // span "tw-flex tw-items-center tw-mt-2 tw-mr-4" bitTypography="body2" for the
                // organization, each collection and the folder; "no folder" when there is none of them.
                let places = places(of: item)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                        HStack(alignment: .center, spacing: 0) {
                            // i "bwi bwi-lg"
                            IconView(place.icon, size: TextStyle.sm.size * 4 / 3)
                            // span "tw-pl-1.5"
                            Text(place.name)
                                .lineLimit(1)
                                .textStyle(.sm)
                                .padding(.leading, Metric.space(1.5))
                        }
                        .padding(.top, Metric.space(2))
                    }
                }
                .padding(.top, Metric.space(2))
            }
        }
    }

    /// `allItems` of item-details-v2: the organization, its collections the item is in, the folder.
    private func places(of item: VaultItem) -> [(icon: BWIcon, name: String)] {
        let vault = model.state.vault
        var places: [(icon: BWIcon, name: String)] = []
        if let summary, let organization = vault.organizationName(of: summary) {
            places.append((.business, organization))
            for collection in vault.collections where summary.collectionIDs.contains(collection.id) {
                places.append((.collectionShared, collection.name))
            }
        }
        if let folder = folderName(of: item) { places.append((.folder, folder)) }
        return places.isEmpty ? [(.folder, BWText["noneFolder"])] : places
    }

    private func folderName(of item: VaultItem) -> String? {
        guard let id = item.folderID else { return nil }
        return model.state.vault.folders.first { $0.id == id }?.name
    }

    /// app-vault-icon with `coloredIcon`: the picture of the website or of the card brand at 36 pixels,
    /// else the icon of the type on a round ground.
    @ViewBuilder
    private func picture(_ item: VaultItem) -> some View {
        if case .card(let card) = item.content, let brand = card.brand, CardBrandImage.exists(for: brand) {
            // The card pictures are 36 by 30 pixels here.
            CardBrandImage(brand: brand, width: 36, height: 30)
        } else if let host = summary?.websiteHost {
            WebsiteIcon(model: model, host: host, size: 36) { typeIcon(.login) }
        } else {
            typeIcon(item.type)
        }
    }

    /// div "tw-bg-illustration-bg-primary tw-rounded-full" around i "bwi bwi-lg" in the colour
    /// "--color-illustration-outline".
    private func typeIcon(_ type: ItemType) -> some View {
        IconView(VaultScreen.icon(for: type), size: TextStyle.body.size * 4 / 3)
            .foregroundStyle(.theme(.illustrationOutline))
            .frame(width: 36, height: 36)
            .background(Circle().fill(.theme(.illustrationBgPrimary)))
    }

    // MARK: Login

    /// login-credentials-view
    private func credentials(_ login: LoginContent) -> some View {
        section(BWText["loginCredentials"]) {
            fields {
                if let username = login.username, !username.isEmpty {
                    plainField("username", username, copyLabel: BWText["copyUsername"])
                }
                if let password = login.password, !password.isEmpty {
                    passwordField(password, hasCodeAfter: login.hasVerificationCode)
                }
                if let created = login.passkeyCreated {
                    // The field "passkey": "created" and the short date of the language.
                    BWReadOnlyField(BWText["typePasskey"]) {
                        BWFieldValue(BWText["dateCreated"] + " " + Self.short(created))
                    }
                }
                if login.hasVerificationCode {
                    VerificationCodeField(model: model, itemID: itemID) {
                        copied(BWText["verificationCodeTotp"])
                    }
                }
            }
        }
    }

    /// The password: eight bullets, or the coloured password in "tw-font-mono" with the button
    /// that numbers its characters.
    private func passwordField(_ password: String, hasCodeAfter: Bool) -> some View {
        let isRevealed = revealed.contains("password")
        return VStack(alignment: .leading, spacing: 0) {
            BWReadOnlyField(BWText["password"]) {
                if isRevealed {
                    // span role="textbox" in the content box of the field: it starts at its top.
                    BWColorPassword(password)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    // `maskedPassword` is always eight bullets.
                    BWFieldValue(String(repeating: "x", count: 8), isHidden: true)
                }
            } suffix: {
                if isRevealed {
                    // The texts "showCharacterCount" and "hideCharacterCount" are not in the desktop locale files.
                    BWIconButton(.numberedList, label: "", size: .small) { navigation.showsPasswordCount.toggle() }
                }
                revealButton("password")
                copyButton(BWText["copyPassword"], password, label: BWText["password"], isSensitive: true)
            }
            if isRevealed, navigation.showsPasswordCount {
                // div with "tw-mt-3" unless a verification code follows, and "tw-mb-2".
                BWColorPassword(password, showsCount: true)
                    .padding(.top, hasCodeAfter ? 0 : Metric.space(3))
                    .padding(.bottom, Metric.space(2))
            }
        }
    }

    /// autofill-options-view: one field for each website, with a launch and a copy button.
    private func websites(_ websites: [String]) -> some View {
        section(BWText["autofillOptions"]) {
            fields {
                ForEach(Array(websites.enumerated()), id: \.offset) { _, website in
                    let shown = LoginContent.displayText(ofWebsite: website)
                    BWReadOnlyField(BWText["website"]) {
                        BWFieldValue(shown)
                    } suffix: {
                        BWIconButton(.externalLink, label: BWText["launch"] + " " + shown, size: .small) {
                            if let url = LoginContent.launchURL(ofWebsite: website) { NSWorkspace.shared.open(url) }
                        }
                        .disabled(LoginContent.launchURL(ofWebsite: website) == nil)
                        copyButton(BWText["copyWebsite"], website, label: BWText["website"])
                    }
                }
            }
        }
    }

    /// The apps of the login: one row for each, with the button that copies its address.
    /// PassVault's own section (PLAN.md, "Differences from the reference").
    private func apps(_ apps: [AppAddress]) -> some View {
        section(BWText["app"]) {
            VStack(alignment: .leading, spacing: Metric.space(2)) {
                ForEach(apps, id: \.self) { app in
                    LoginAppRow(app) {
                        copyButton(BWText["copyUri"], app.address, label: BWText["uri"])
                    }
                }
            }
        }
    }

    // MARK: Card

    /// card-details-view
    private func card(_ card: CardContent) -> some View {
        section(card.namedBrand.map { BWText["cardBrandDetails", $0] } ?? BWText["cardDetails"]) {
            fields {
                if let name = card.cardholderName, !name.isEmpty {
                    // "copyCardholderName" is not in the desktop locale files.
                    plainField("cardholderName", name, copyLabel: "")
                }
                if let number = card.formattedNumber {
                    hiddenField("number", number, key: "cardNumber", isMonospaced: true, copyLabel: BWText["copyNumber"],
                                copied: card.number ?? number)
                }
                if let expiration = card.expiration {
                    BWReadOnlyField(BWText["expiration"]) { BWFieldValue(expiration) }
                }
                if let code = card.securityCode, !code.isEmpty {
                    hiddenField("securityCode", code, key: "cardCode", isMonospaced: true, copyLabel: BWText["copySecurityCode"])
                }
            }
        }
    }

    // MARK: Identity

    /// view-identity-sections: a section is there when one of its fields has a value.
    @ViewBuilder
    private func identity(_ identity: IdentityContent) -> some View {
        if has(identity.fullName) || has(identity.username) || has(identity.company) {
            section(BWText["personalDetails"]) {
                fields {
                    if let name = identity.fullName { plainField("name", name, copyLabel: BWText["copyName"]) }
                    if let username = filled(identity.username) { plainField("username", username, copyLabel: BWText["copyUsername"]) }
                    // "copyCompany" is not in the desktop locale files.
                    if let company = filled(identity.company) { plainField("company", company, copyLabel: "") }
                }
            }
        }
        if has(identity.socialSecurityNumber) || has(identity.passportNumber) || has(identity.licenseNumber) {
            section(BWText["identification"]) {
                fields {
                    if let number = filled(identity.socialSecurityNumber) {
                        // "copySSN" is not in the desktop locale files.
                        hiddenField("ssn", number, key: "ssn", copyLabel: "")
                    }
                    if let number = filled(identity.passportNumber) {
                        hiddenField("passportNumber", number, key: "passport", copyLabel: BWText["copyPassportNumber"])
                    }
                    if let number = filled(identity.licenseNumber) {
                        plainField("licenseNumber", number, copyLabel: BWText["copyLicenseNumber"])
                    }
                }
            }
        }
        if has(identity.email) || has(identity.phone) || has(identity.fullAddress) {
            section(BWText["contactInfo"]) {
                fields {
                    if let email = filled(identity.email) { plainField("email", email, copyLabel: BWText["copyEmail"]) }
                    if let phone = filled(identity.phone) { plainField("phone", phone, copyLabel: BWText["copyPhone"]) }
                    if let address = identity.fullAddress {
                        // textarea [rows]="addressRows": as many rows as the address has lines.
                        BWReadOnlyField(BWText["address"], isTextArea: true) {
                            BWFieldText(address, rows: address.split(separator: "\n", omittingEmptySubsequences: false).count)
                        } suffix: {
                            copyButton(BWText["copyAddress"], address, label: BWText["address"])
                        }
                    }
                }
            }
        }
    }

    private func filled(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
    }

    private func has(_ text: String?) -> Bool {
        filled(text) != nil
    }

    // MARK: SSH key

    /// sshkey-view
    private func sshKey(_ key: SSHKeyContent) -> some View {
        section(BWText["typeSshKey"]) {
            fields {
                hiddenField("sshPrivateKey", key.privateKey, key: "privateKey", copyLabel: BWText["copyPrivateKey"])
                plainField("sshPublicKey", key.publicKey, copyLabel: BWText["copyPublicKey"])
                plainField("sshFingerprint", key.fingerprint, copyLabel: BWText["copyFingerprint"])
            }
        }
    }

    // MARK: Notes and custom fields

    /// additional-options: the note in a textarea of five rows. Its label "note" is not in the
    /// desktop locale files, so the field has none; the toast of the copy button has no label either.
    private func notes(_ notes: String) -> some View {
        section(BWText["additionalOptions"]) {
            BWReadOnlyField("", isTextArea: true) {
                BWFieldText(notes, rows: 5)
            } suffix: {
                copyButton(BWText["copyNotes"], notes, label: "")
            }
        }
    }

    /// custom-fields-v2: every field in its own block, "tw-mb-4" apart.
    private func customFields(_ customFields: [CustomField]) -> some View {
        section(BWText["customFields"]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(customFields.enumerated()), id: \.offset) { index, field in
                    customField(field, index: index)
                        .padding(.bottom, index == customFields.count - 1 ? 0 : Metric.space(4))
                }
            }
        }
    }

    @ViewBuilder
    private func customField(_ field: CustomField, index: Int) -> some View {
        switch field.value {
        case .text(let value):
            // textarea vaultAutosizeReadOnlyTextArea: as high as its text.
            BWReadOnlyField(field.name, isTextArea: true) {
                BWFieldText(value)
            } suffix: {
                if !value.isEmpty { copyButton(BWText["copyCustomField", field.name], value, label: field.name) }
            }
        case .hidden(let value):
            let key = "custom-\(index)"
            let isRevealed = revealed.contains(key)
            // input type="password" "tw-font-mono"; shown, it is a textarea in the same font.
            BWReadOnlyField(field.name, isTextArea: isRevealed) {
                if isRevealed {
                    BWFieldText(value, isMonospaced: true)
                } else {
                    BWFieldValue(value, isHidden: true, isMonospaced: true)
                }
            } suffix: {
                if !value.isEmpty {
                    revealButton(key)
                    copyButton(BWText["copyCustomField", field.name], value, label: field.name, isSensitive: true)
                }
            }
        case .boolean(let isOn):
            // bit-form-control: a disabled checkbox with its label. It keeps its "tw-mb-4".
            BWCheckbox(field.name, isOn: .constant(isOn))
                .disabled(true)
                .padding(.bottom, Metric.space(4))
        case .linked(let linkedField):
            // custom-fields-v2: the value is the label of the field it shows.
            BWReadOnlyField(BWText["cfTypeLinked"] + ": " + field.name) {
                BWFieldValue(LinkedField.labelKey(linkedField).map { BWText[$0] } ?? "")
            }
        }
    }

    // MARK: Attachments

    /// attachments-v2-view: one row for each file with the button that downloads it. A protected
    /// item asks for the master password again (`checkPwReprompt`).
    private func attachments(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(BWText["attachments"])
            ForEach(item.attachments) { attachment in
                AttachmentRow(attachment: attachment) {
                    BWIconButton(.download, label: BWText["downloadAttachmentName", attachment.fileName]) {
                        let download = { @MainActor in
                            ItemActions(model: model, navigation: navigation, isPanel: true).download(attachment, ofItem: item.id)
                        }
                        if let summary { navigation.perform(on: summary, download) } else { download() }
                    }
                    // bit-item-action "tw-pr-4 [@media(min-width:650px)]:tw-pr-6"
                    .padding(.trailing, Metric.space(4))
                }
            }
        }
        .padding(.bottom, Metric.space(5))
    }

    // MARK: Item history

    /// item-history-v2: when the item was edited and made, in "tw-text-xs tw-text-muted".
    private func history(_ item: VaultItem) -> some View {
        section(BWText["itemHistory"], hasMargin: false) {
            VStack(alignment: .leading, spacing: 0) {
                historyLine("lastEdited", item.revised)
                    .padding(.bottom, Metric.space(1))
                // "tw-mb-1" when the item has a password history, else "tw-mb-0".
                historyLine("dateCreated", item.created)
                    .padding(.bottom, item.passwordHistoryCount > 0 ? Metric.space(1) : 0)
                if let passwordRevised = item.passwordRevised {
                    // "tw-mb-3" with a password history; without one the paragraph keeps the 10 pixels
                    // that the desktop styles give every `p`.
                    historyLine("datePasswordUpdated", passwordRevised)
                        .padding(.bottom, item.passwordHistoryCount > 0 ? Metric.space(3) : 10)
                }
                if item.passwordHistoryCount > 0 {
                    BWLink(BWText["passwordHistory"], size: TextStyle.sm.size) { navigation.passwordHistoryItemID = item.id }
                }
            }
        }
    }

    private func historyLine(_ key: String, _ date: Date) -> some View {
        // p: span "tw-font-medium" with the label and a colon, then the date as Angular's "medium".
        Text("\(Text(BWText[key] + ":").font(BWFont.inter(TextStyle.xs.size, weight: 500))) \(Self.medium(date))")
            .textSelection(.enabled)
            .textStyle(.xs)
            .foregroundStyle(.theme(.textMuted))
    }

    /// The "medium" date of Angular: the medium date and time of the language, joined as its
    /// locale data says ("Nov 12, 2026, 9:49:57 PM", "12. 11. 2026 21:49:57").
    static func medium(_ date: Date) -> String {
        BWDate.medium(date)
    }

    /// The "short" date of Angular: the short date and time of the language ("11/12/26, 9:49 PM",
    /// "12.11.26 21:49").
    static func short(_ date: Date) -> String {
        BWDate.short(date)
    }

    // MARK: Fields and buttons

    /// A field with a text and a copy button. `labelKey` is also the label of the toast.
    private func plainField(_ labelKey: String, _ value: String, copyLabel: String) -> some View {
        BWReadOnlyField(BWText[labelKey]) {
            BWFieldValue(Self.oneLine(value))
        } suffix: {
            copyButton(copyLabel, value, label: BWText[labelKey])
        }
    }

    /// An `input type="password"` with the eye button and a copy button.
    private func hiddenField(_ labelKey: String, _ value: String, key: String, isMonospaced: Bool = false,
                             copyLabel: String, copied: String? = nil) -> some View {
        BWReadOnlyField(BWText[labelKey]) {
            BWFieldValue(Self.oneLine(value), isHidden: !revealed.contains(key), isMonospaced: isMonospaced)
        } suffix: {
            revealButton(key)
            copyButton(copyLabel, copied ?? value, label: BWText[labelKey], isSensitive: true)
        }
    }

    /// An `input` shows its value on one line.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    /// bitPasswordInputToggle: "bwi-eye", or "bwi-eye-slash" while the value is shown.
    private func revealButton(_ key: String) -> some View {
        let isRevealed = revealed.contains(key)
        return BWIconButton(isRevealed ? .eyeSlash : .eye, label: BWText["toggleVisibility"], size: .small) {
            if isRevealed {
                navigation.revealedFields.remove(key)
                if key == "password" { navigation.showsPasswordCount = false }
            } else {
                navigation.revealedFields.insert(key)
            }
        }
    }

    /// appCopyClick with showToast: copies the value and says so.
    private func copyButton(_ buttonLabel: String, _ value: String, label: String, isSensitive: Bool = false) -> some View {
        BWIconButton(.clone, label: buttonLabel, size: .small) {
            Task {
                guard (try? await model.copy(text: value, isSensitive: isSensitive)) != nil else { return }
                copied(label)
            }
        }
    }

    /// The toast of copy-click.directive.ts: "valueCopied" with the label of the field, or
    /// "copySuccessful" when the field has none.
    private func copied(_ label: String) {
        navigation.copied(label.isEmpty ? BWText["copySuccessful"] : BWText["valueCopied", label])
    }

    // MARK: Footer

    /// The footer of vault-item-dialog in view mode: "edit", then at the end the archive or the
    /// unarchive button and the delete button; for an item in the trash "restore" and the delete button.
    /// The marks come from the list, which follows every change at once.
    @ViewBuilder
    private var footer: some View {
        let actions = ItemActions(model: model, navigation: navigation, isPanel: true)
        let isInTrash = summary?.isInTrash ?? item?.isInTrash ?? false
        let isArchived = summary?.isArchived ?? item?.isArchived ?? false
        if isInTrash {
            BWButton(BWText["restore"], kind: .primary, isBlock: false) {
                if let summary { actions.restore(summary) }
            }
        } else if summary?.isReadOnly != true {
            BWButton(BWText["edit"], kind: .primary, isBlock: false) {
                if let summary { actions.edit(summary) }
            }
        }
        Spacer(minLength: 0)
        // div "tw-ml-auto": the buttons follow each other; the archive button has "tw-mr-1".
        HStack(spacing: 0) {
            if !isInTrash {
                Group {
                    if isArchived {
                        BWIconButton(.unarchive, label: BWText["unArchive"]) { if let summary { actions.unarchive(summary) } }
                    } else {
                        BWIconButton(.archive, label: BWText["archiveVerb"]) { if let summary { actions.archive(summary) } }
                    }
                }
                .padding(.trailing, Metric.space(1))
            }
            if summary?.canDelete != false {
                BWIconButton(.trash, label: BWText["delete"], kind: .dangerGhost) {
                    if let summary { actions.delete(summary) }
                }
            }
        }
        .floatingActionCapsule()
        .disabled(summary == nil)
    }
}

/// The verification code of a login with the countdown of its period and a copy button.
/// The code is asked from the engine again when its period ends.
private struct VerificationCodeField: View {
    let model: AppModel
    let itemID: String
    let onCopy: () -> Void
    @State private var code: VerificationCode?

    var body: some View {
        // totp.service.ts looks at the clock once a second. Here every look is at a full second.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), by: 1)) { timeline in
            let remaining = code?.remainingSeconds(at: timeline.date)
            BWReadOnlyField(BWText["verificationCodeTotp"]) {
                // input "tw-font-mono"; "*** ***" until the code is there.
                BWFieldValue(code?.formatted ?? "*** ***", isMonospaced: true)
            } suffix: {
                if let code, let remaining {
                    BWTotpCountdown(remaining: remaining, period: code.period)
                }
                BWIconButton(.clone, label: BWText["copyVerificationCode"], size: .small) {
                    Task {
                        guard (try? await model.copy(.verificationCode, of: itemID)) != nil else { return }
                        onCopy()
                    }
                }
                .disabled(code == nil)
            }
            // A new period has a new code. Until the first code is there, the usual period stands in.
            .task(id: Int(timeline.date.timeIntervalSince1970) / max(code?.period ?? 30, 1)) {
                code = try? await model.verificationCode(for: itemID)
            }
        }
    }
}
