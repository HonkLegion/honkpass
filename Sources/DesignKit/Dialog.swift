import SwiftUI

/// `bit-dialog` over a backdrop: libs/components/src/dialog/dialog/dialog.component.html and
/// dialog.service.ts. Put it over the whole window content. It is the host of the lists of the
/// selects inside it.
public struct BWDialog<Content: View, Footer: View>: View {
    public enum Size: Sendable {
        /// "md:tw-max-w-sm"
        case small
        /// "md:tw-max-w-xl"
        case regular
        /// "md:tw-max-w-3xl"
        case large

        var maxWidth: CGFloat {
            switch self {
            case .small: 24 * Metric.rem
            case .regular: 36 * Metric.rem
            case .large: 48 * Metric.rem
            }
        }
    }

    private let title: String
    private let titleIcon: BWIcon?
    private let size: Size
    private let hasAltGround: Bool
    private let fadingEdges: Bool
    private let floatingFooter: Bool
    private let layeredHeader: Bool
    private let onClose: () -> Void
    private let content: Content
    private let footer: Footer
    private var hasFooter: Bool { Footer.self != EmptyView.self }
    @State private var footerHeight = Metric.space(20)
    @State private var headerHeight = Metric.panelHeaderHeight
    @State private var isAtTop = true
    private var bodyBackground: ThemeColor { hasAltGround ? .bgTertiary : .bgPrimary }

    /// - Parameters:
    ///   - titleIcon: an icon before the title, in the danger colour ("tw-flex tw-items-center tw-gap-2").
    ///   - hasAltGround: `background="alt"`: the body lies on "tw-bg-background-alt" with "tw-py-4".
    ///   - fadingEdges: fade the opaque header and footer into the body without changing layout.
    ///   - floatingFooter: use the short detail-style fade with independent action buttons.
    public init(title: String, titleIcon: BWIcon? = nil, size: Size = .regular, hasAltGround: Bool = false,
                fadingEdges: Bool = true, floatingFooter: Bool = true, layeredHeader: Bool = true,
                onClose: @escaping () -> Void, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.titleIcon = titleIcon
        self.size = size
        self.hasAltGround = hasAltGround
        self.fadingEdges = fadingEdges
        self.floatingFooter = floatingFooter
        self.layeredHeader = layeredHeader
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        GeometryReader { window in
            ZStack {
                // backdrop: "tw-fixed tw-bg-bg-overlay tw-inset-0"
                Rectangle()
                    .fill(.theme(.bgOverlay))
                    .onTapGesture(perform: onClose)
                panel
                    // host: "md:tw-max-w-xl md:tw-p-4 tw-max-h-[90vh]"; the panel is centred in the window.
                    .frame(maxWidth: size.maxWidth - 2 * Metric.space(4))
                    .padding(Metric.space(4))
                    .frame(maxHeight: 0.9 * window.size.height)
            }
            .frame(width: window.size.width, height: window.size.height)
            .bwDropdownHost()
            .bwPopoverHost()
            .bwEscapeLayer(close: onClose)
        }
    }

    /// section: "tw-flex tw-w-full tw-flex-col tw-overflow-hidden tw-border tw-border-solid tw-border-secondary-100
    /// tw-bg-background tw-text-main", "md:tw-rounded-xl tw-shadow-lg".
    private var panel: some View {
        let radius = Metric.containerCornerRadius
        return VStack(alignment: .leading, spacing: 0) {
            if !layeredHeader { header.background(.theme(bodyBackground)) }
            if floatingFooter {
                // The body now reaches the bottom corners beneath the floating buttons.
                bodyArea.clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius - 1,
                                                         bottomTrailingRadius: radius - 1))
            } else {
                bodyArea
            }
            if hasFooter, !floatingFooter {
                // The divider above the footer is transparent while the body does not scroll.
                Rectangle().fill(.clear).frame(height: 1)
                // footer: "tw-flex tw-flex-row tw-items-center tw-gap-2 tw-bg-background tw-py-5 tw-ps-6 tw-pe-4".
                // A `Spacer` in the footer moves what follows it to the end ("tw-ml-auto").
                footerRow
            }
        }
        .foregroundStyle(.theme(.textMain))
        .clipShape(RoundedRectangle(cornerRadius: radius - 1))
        .padding(1)
        // "tw-shadow-lg": 0 10px 15px -3px rgb(0 0 0 / .1), 0 4px 6px -4px rgb(0 0 0 / .1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(bodyBackground)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.secondary100), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 8)
    }

    private var bodyArea: some View {
        // The body scrolls when the window is too low for it ("tw-overflow-y-auto").
        ViewThatFits(in: .vertical) {
            bodyContent
                .padding(.top, layeredHeader ? headerHeight : 0)
                .onAppear { isAtTop = true }
            BWScrollView(topInset: layeredHeader ? headerHeight : 0, onScroll: { isAtTop = $0.isAtTop }) { bodyContent }
        }
        .overlay(alignment: .top) {
            if layeredHeader {
                VStack(spacing: 0) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    Color.clear.frame(height: Metric.headerFadeHeight).allowsHitTesting(false)
                }
                .background {
                    BWLayeredHeaderBackground(background: bodyBackground, isAtTop: isAtTop, headerHeight: headerHeight)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Metric.containerCornerRadius - 1,
                                                 topTrailingRadius: Metric.containerCornerRadius - 1))
            } else if fadingEdges {
                BWHeaderFade(background: bodyBackground)
            }
        }
        .overlay(alignment: .bottom) {
            if floatingFooter, hasFooter {
                ZStack(alignment: .bottom) {
                    BWFooterFade(footerHeight: footerHeight, background: hasAltGround ? .bgTertiary : .bgPrimary)
                    footerRow
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
            } else if fadingEdges, hasFooter {
                BWHeaderFade(edge: .bottom)
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: Metric.space(2)) { footer }
            .environment(\.hasFloatingActionBackdrop, floatingFooter)
            .environment(\.floatingActionBackground, bodyBackground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metric.space(5))
            .padding(.leading, Metric.space(6))
            .padding(.trailing, Metric.space(4))
    }

    /// body: "tw-py-2 tw-ps-6 tw-pe-6", and "tw-pb-4" when the dialog has no footer.
    private var bodyContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, hasAltGround ? Metric.space(4) : Metric.space(2))
            .padding(.bottom, hasFooter && !hasAltGround ? Metric.space(2) : Metric.space(4))
            .padding(.bottom, floatingFooter && hasFooter ? footerHeight + 1 : 0)
            .padding(.horizontal, Metric.space(6))
            .background(.theme(hasAltGround ? .bgTertiary : .clear))
    }

    /// header: "tw-flex tw-justify-between tw-items-center tw-gap-2 tw-border-0 tw-border-b tw-border-solid tw-py-3 tw-ps-6"
    /// with "has-[[biticonbutton]]:tw-pe-2"; the bottom border is transparent while the body does not scroll.
    private var header: some View {
        HStack(alignment: .center, spacing: Metric.space(2)) {
            // h2 bitTypography="h3" noMargin: "!tw-text-xl tw-text-main tw-font-medium tw-line-clamp-2"
            HStack(alignment: .center, spacing: Metric.space(2)) {
                if let titleIcon {
                    IconView(titleIcon, size: TextStyle.h3.size).foregroundStyle(.theme(.fgDanger))
                }
                Text(title)
                    .lineLimit(2)
                    .textStyle(.h3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BWIconButton(.close, label: BWText["close"], action: onClose)
        }
        .padding(.vertical, Metric.space(3))
        .padding(.leading, Metric.space(6))
        .padding(.trailing, Metric.space(2))
        .padding(.bottom, 1)
    }
}

public extension BWDialog where Footer == EmptyView {
    /// A dialog without a footer row.
    init(title: String, size: Size = .regular, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, size: size, onClose: onClose, content: content, footer: { EmptyView() })
    }
}
