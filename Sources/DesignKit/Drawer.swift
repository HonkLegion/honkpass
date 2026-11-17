import SwiftUI

/// `bit-dialog` shown as a drawer: the panel in the third column of `bit-layout`.
/// libs/components/src/dialog/dialog/dialog.component.html with `isDrawer`, dialogSize large and
/// background "alt". The caller gives it its width (`BWDrawer.width`).
public struct BWDrawer<Content: View, Footer: View>: View {
    private let title: String
    private let startsAtEnd: Bool
    private let floatingFooter: Bool
    private let fadingHeader: Bool
    private let layeredHeader: Bool
    private let headerBackground: ThemeColor
    private let onClose: () -> Void
    private let content: Content
    private let footer: Footer
    @State private var isAtTop = true
    @State private var showsFooterBorder = false
    @State private var footerHeight = Metric.space(20)
    @State private var headerHeight = Metric.panelHeaderHeight
    @State private var contentViewport: CGFloat = 0

    /// - Parameters:
    ///   - startsAtEnd: the body shows its end first.
    ///   - footer: the buttons of the footer row; put a `Spacer` before the ones at the end.
    public init(title: String, startsAtEnd: Bool = false, floatingFooter: Bool = true, fadingHeader: Bool = true,
                headerBackground: ThemeColor = .bgTertiary, layeredHeader: Bool = true,
                onClose: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.startsAtEnd = startsAtEnd
        self.floatingFooter = floatingFooter
        self.fadingHeader = fadingHeader
        self.layeredHeader = layeredHeader
        self.headerBackground = headerBackground
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !layeredHeader { header.background(.theme(headerBackground)) }
            // body wrapper: "tw-flex-1 tw-overflow-hidden tw-bg-background-alt"; the scroll area has
            // "tw-py-2 tw-ps-6 tw-pe-6" and, for the "alt" ground, "tw-py-4".
            BWScrollView(startsAtEnd: startsAtEnd, topInset: layeredHeader ? headerHeight : 0, onScroll: {
                isAtTop = $0.isAtTop
                showsFooterBorder = $0.isScrollable && !$0.isAtBottom
                contentViewport = $0.viewport
            }) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Metric.space(4))
                    .padding(.horizontal, Metric.space(6))
                    .padding(.bottom, floatingFooter ? footerHeight : 0)
                    // Fill short bodies without changing the scroll anchor of dropdowns elsewhere.
                    .frame(minHeight: contentViewport, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            .background(.theme(.bgTertiary))
            .overlay(alignment: .top) {
                if layeredHeader {
                    VStack(spacing: 0) {
                        header
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        Color.clear.frame(height: Metric.headerFadeHeight).allowsHitTesting(false)
                    }
                    .background {
                        BWLayeredHeaderBackground(background: headerBackground, isAtTop: isAtTop, headerHeight: headerHeight)
                    }
                } else if fadingHeader {
                    BWHeaderFade(background: headerBackground)
                }
            }
            .overlay(alignment: .bottom) {
                if floatingFooter {
                    ZStack(alignment: .bottom) {
                        BWFooterFade(footerHeight: footerHeight)
                        footerRow
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                    }
                }
            }
            // "tw-border-0 tw-border-t tw-border-solid": shown while there is more below.
            if !floatingFooter {
                Rectangle()
                    .fill(.theme(showsFooterBorder ? .secondary100 : .clear))
                    .frame(height: 1)
                footerRow
            }
        }
        .foregroundStyle(.theme(.textMain))
        .background(.theme(.bgPrimary))
        .overlay(alignment: .leading) {
            Rectangle().fill(.theme(.secondary100)).frame(width: 1)
        }
    }

    private var footerRow: some View {
        // footer: "tw-flex tw-flex-row tw-items-center tw-gap-2 tw-bg-background tw-py-5 tw-ps-6 tw-pe-4".
        // The drawer adds "tw-px-6 tw-py-4", which the classes above win over in the stylesheet.
        HStack(spacing: Metric.space(2)) {
            footer
        }
        .environment(\.hasFloatingActionBackdrop, floatingFooter)
        .padding(.vertical, Metric.space(5))
        .padding(.leading, Metric.space(6))
        .padding(.trailing, Metric.space(4))
    }

    /// header: "tw-flex tw-justify-between tw-items-center tw-gap-2 tw-border-0 tw-border-b tw-border-solid",
    /// in a drawer "tw-px-6 tw-py-4 has-[[biticonbutton]]:tw-pe-4". The line under it shows once the
    /// body has left its top.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Metric.space(2)) {
                // h2 bitTypography="h3" noMargin "tw-line-clamp-2"
                Text(title)
                    .lineLimit(2)
                    .textStyle(.h3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                BWIconButton(.close, label: BWText["close"], action: onClose)
            }
            .padding(.vertical, Metric.space(2))
            .padding(.leading, Metric.space(6))
            .padding(.trailing, Metric.space(4))
            .frame(minHeight: Metric.panelHeaderHeight - 1)
            Rectangle()
                .fill(.theme(isAtTop || fadingHeader ? .clear : .secondary100))
                .frame(height: 1)
        }
    }
}

extension EnvironmentValues {
    @Entry var hasFloatingActionBackdrop = false
    @Entry var floatingActionBackground: ThemeColor = .bgTertiary
}

public extension View {
    /// Share one backdrop with the control shape and independent action and hover states.
    func floatingActionCapsule() -> some View {
        environment(\.hasFloatingActionBackdrop, false)
            .background {
                BWFloatingActionBackdrop(cornerRadius: 0).clipShape(BWControlShape())
            }
    }
}

/// A quiet material behind floating controls, without adding layout or a footer bar.
struct BWFloatingActionBackdrop: View {
    var cornerRadius: CGFloat = Metric.containerCornerRadius
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.floatingActionBackground) private var background

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(.theme(background).opacity(reduceTransparency ? 1 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The short fade shared by floating action rows. The buttons keep their own hit areas.
public struct BWFooterFade: View {
    private let footerHeight: CGFloat
    private let background: ThemeColor

    public init(footerHeight: CGFloat, background: ThemeColor = .bgTertiary) {
        self.footerHeight = footerHeight
        self.background = background
    }

    public var body: some View {
        LinearGradient(stops: [
            .init(color: .theme(background).opacity(0), location: 0),
            .init(color: .theme(background).opacity(0.92), location: 0.6),
            .init(color: .theme(background), location: 1),
        ], startPoint: .top, endPoint: .bottom)
            .frame(height: (footerHeight + Metric.space(6)) / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The editor's experimental scroll layer. The top stays opaque beside the window strip.
public struct BWLayeredHeaderBackground: View {
    private let background: ThemeColor
    private let isAtTop: Bool
    private let headerHeight: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(background: ThemeColor, isAtTop: Bool, headerHeight: CGFloat) {
        self.background = background
        self.isAtTop = isAtTop
        self.headerHeight = headerHeight
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Group {
                if isAtTop || reduceTransparency {
                    Rectangle().fill(.theme(background))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(.theme(background).opacity(0.12))
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: .theme(background), location: 0),
                                .init(color: .theme(background), location: 0.2),
                                .init(color: .theme(background).opacity(0), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            // Keep material noise away from the exact join with the window strip.
            Rectangle().fill(.theme(background)).frame(height: Metric.headerFadeHeight)
        }
        .mask {
            // This is an alpha mask, not a visible colour. The final band also fades the blur.
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: headerHeight / (headerHeight + Metric.headerFadeHeight)),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The opaque header fades over the viewport. It never takes pointer or scroll events.
public struct BWHeaderFade: View {
    private let edge: VerticalEdge
    private let background: ThemeColor

    public init(edge: VerticalEdge = .top, background: ThemeColor = .bgPrimary) {
        self.edge = edge
        self.background = background
    }

    public var body: some View {
        LinearGradient(colors: [.theme(background), .theme(background).opacity(0)],
                       startPoint: edge == .top ? .top : .bottom,
                       endPoint: edge == .top ? .bottom : .top)
            .frame(height: Metric.headerFadeHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
