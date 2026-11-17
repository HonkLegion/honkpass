import DesignKit
import Engine
import SwiftUI
import VaultModel

/// "Assign to collections": gives an item of the user to an organization and puts it into
/// collections, or sets the collections of an item of an organization.
/// Source: libs/vault/src/components/assign-collections.component.html and its dialog. No
/// reference picture yet.
struct AssignCollectionsDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemID: String
    @State private var organizationID: String?
    @State private var chosen: [String] = []
    @State private var isSending = false

    private var vault: VaultContents { model.state.vault }
    private var item: VaultItemSummary? { vault.items.first { $0.id == itemID } }
    private var organization: VaultOrganization? { vault.organizations.first { $0.id == organizationID } }

    var body: some View {
        let isOwn = item?.organizationID == nil
        BWDialog(title: BWText["assignToCollections"], onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                Text(BWText["bulkCollectionAssignmentDialogDescriptionSingular"])
                    .textStyle(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isOwn {
                    // ul "tw-list-disc tw-pl-5": the item leaves the vault of the user for good.
                    HStack(alignment: .firstTextBaseline, spacing: Metric.space(2)) {
                        Text("•")
                        Text(organization.map { BWText["personalItemWithOrgTransferWarningSingular", $0.name] }
                            ?? BWText["personalItemTransferWarningSingular"])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .textStyle(.body)
                    .padding(.leading, Metric.space(2))
                    .padding(.top, Metric.space(2))
                }
                Spacer().frame(height: Metric.space(4))
                if isOwn {
                    BWSelect(BWText["moveToOrganization"], selection: Binding(get: { organizationID }, set: { id in
                        organizationID = id
                        chosen = []
                    }), options: vault.organizations.map { .init($0.id, $0.name) })
                }
                BWFieldLabel(BWText["selectCollectionsToAssign"])
                    .padding(.bottom, Metric.space(2))
                CollectionChoice(collections: organizationID.map { vault.assignableCollections(of: $0) } ?? [], chosen: $chosen)
            }
            .foregroundStyle(.theme(.textMain))
        } footer: {
            BWButton(BWText["assign"], kind: .primary, isBlock: false, action: assign)
                .disabled(isSending || chosen.isEmpty || organization == nil)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onAppear {
            // An item of an organization starts with the collections it is in; an item of the
            // user with the first organization of the account.
            organizationID = item?.organizationID ?? vault.organizations.first?.id
            let open = Set(organizationID.map { vault.assignableCollections(of: $0).map(\.id) } ?? [])
            chosen = (item?.collectionIDs ?? []).filter(open.contains)
        }
        .onExitCommand(perform: close)
    }

    private func assign() {
        guard let item, let organization, !chosen.isEmpty else { return }
        ItemActions(model: model, navigation: navigation).assign(item, to: organization, collectionIDs: chosen)
    }

    private func close() {
        navigation.assignItemID = nil
    }
}

/// The collections an item goes into: one checkbox for each. The reference has a field with a
/// list that opens (`bit-multi-select`); PLAN.md, differences.
struct CollectionChoice: View {
    let collections: [VaultCollection]
    @Binding var chosen: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space(2)) {
            if collections.isEmpty {
                Text(BWText["noCollectionsAssigned"])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
            }
            ForEach(collections) { collection in
                BWCheckbox(collection.name, isOn: Binding(get: { chosen.contains(collection.id) }, set: { isOn in
                    if isOn {
                        if !chosen.contains(collection.id) { chosen.append(collection.id) }
                    } else {
                        chosen.removeAll { $0 == collection.id }
                    }
                }))
            }
        }
    }
}
