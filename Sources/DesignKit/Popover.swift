import SwiftUI

/// Where a `bit-popover` opens beside its trigger: libs/components/src/popover/default-positions.ts.
/// The first position that has room in the window is taken, the wanted one first.
public enum BWPopoverPosition: CaseIterable, Sendable {
    case rightStart, rightCenter, rightEnd
    case leftStart, leftCenter, leftEnd
    case belowCenter, belowStart, belowEnd
    case aboveCenter, aboveStart, aboveEnd

    /// `ORIGIN_OFFSET_PX`: between the trigger and the popover.
    private static let gap: CGFloat = 14
    /// `OVERLAY_OFFSET_PX`: from a corner of the popover to its arrow.
    static let inset: CGFloat = 24

    enum Side { case right, left, below, above }
    enum Place { case start, center, end }

    var side: Side {
        switch self {
        case .rightStart, .rightCenter, .rightEnd: .right
        case .leftStart, .leftCenter, .leftEnd: .left
        case .belowCenter, .belowStart, .belowEnd: .below
        case .aboveCenter, .aboveStart, .aboveEnd: .above
        }
    }

    var place: Place {
        switch self {
        case .rightStart, .leftStart, .belowStart, .aboveStart: .start
        case .rightCenter, .leftCenter, .belowCenter, .aboveCenter: .center
        case .rightEnd, .leftEnd, .belowEnd, .aboveEnd: .end
        }
    }

    /// The top left corner of a popover of this size beside the trigger.
    func origin(trigger: CGRect, size: CGSize) -> CGPoint {
        func along(_ middle: CGFloat, _ length: CGFloat) -> CGFloat {
            switch place {
            case .start: middle - Self.inset
            case .center: middle - length / 2
            case .end: middle + Self.inset - length
            }
        }
        return switch side {
        case .right: CGPoint(x: trigger.maxX + Self.gap, y: along(trigger.midY, size.height))
        case .left: CGPoint(x: trigger.minX - Self.gap - size.width, y: along(trigger.midY, size.height))
        case .below: CGPoint(x: along(trigger.midX, size.width), y: trigger.maxY + Self.gap)
        case .above: CGPoint(x: along(trigger.midX, size.width), y: trigger.minY - Self.gap - size.height)
        }
    }

    /// The middle of the arrow in a popover of this size: one pixel inside the edge that faces the trigger.
    func arrow(size: CGSize) -> CGPoint {
        func along(_ length: CGFloat) -> CGFloat {
            switch place {
            case .start: Self.inset
            case .center: length / 2
            case .end: length - Self.inset
            }
        }
        return switch side {
        case .right: CGPoint(x: 1, y: along(size.height))
        case .left: CGPoint(x: size.width - 1, y: along(size.height))
        case .below: CGPoint(x: along(size.width), y: 1)
        case .above: CGPoint(x: along(size.width), y: size.height - 1)
        }
    }

    /// The position for a popover of this size: the wanted one, or the first of the others that
    /// lies in the window whole. When none does, the wanted one.
    static func choose(wanted: BWPopoverPosition?, trigger: CGRect, size: CGSize, window: CGSize) -> BWPopoverPosition {
        let order = (wanted.map { [$0] } ?? []) + allCases.filter { $0 != wanted }
        return order.first { position in
            let origin = position.origin(trigger: trigger, size: size)
            return origin.x >= 0 && origin.y >= 0 && origin.x + size.width <= window.width && origin.y + size.height <= window.height
        } ?? order[0]
    }
}

/// The help behind a question mark: a `bit-popover` with a title, a text and, for a setting,
/// the link "learn more".
public struct BWHelp {
    let isOpen: Binding<Bool>
    let label: String
    let title: String
    let text: String
    let position: BWPopoverPosition?
    let link: (title: String, open: () -> Void)?

    /// - Parameters:
    ///   - label: what the question mark is called for VoiceOver.
    ///   - position: the place the reference asks for; nil for the first that has room.
    public init(isOpen: Binding<Bool>, label: String, title: String, text: String, position: BWPopoverPosition? = nil,
                linkTitle: String? = nil, onLink: (() -> Void)? = nil) {
        self.isOpen = isOpen
        self.label = label
        self.title = title
        self.text = text
        self.position = position
        link = linkTitle.flatMap { title in onLink.map { (title, $0) } }
    }
}

/// The question mark that opens a help: a `bitLink` with "bwi-question-circle". It is a
/// button, so 14 pixels as every desktop button, in the colour of a link.
public struct BWHelpButton: View {
    private let help: BWHelp
    @State private var isHovered = false

    public init(_ help: BWHelp) {
        self.help = help
    }

    public var body: some View {
        Button {
            help.isOpen.wrappedValue.toggle()
        } label: {
            IconView(.questionCircle, size: TextStyle.body.size)
                .foregroundStyle(.theme(isHovered ? .fgBrandStrong : .fgBrand))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .accessibilityLabel(help.label)
        .anchorPreference(key: BWPopoverPreference.self, value: .bounds) { anchor in
            help.isOpen.wrappedValue ? BWPopoverRequest(anchor: anchor, help: help) : nil
        }
    }
}

struct BWPopoverRequest {
    let anchor: Anchor<CGRect>
    let help: BWHelp
}

struct BWPopoverPreference: PreferenceKey {
    static var defaultValue: BWPopoverRequest? { nil }

    static func reduce(value: inout BWPopoverRequest?, nextValue: () -> BWPopoverRequest?) {
        value = value ?? nextValue()
    }
}

public extension View {
    /// Draws the open help of the question marks inside this view over it, behind a transparent
    /// backdrop: a click beside it and Escape close it. `BWDialog` is such a host.
    func bwPopoverHost() -> some View {
        overlayPreferenceValue(BWPopoverPreference.self) { request in
            GeometryReader { proxy in
                if let request {
                    let dismiss = { request.help.isOpen.wrappedValue = false }
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismiss)
                        BWPopoverPlacer(help: request.help, trigger: proxy[request.anchor], window: proxy.size, dismiss: dismiss)
                    }
                    .onExitCommand(perform: dismiss)
                    .bwEscapeLayer(close: dismiss)
                }
            }
        }
    }
}

/// Puts the popover where it has room, once its size is known.
private struct BWPopoverPlacer: View {
    let help: BWHelp
    let trigger: CGRect
    let window: CGSize
    let dismiss: () -> Void
    @State private var size: CGSize?

    var body: some View {
        let position = BWPopoverPosition.choose(wanted: help.position, trigger: trigger, size: size ?? .zero, window: window)
        let origin = position.origin(trigger: trigger, size: size ?? .zero)
        BWPopoverPanel(help: help, arrow: size.map { position.arrow(size: $0) }, dismiss: dismiss)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: origin.x, y: origin.y)
            .opacity(size == nil ? 0 : 1)
    }
}

/// popover-base.component.html and popover.component.html: "tw-rounded-xl tw-shadow-md tw-border
/// tw-border-border-base" around "tw-max-w-[22.5rem] tw-bg-bg-primary tw-text-fg-body" with
/// "tw-p-6", the close button at "tw-top-3 tw-right-3", and the arrow of popover.component.css.
private struct BWPopoverPanel: View {
    let help: BWHelp
    let arrow: CGPoint?
    let dismiss: () -> Void
    @FocusState private var hasFocus: Bool

    private static let maxWidth = 22.5 * Metric.rem
    private static let padding = Metric.space(6)

    var body: some View {
        let radius = Metric.containerCornerRadius
        // The texts behind the question marks are sentences, so the popover is as wide as it may be.
        content
            .frame(width: Self.maxWidth - 2 * Self.padding, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Self.padding)
        .overlay(alignment: .topTrailing) {
            BWIconButton(.close, label: BWText["close"], size: .small, action: dismiss)
                .padding(Metric.space(3))
        }
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderBase), lineWidth: 1))
        // ".bit-popover-arrow": "tw-size-3 tw-rotate-45" with the ground and the border of the
        // popover, under its content, so that only the half outside the edge shows.
        .background(alignment: .topLeading) {
            if let arrow {
                Rectangle()
                    .fill(.theme(.bgPrimary))
                    .overlay(Rectangle().strokeBorder(.theme(.borderBase), lineWidth: 1))
                    .frame(width: Metric.space(3), height: Metric.space(3))
                    .rotationEffect(.degrees(45))
                    .position(arrow)
            }
        }
        // "tw-shadow-md": 0 4px 6px -1px rgb(0 0 0 / .1), 0 2px 4px -2px rgb(0 0 0 / .1)
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4)
        // `cdkTrapFocus cdkTrapFocusAutoCapture`: the popover has the keyboard while it is open.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(help.title)
    }

    /// "tw-flex tw-flex-col tw-gap-3": h2 bitTypography="h4" "tw-pe-7 tw-text-fg-heading", then
    /// the text in body2 "tw-text-fg-body". A paragraph of the desktop app has "margin-bottom: 10px".
    private var content: some View {
        VStack(alignment: .leading, spacing: Metric.space(3)) {
            Text(help.title)
                .textStyle(.h4)
                .foregroundStyle(.theme(.fgHeading))
                .padding(.trailing, Metric.space(7))
            VStack(alignment: .leading, spacing: 0) {
                Text(help.text)
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.fgBody))
                    .padding(.bottom, help.link == nil ? 0 : 10)
                if let link = help.link {
                    // div "tw-flex tw-gap-1.5 tw-items-center": the link and "bwi-external-link tw-text-primary-600".
                    HStack(spacing: Metric.space(1.5)) {
                        BWLink(link.title, size: TextStyle.sm.size) {
                            dismiss()
                            link.open()
                        }
                        IconView(.externalLink, size: TextStyle.sm.size)
                            .foregroundStyle(.theme(.primary600))
                    }
                }
            }
        }
    }
}
