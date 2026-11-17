import SwiftUI

/// How wide the side navigation is, and what a drag of its handle and the arrow keys make of it.
/// Source: side-nav.service.ts, side-nav-resize.ts and side-nav-width.service.ts.
public struct SideNavigationSize: Equatable, Sendable {
    /// `SIDE_NAV_WIDTH_BOUNDS`: 15, 37.5 and 18.5 rem.
    public static let minimum = 15 * Metric.rem
    public static let maximum = 37.5 * Metric.rem
    public static let standard = 18.5 * Metric.rem
    /// `SIDERAIL_WIDTH_REM`: the rail of icons of the closed navigation.
    public static let rail = 4 * Metric.rem
    /// `SNAP_TO_CLOSED_THRESHOLD_REM`: an open navigation dragged narrower than this closes.
    static let snapToClosed = 4 * Metric.rem
    /// `TENSION_FACTOR`: how little the navigation gives way under its smallest width.
    static let tension = 0.15
    /// `ARROW_STEP_REM`
    static let arrowStep = Metric.rem

    public enum Arrow: Sendable {
        case left, right
    }

    /// What the user chose with the button, the handle or the arrow keys (`userCollapsePreference`).
    public enum Preference: Sendable {
        case open, closed
    }

    public private(set) var isOpen = true
    /// nil until the user opens or closes the navigation: then it opens by itself where it has room.
    public private(set) var preference: Preference?
    /// The open navigation has a column of its own beside the main content (`isPushMode`).
    /// Without the room for that it closes to its rail, or lies over the content when the
    /// user opens it all the same.
    public private(set) var isPushMode = true
    /// The window and the drawer the navigation was last fitted to.
    private var fitted: [CGFloat] = []
    /// The width of the open navigation as it is drawn; a drag paints it.
    public private(set) var width: CGFloat
    /// The width the user chose. It is what the app remembers.
    public private(set) var saved: CGFloat
    /// A width that only the drag in progress shows: the navigation on its way out of the rail,
    /// or held back under its smallest width.
    public private(set) var preview: CGFloat?

    /// - Parameter saved: the remembered width; it is brought into the bounds.
    public init(saved: CGFloat? = nil) {
        let width = Self.clamp(saved ?? Self.standard)
        self.width = width
        self.saved = width
    }

    /// The width to draw now.
    public var displayWidth: CGFloat {
        preview ?? (isOpen ? width : Self.rail)
    }

    /// `resizeHandlePercent`: where the width is between the rail and the largest width.
    public var percent: Int {
        Int(((displayWidth - Self.rail) / (Self.maximum - Self.rail) * 100).rounded())
    }

    /// The handle is dragged: `pointer` is how far the pointer is from the leading edge of the navigation.
    public mutating func drag(to pointer: CGFloat) {
        if !isOpen {
            // Out of the rail: a preview until the smallest width is reached, then the navigation is open.
            if pointer < Self.rail {
                preview = nil
            } else if pointer >= Self.minimum {
                preview = nil
                preference = .open
                isOpen = true
                width = Self.clamp(pointer)
            } else {
                preview = pointer
            }
            return
        }
        if pointer < Self.snapToClosed {
            // It closes, and the widths this drag painted on the way down are forgotten.
            preview = nil
            preference = .closed
            isOpen = false
            width = saved
        } else if pointer < Self.minimum {
            preview = Self.minimum - (Self.minimum - pointer) * Self.tension
        } else {
            preview = nil
            width = Self.clamp(pointer)
        }
    }

    /// The handle is let go. Only now a width becomes the user's choice, so a drag that ends
    /// closed does not replace the width the user had.
    public mutating func endDrag() {
        let hadPreview = preview != nil
        preview = nil
        if !isOpen {
            // Let go on the way out of the rail: open at the width the user had.
            if hadPreview { expand() }
        } else if hadPreview {
            // Let go under the smallest width: back to it.
            commit(Self.minimum)
        } else {
            commit(width)
        }
    }

    /// An arrow key while the handle has the focus: a step of one rem; the left arrow at the
    /// smallest width closes the navigation and the right arrow opens a closed one.
    public mutating func press(_ arrow: Arrow) {
        if !isOpen {
            if arrow == .right { expand() }
        } else if arrow == .left, width <= Self.minimum {
            preference = .closed
            isOpen = false
        } else {
            commit(width + (arrow == .left ? -Self.arrowStep : Self.arrowStep))
        }
    }

    /// `toggle()`: the button of the navigation. The choice stays when the window changes.
    public mutating func toggle() {
        if isOpen {
            preference = .closed
            isOpen = false
        } else {
            expand()
        }
    }

    /// `_expand()`: open at the width the user last chose.
    private mutating func expand() {
        preference = .open
        isOpen = true
        width = saved
    }

    /// `update()` of layout.component.ts: the navigation is fitted to a window that is
    /// `window` wide and has a drawer that wants `drawer` (0 without one). When the room
    /// around the navigation got too small for its own column, it closes to its rail; when
    /// the room is back, it opens again, unless the user closed it. A navigation that the
    /// user made wider than the room is not closed for that: it then lies over the content.
    public mutating func fit(window: CGFloat, drawer: CGFloat) {
        let fit = BWLayout.Fit(window: window, navigation: width, drawer: drawer)
        let roomChanged = fitted != [window, drawer]
        fitted = [window, drawer]
        if roomChanged, !fit.navigationPushes, isOpen, isPushMode { isOpen = false }
        if fit.navigationPushes, !isPushMode, preference != .closed {
            isOpen = true
            width = saved
        }
        isPushMode = fit.navigationPushes
    }

    /// The remembered width arrives after the window was laid out, as at a start of the
    /// reference: a navigation that has no room at that width closes to its rail, where a
    /// width from a gesture of the user would leave it lying over the content.
    public mutating func restore(_ width: CGFloat) {
        commit(width)
        fitted = []
    }

    /// Sets the width as a choice of the user.
    public mutating func commit(_ width: CGFloat) {
        self.width = Self.clamp(width)
        saved = self.width
    }

    private static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }
}

/// The handle at the trailing edge of the side navigation: a bar of a quarter rem that takes
/// the colour "primary-300" under the pointer, after a quarter of a second, and with the focus.
/// It is dragged, or moved by the left and right arrows while it has the focus.
/// Source: the `cdkDrag` element of side-nav.component.html.
public struct SideNavigationResizeHandle: View {
    @Binding private var size: SideNavigationSize
    @State private var isHovered = false
    @State private var isDragging = false
    @FocusState private var hasFocus: Bool

    public init(size: Binding<SideNavigationSize>) {
        _size = size
    }

    public var body: some View {
        // "tw-w-1"; "before:-tw-left-0.5 before:-tw-right-1" widens what the pointer can take.
        let bar = Metric.space(1)
        Rectangle()
            .fill(.theme(isHovered || isDragging || hasFocus ? .primary300 : .clear))
            .frame(width: bar)
            .padding(.leading, Metric.space(0.5))
            .padding(.trailing, Metric.space(1))
            .contentShape(Rectangle())
            // "-tw-right-0.5": the bar lies half over the edge of the navigation.
            .offset(x: Metric.space(0.5) + Metric.space(1))
            // "tw-transition-colors tw-duration-[250ms] hover:tw-ease-in-out hover:tw-delay-[250ms]"
            .animation(isHovered ? .easeInOut(duration: 0.25).delay(0.25) : .easeInOut(duration: 0.25), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    size.drag(to: value.location.x)
                }
                .onEnded { _ in
                    isDragging = false
                    size.endDrag()
                    // The focus of the reference shows for the keyboard only (`:focus-visible`):
                    // a handle that was dragged with the pointer does not stay marked.
                    hasFocus = false
                })
            .focusable()
            .focusEffectDisabled()
            .focused($hasFocus)
            .onKeyPress(.leftArrow) {
                size.press(.left)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                size.press(.right)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(BWText["resizeSideNavigation"])
            .accessibilityValue("\(size.percent) %")
            .accessibilityAdjustableAction { direction in
                size.press(direction == .increment ? .right : .left)
            }
    }
}
