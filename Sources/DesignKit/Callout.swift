import SwiftUI

/// `bit-callout` of the type "info" with a title and the button that dismisses it:
/// libs/components/src/callout. "tw-border tw-border-solid tw-rounded-xl tw-ps-4 tw-pe-2",
/// "tw-pt-3 tw-pb-4", "tw-bg-bg-brand-softer tw-border-border-brand-soft"; it keeps its "tw-mb-4".
public struct BWCallout<Content: View>: View {
    private let title: String
    private let isWarning: Bool
    private let onDismiss: (() -> Void)?
    private let content: Content

    /// - Parameters:
    ///   - isWarning: the type "warning": its colours, and "bwi-exclamation-triangle" before the title.
    ///   - onDismiss: nil for a callout that cannot be closed: it has no cross.
    public init(title: String, isWarning: Bool = false, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isWarning = isWarning
        self.onDismiss = onDismiss
        self.content = content()
    }

    public var body: some View {
        let radius = Metric.containerCornerRadius
        // "tw-flex tw-flex-col tw-gap-2"
        VStack(alignment: .leading, spacing: Metric.space(2)) {
            // "tw-flex tw-justify-between"
            HStack(alignment: .top, spacing: 0) {
                // "tw-flex tw-gap-2 tw-items-baseline": the icon of the type, then the header
                // "tw-text-base tw-font-medium" in the strong colour of the type, with "tw-pt-1.5"
                HStack(alignment: .firstTextBaseline, spacing: Metric.space(2)) {
                    if isWarning { IconView(.exclamationTriangle, size: TextStyle.base.size) }
                    Text(title).textStyle(.base.weight(500))
                }
                .foregroundStyle(.theme(isWarning ? .fgWarningStrong : .fgBrandStrong))
                .padding(.top, Metric.space(1.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onDismiss { BWIconButton(.close, label: BWText["close"], size: .small, action: onDismiss) }
            }
            // div bitTypography="body2" "tw-pr-4"
            content
                .textStyle(.sm)
                .foregroundStyle(.theme(.textMain))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Metric.space(4))
        }
        .padding(.top, Metric.space(3))
        .padding(.bottom, Metric.space(4))
        .padding(.leading, Metric.space(4))
        .padding(.trailing, Metric.space(2))
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(isWarning ? .bgWarningSoft : .bgBrandSofter)))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(.theme(isWarning ? .borderWarningSoft : .borderBrandSoft), lineWidth: 1))
        .padding(.bottom, Metric.space(4))
    }
}

/// `bit-callout` without a title, of the type success or warning: one line with an icon, as the
/// dialog "confirm autofill" of the browser extension shows a website
/// (libs/components/src/callout): "tw-mb-4 tw-border tw-rounded-xl tw-ps-4 tw-pe-2", the
/// content "tw-py-2", in "tw-bg-bg-success-soft tw-border-border-success-soft" or the warning
/// colours, the icon in the strong colour of the type. The text is "tw-font-mono
/// tw-line-clamp-1 tw-break-all".
public struct BWStatusCallout: View {
    public enum Kind: Sendable {
        case success, warning
    }

    private let text: String
    private let kind: Kind
    private let icon: BWIcon

    public init(_ text: String, kind: Kind, icon: BWIcon) {
        self.text = text
        self.kind = kind
        self.icon = icon
    }

    public var body: some View {
        let radius = Metric.containerCornerRadius
        HStack(alignment: .firstTextBaseline, spacing: Metric.space(2)) {
            IconView(icon, size: TextStyle.sm.size)
                .foregroundStyle(.theme(kind == .success ? .fgSuccessStrong : .fgWarningStrong))
            Text(text)
                .font(Font(BWFont.monoCT(TextStyle.sm.size)))
                .foregroundStyle(.theme(.textMain))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Metric.space(2))
        .padding(.leading, Metric.space(4))
        .padding(.trailing, Metric.space(2))
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(kind == .success ? .bgSuccessSoft : .bgWarningSoft)))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(.theme(kind == .success ? .borderSuccessSoft : .borderWarningSoft), lineWidth: 1))
        .padding(.bottom, Metric.space(4))
        .accessibilityElement(children: .combine)
    }
}
