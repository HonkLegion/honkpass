import SwiftUI

/// The tab row of `bit-tab-group`: libs/components/src/tabs. The labels are 24 pixels apart; the
/// chosen one is semibold in the brand colour over a line of two pixels that covers the border
/// under the row. Put the content of the chosen tab under it, after "tw-pt-5".
public struct BWTabs<ID: Hashable>: View {
    private let tabs: [(id: ID, label: String)]
    @Binding private var selection: ID

    public init(_ tabs: [(id: ID, label: String)], selection: Binding<ID>) {
        self.tabs = tabs
        _selection = selection
    }

    public var body: some View {
        // bit-tab-header: "tw-flex tw-items-end tw-border-0 tw-border-b tw-border-solid tw-border-border-base";
        // the list has "tw-leading-5" and a gap of 24 pixels.
        HStack(alignment: .bottom, spacing: 24) {
            ForEach(tabs, id: \.id) { tab in
                Tab(label: tab.label, isSelected: tab.id == selection) { selection = tab.id }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 1)
        .background(alignment: .bottom) {
            Rectangle().fill(.theme(.borderBase)).frame(height: 1)
        }
    }

    /// bitTabListItem: "tw-pb-3 tw-text-sm tw-font-medium", the label in a span "tw-h-6";
    /// "after:tw-h-[2px] after:tw-bg-bg-brand after:-tw-bottom-px"; chosen "tw-font-semibold !tw-text-fg-brand",
    /// else "!tw-text-fg-body hover:!tw-text-fg-brand".
    private struct Tab: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(label)
                    .lineLimit(1)
                    .textStyle(TextStyle(size: TextStyle.sm.size, lineHeight: 1.25 * Metric.rem, weight: isSelected ? 600 : 500))
                    .frame(height: Metric.space(6))
                    .padding(.bottom, Metric.space(3))
                    .foregroundStyle(.theme(isSelected || isHovered ? .fgBrand : .fgBody))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(.theme(.bgBrand))
                            .frame(height: 2)
                            .offset(y: 1)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
