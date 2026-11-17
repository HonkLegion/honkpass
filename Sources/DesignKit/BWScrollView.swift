import SwiftUI

public extension ThemeColor {
    /// The scrollbar thumb of the desktop app: `scrollbarColor` in apps/desktop/src/scss/variables.scss.
    static let scrollbar = ThemeColor(light: 0x64646433, dark: 0x6E788AFF)
    /// `scrollbarHoverColor`
    static let scrollbarHover = ThemeColor(light: 0x64646466, dark: 0x8D94A5FF)
    /// `scrollbarColorNav`: the thumb in the side navigation.
    static let scrollbarNavigation = ThemeColor(light: 0xFFFFFFFF, dark: 0x6E788AFF)
}

/// Where a `BWScrollView` is: the offset from the top, the height of the content and of the area.
public struct BWScrollMetrics: Equatable, Sendable {
    public var offset: CGFloat = 0
    public var content: CGFloat = 0
    public var viewport: CGFloat = 0

    public init() {}

    init(offset: CGFloat, content: CGFloat, viewport: CGFloat) {
        self.offset = offset
        self.content = content
        self.viewport = viewport
    }

    public var isScrollable: Bool { viewport > 0 && content - viewport > 0.5 }
    public var isAtTop: Bool { offset < 0.5 }
    public var isAtBottom: Bool { content - viewport - offset < 0.5 }
}

/// A view of the content of a `BWScrollView` that has to be in sight.
public struct BWScrollTarget: Equatable {
    /// The identifier (`.id`) of the view.
    let id: AnyHashable
    /// A new number asks again for the same view, after the user has scrolled away from it.
    let request: Int

    public init(id: AnyHashable, request: Int = 0) {
        self.id = id
        self.request = request
    }
}

/// The scrollbar of every scroll area.
public enum BWScrollbar {
    /// The room a scrollbar takes beside content that is higher than its area.
    public static let width: CGFloat = 6
}

/// A vertical scroll area with the scrollbar of the desktop app (apps/desktop/src/scss/base.scss):
/// a round thumb on a transparent track. The reference has it ten pixels wide; PassVault six
/// (PLAN.md, "Differences from the reference"). As with `overflow: auto`, the scrollbar
/// takes its room only while the content is higher than the area.
public struct BWScrollView<Content: View>: View {
    private typealias Metrics = BWScrollMetrics

    public static var scrollbarWidth: CGFloat { BWScrollbar.width }

    private let isNavigation: Bool
    private let scrollTarget: BWScrollTarget?
    private let startsAtEnd: Bool
    private let topInset: CGFloat
    private let onScroll: ((BWScrollMetrics) -> Void)?
    private let content: Content
    @State private var metrics = Metrics()
    @State private var position = ScrollPosition()
    @State private var isHovered = false
    @State private var dragStart: CGFloat?

    /// - Parameter isNavigation: the thumb of `#bit-side-nav--scroll`: a transparent pixel on each
    ///   side and the navigation colour.
    ///   - startsAtEnd: the area shows the end of its content first.
    ///   - onScroll: called when the scroll position or a size changes.
    ///   - scrollTarget: a view of the content that has to be in sight; the area scrolls as little
    ///     as that needs, at the start and when the target changes.
    ///   - topInset: reserved space for an overlaid header. Content can scroll beneath it;
    ///     the scrollbar and metrics describe the unobscured viewport.
    public init(isNavigation: Bool = false, startsAtEnd: Bool = false, scrollTarget: BWScrollTarget? = nil,
                topInset: CGFloat = 0,
                onScroll: ((BWScrollMetrics) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.isNavigation = isNavigation
        self.scrollTarget = scrollTarget
        self.startsAtEnd = startsAtEnd
        self.topInset = max(0, topInset)
        self.onScroll = onScroll
        self.content = content()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding(.top, topInset)
                    .padding(.trailing, isScrollable ? Self.scrollbarWidth : 0)
            }
            // `.hidden` still shows the system scrollbar, and keeps its room, when a mouse is connected.
            .scrollIndicators(.never)
            .defaultScrollAnchor(startsAtEnd ? .bottom : .top)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.y, content: max(0, geometry.contentSize.height - topInset),
                        viewport: max(0, geometry.containerSize.height - topInset))
            } action: { _, new in
                metrics = new
                onScroll?(new)
            }
            .onChange(of: scrollTarget, initial: true) {
                if let scrollTarget { proxy.scrollTo(scrollTarget.id) }
            }
        }
        .overlay(alignment: .topTrailing) { thumb }
    }

    private var isScrollable: Bool { metrics.isScrollable }

    @ViewBuilder
    private var thumb: some View {
        let scrollable = metrics.content - metrics.viewport
        if isScrollable {
            let height = max(metrics.viewport * metrics.viewport / metrics.content, 24)
            let travel = metrics.viewport - height
            let top = min(max(metrics.offset / scrollable, 0), 1) * travel
            RoundedRectangle(cornerRadius: Self.scrollbarWidth / 2)
                .fill(.theme(isNavigation ? .scrollbarNavigation : (isHovered || dragStart != nil ? .scrollbarHover : .scrollbar)))
                .padding(.horizontal, isNavigation ? 1 : 0)
                .frame(width: Self.scrollbarWidth, height: height)
                .contentShape(Rectangle())
                .offset(y: topInset + top)
                .onHover { isHovered = $0 }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? metrics.offset
                        dragStart = start
                        let target = start + drag.translation.height / max(travel, 1) * scrollable
                        position.scrollTo(y: min(max(target, 0), scrollable))
                    }
                    .onEnded { _ in dragStart = nil })
        }
    }
}
