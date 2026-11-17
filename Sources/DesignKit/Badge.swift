import SwiftUI

/// `bitBadge`, variant primary, size large: libs/components/src/badge/badge.component.ts.
/// "tw-inline-flex tw-items-center tw-rounded-full tw-border tw-font-medium", the label
/// "tw-text-sm/5 tw-px-1.5 tw-py-1", in "tw-bg-bg-brand-softer tw-border-border-brand-soft
/// tw-text-fg-brand-strong".
public struct BWBadge: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .textStyle(.smTight.weight(500))
            .lineLimit(1)
            .foregroundStyle(.theme(.fgBrandStrong))
            .padding(.horizontal, Metric.space(1.5))
            .padding(.vertical, Metric.space(1))
            .background(BWControlShape().fill(.theme(.bgBrandSofter)))
            .overlay(BWControlShape().strokeBorder(.theme(.borderBrandSoft), lineWidth: 1))
    }
}
