import SwiftUI

/// `bit-item` around a `button bit-item-content`: one row of a list of choices
/// (libs/components/src/item). `start` is the slot before the texts and `end` the slot of the
/// row's own buttons, which are not part of the choice.
public struct BWItem<Start: View, End: View>: View {
    private let title: String
    private let secondary: String?
    private let height: CGFloat?
    private let isFocused: Bool
    private let truncates: Bool
    private let isBrand: Bool
    private let action: () -> Void
    private let start: Start
    private let end: End
    private var contentEndIcon: BWIcon?
    @State private var isHovered = false

    /// - Parameters:
    ///   - height: the height the reference gives the row ("md:tw-h-20"); nil follows the content.
    ///   - isFocused: the keyboard is on the row: "tw-ring-1 tw-border-border-focus tw-ring-border-focus".
    ///   - truncates: `truncate` of bit-item-content: each text stays on one line.
    ///   - isBrand: the title is "tw-text-fg-brand tw-font-semibold" and the row "!tw-py-4": a row
    ///     that is an action among rows that are choices.
    ///   - end: icon buttons at the end of the row (`slot="end"`).
    public init(_ title: String, secondary: String? = nil, height: CGFloat? = nil, isFocused: Bool = false,
                truncates: Bool = false, isBrand: Bool = false, action: @escaping () -> Void, @ViewBuilder start: () -> Start,
                @ViewBuilder end: () -> End) {
        self.isBrand = isBrand
        self.title = title
        self.secondary = secondary
        self.height = height
        self.isFocused = isFocused
        self.truncates = truncates
        self.action = action
        self.start = start()
        self.end = end()
    }

    public var body: some View {
        let radius = Metric.containerCornerRadius
        let hasEnd = End.self != EmptyView.self
        // host: "tw-flex tw-rounded-lg tw-gap-3 tw-justify-between"
        HStack(spacing: Metric.space(3)) {
            Button(action: action) {
                // bit-item-content: "tw-w-full tw-flex tw-gap-4 tw-items-center tw-justify-between tw-ps-3 tw-py-2",
                // inside "tw-flex tw-gap-3 tw-items-center tw-w-full tw-min-w-0".
                HStack(alignment: .center, spacing: Metric.space(4)) {
                    HStack(alignment: .center, spacing: Metric.space(3)) {
                        start
                        // "tw-flex tw-flex-col tw-items-start tw-text-start tw-w-full tw-pe-3"
                        VStack(alignment: .leading, spacing: 0) {
                            // div bitTypography="body2" "tw-text-main"
                            Text(title)
                                .lineLimit(truncates ? 1 : nil)
                                .textStyle(isBrand ? .sm.weight(600) : .sm)
                                .foregroundStyle(.theme(isBrand ? .fgBrand : .textMain))
                            if let secondary {
                                // div bitTypography="helper" "tw-text-muted"
                                Text(secondary)
                                    .lineLimit(truncates ? 1 : nil)
                                    .textStyle(.xs)
                                    .foregroundStyle(.theme(.textMuted))
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, hasEnd || contentEndIcon != nil ? 0 : Metric.space(3))
                    }
                    // The end slot of the content, "tw-flex tw-items-center": it has the trailing
                    // padding of the row when the row has no buttons of its own.
                    if let contentEndIcon {
                        IconView(contentEndIcon, size: Metric.rem)
                            .foregroundStyle(.theme(.textMain))
                            .padding(.trailing, hasEnd ? 0 : Metric.space(3))
                    }
                }
                .padding(.leading, Metric.space(3))
                .padding(.vertical, Metric.space(isBrand ? 4 : 2))
                .frame(minHeight: (height ?? Metric.space(9)) - 2)
                .frame(height: height.map { $0 - 2 })
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            if hasEnd {
                // The end slot: "tw-flex tw-items-center", and "tw-pe-2" after an icon button.
                HStack(spacing: 0) { end }
                    .padding(.trailing, Metric.space(2))
            }
        }
        // host: "tw-rounded-lg tw-bg-bg-primary tw-border tw-border-solid tw-border-border-base tw-min-h-9",
        // with the pointer over the choice "tw-bg-bg-brand-softer"
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(isHovered ? .bgBrandSofter : .bgPrimary)))
        // The focus: the border and a ring of one pixel around it, both in the focus colour.
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(isFocused ? .borderFocus : .borderBase), lineWidth: 1)
            .allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: radius + 1).strokeBorder(.theme(isFocused ? .borderFocus : .clear), lineWidth: 1)
            .padding(-1)
            .allowsHitTesting(false))
        // "tw-mb-1.5"
        .padding(.bottom, Metric.space(1.5))
    }
}

public extension BWItem {
    /// A `bit-icon` with `slot="end"` inside the content of the row: part of the choice, as
    /// the arrow of a row that opens something.
    func contentEnd(_ icon: BWIcon) -> BWItem {
        var item = self
        item.contentEndIcon = icon
        return item
    }
}

public extension BWItem where End == EmptyView {
    /// A row without buttons of its own.
    init(_ title: String, secondary: String? = nil, height: CGFloat? = nil, isFocused: Bool = false,
         truncates: Bool = false, isBrand: Bool = false, action: @escaping () -> Void, @ViewBuilder start: () -> Start) {
        self.init(title, secondary: secondary, height: height, isFocused: isFocused, truncates: truncates, isBrand: isBrand,
                  action: action, start: start, end: { EmptyView() })
    }
}
