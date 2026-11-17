import AppKit
import DesignKit
import SwiftUI
import VaultModel

/// `vault-item-copy-actions` (libs/vault/src/components/item-copy-actions): the copy buttons at
/// the end of a row of items. A button for a field the item does not have is disabled.
struct ItemCopyActions: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation
    let item: VaultItemSummary
    /// `showQuickCopyActions`: a login and a card have a button for each of their fields. Without
    /// it they have one button with a menu, as an identity and an SSH key always have.
    let showsQuickCopy: Bool
    /// What `openCopyMenuItemID` holds while the menu of this row is open: the item, unless a
    /// list shows an item in two rows.
    var menuID: String?

    private var copier: ItemCopier { ItemCopier(model: model, navigation: navigation) }

    var body: some View {
        // host: "tw-flex tw-items-center tw-gap-2 [&_button[biticonbutton]]:-tw-mx-1"
        HStack(spacing: Metric.space(2)) {
            switch item.type {
            case .login where showsQuickCopy:
                copyButton(.user, "copyUsername", "noUsername", .username)
                copyButton(.key, "copyPassword", "noPassword", .password)
                copyButton(.clock, "copyVerificationCode", "noVerificationCode", .verificationCode)
            case .login:
                copyMenuButton([(.username, "copyUsername"), (.password, "copyPassword"), (.verificationCode, "copyVerificationCode")],
                               copiesSingleValue: true)
            case .card where showsQuickCopy:
                copyButton(.hashtag, "copyNumber", "noNumber", .cardNumber)
                copyButton(.key, "copySecurityCode", "noSecurityCode", .cardSecurityCode)
            case .card:
                copyMenuButton([(.cardNumber, "copyNumber"), (.cardSecurityCode, "copySecurityCode")], copiesSingleValue: true)
            case .secureNote:
                BWIconButton(.clone, label: BWText["copyNote"], size: .small) { copier.copy(.notes, of: item) }
                    .disabled(!item.fields.contains(.notes))
                    .padding(.horizontal, -Metric.space(1))
            case .identity:
                copyMenuButton([
                    (.identityUsername, "copyUsername"), (.identityEmail, "copyEmail"),
                    (.identityPhone, "copyPhone"), (.identityAddress, "copyAddress"),
                ], copiesSingleValue: true)
            case .sshKey:
                // A list knows only that the item has a key; its three parts come together.
                copyMenuButton(item.fields.contains(.sshKey) ? [
                    (.sshKey, "copyPrivateKey"), (.sshPublicKey, "copyPublicKey"), (.sshFingerprint, "copyFingerprint"),
                ] : [], copiesSingleValue: false, hasEveryField: true)
            }
        }
    }

    /// One copy button that opens a menu with the fields the item has. With one such field it
    /// copies it at once (`findSingleCopyableItem`); an item with none has the button disabled.
    @ViewBuilder
    private func copyMenuButton(_ all: [(field: ItemField, key: String)], copiesSingleValue: Bool,
                                hasEveryField: Bool = false) -> some View {
        let offered = all.filter { hasEveryField || item.fields.contains($0.field) }
        Group {
            if copiesSingleValue, offered.count == 1, let only = offered.first {
                BWIconButton(.clone, label: BWText[only.key], size: .small) { copier.copy(only.field, of: item) }
            } else {
                BWIconButton(.clone, label: BWText[offered.isEmpty ? "noDetailsToCopy" : "copy"], size: .small) {
                    navigation.openCopyMenuItemID = menuID ?? item.id
                }
                .disabled(offered.isEmpty)
                .bwMenu(isOpen: Binding(get: { navigation.openCopyMenuItemID == menuID ?? item.id },
                                        set: { if !$0 { navigation.openCopyMenuItemID = nil } })) {
                    offered.map { entry in BWMenuItem(BWText[entry.key]) { copier.copy(entry.field, of: item) } }
                }
            }
        }
        .padding(.horizontal, -Metric.space(1))
    }

    private func copyButton(_ icon: BWIcon, _ key: String, _ missingKey: String, _ field: ItemField) -> some View {
        let has = item.fields.contains(field)
        return BWIconButton(icon, label: BWText[has ? key : missingKey], size: .small) { copier.copy(field, of: item) }
            .disabled(!has)
            .padding(.horizontal, -Metric.space(1))
    }
}

/// Copies a field of an item of a list, as copy-cipher-field.service.ts: a user name and a
/// website at once, the other fields after the master password when the item asks for it,
/// and then the toast that names what was copied.
@MainActor
struct ItemCopier {
    let model: AppModel
    let navigation: VaultNavigation

    func copy(_ field: ItemField, of item: VaultItemSummary) {
        let copy = { @MainActor [model, navigation] in
            _ = Task {
                guard (try? await model.copy(field, of: item.id)) != nil else { return }
                navigation.copied(BWText["valueCopied", BWText[Self.toastKey(for: field)]])
            }
        }
        if field.isPublic {
            copy()
        } else {
            navigation.perform(on: item, copy)
        }
    }

    /// Opens the first website of a login in the browser.
    func launch(_ item: VaultItemSummary) {
        Task { [model] in
            guard let website = try? await model.item(id: item.id).value(of: .website),
                  let url = LoginContent.launchURL(ofWebsite: website) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// `typeI18nKey` of the copy actions.
    static func toastKey(for field: ItemField) -> String {
        switch field {
        case .username, .identityUsername: "username"
        case .password: "password"
        case .verificationCode: "verificationCode"
        case .website: "website"
        case .cardNumber: "number"
        case .cardSecurityCode: "securityCode"
        case .identityEmail: "email"
        case .identityPhone: "phone"
        case .identityAddress: "address"
        case .sshKey: "sshPrivateKey"
        case .sshPublicKey: "sshPublicKey"
        case .sshFingerprint: "sshFingerprint"
        case .notes: "typeSecureNote"
        }
    }
}
