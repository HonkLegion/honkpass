import DesignKit
import SwiftUI
import VaultModel

/// `app-vault-icon`: the picture of the brand of a card, the icon of the website of a login,
/// or the icon of the type of the item.
struct ItemRowIcon: View {
    let model: AppModel
    let item: VaultItemSummary

    var body: some View {
        if let brand = item.cardBrand, CardBrandImage.exists(for: brand) {
            CardBrandImage(brand: brand)
        } else if let host = item.websiteHost {
            WebsiteIcon(model: model, host: host) {
                IconView(.globe, size: TextStyle.body.size * 4 / 3)
                    .foregroundStyle(.theme(.textMuted))
            }
        } else {
            IconView(Self.icon(for: item.type), size: TextStyle.body.size * 4 / 3)
                .foregroundStyle(.theme(.textMuted))
        }
    }

    static func icon(for type: ItemType) -> BWIcon {
        switch type {
        case .login: .globe
        case .secureNote: .stickyNote
        case .card: .creditCard
        case .identity: .idCard
        case .sshKey: .key
        }
    }
}
