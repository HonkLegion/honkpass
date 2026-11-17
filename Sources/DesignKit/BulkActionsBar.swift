import SwiftUI

/// `bit-bulk-actions-bar`: libs/components/src/bulk-actions-bar. The bar that floats over the
/// bottom of a list while rows are ticked: how many, "clear", then the actions.
/// "tw-flex tw-items-center tw-gap-[17px] tw-p-2 tw-rounded-xl tw-bg-bg-brand-stronger"; it keeps
/// its "tw-mb-4". Put it at the bottom of the list it belongs to.
public struct BWBulkActionsBar: View {
    public struct Action {
        let title: String
        let icon: BWIcon
        let action: () -> Void

        public init(_ title: String, icon: BWIcon, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.action = action
        }
    }

    private let count: Int
    private let onClear: () -> Void
    private let actions: [Action]

    public init(count: Int, onClear: @escaping () -> Void, actions: [Action]) {
        self.count = count
        self.onClear = onClear
        self.actions = actions
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 17) {
            // span "tw-flex tw-gap-1.5 tw-px-2 tw-text-sm": the number "tw-font-semibold tw-text-fg-contrast",
            // the word "tw-text-fg-contrast-strong"
            HStack(spacing: Metric.space(1.5)) {
                Text(String(count))
                    .textStyle(.sm.weight(600))
                    .foregroundStyle(.theme(.fgContrast))
                Text(BWText["selectedLowercase"])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.fgContrastStrong))
            }
            .padding(.horizontal, Metric.space(2))
            .overlay(alignment: .trailing) { divider }
            BarButton(title: BWText["clear"], icon: .clear, action: onClear)
                .overlay(alignment: .trailing) { divider }
            // The actions, "gap 8" apart.
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    BarButton(title: action.title, icon: action.icon, action: action.action)
                }
            }
        }
        .padding(Metric.space(2))
        .background(BWControlShape().fill(.theme(.bgBrandStronger)))
        .fixedSize()
        .padding(.bottom, Metric.space(4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BWText["bulkActionsBar"])
    }

    /// "after:tw-bg-bg-brand-strong after:tw-w-px after:tw-h-8", moved to the middle of the gap
    /// that follows ("after:tw-translate-x-[calc(theme(spacing.2)_+_1px)]").
    private var divider: some View {
        Rectangle()
            .fill(.theme(.bgBrandStrong))
            .frame(width: 1, height: Metric.space(8))
            .offset(x: Metric.space(2) + 1)
    }

    /// `bitBulkActionButton`: "tw-inline-flex tw-items-center tw-gap-2 tw-px-3 tw-py-2 tw-text-sm
    /// !tw-text-fg-contrast tw-rounded-lg hover:tw-bg-bg-hover-contrast".
    private struct BarButton: View {
        let title: String
        let icon: BWIcon
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Metric.space(2)) {
                    IconView(icon, size: TextStyle.sm.size)
                    Text(title).lineLimit(1).textStyle(.sm)
                }
                .foregroundStyle(.theme(.fgContrast))
                .padding(.horizontal, Metric.space(3))
                .padding(.vertical, Metric.space(2))
                .background(BWControlShape().fill(.theme(isHovered ? .bgHoverContrast : .clear)))
                .contentShape(BWControlShape())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
        }
    }
}
