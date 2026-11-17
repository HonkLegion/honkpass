import SwiftUI

/// One `bitMenuItem` of a `bit-menu`: libs/components/src/menu/menu-item.component.ts.
public struct BWMenuItem {
    public enum Kind: Sendable {
        /// "tw-text-fg-body hover:tw-text-fg-heading hover:tw-bg-bg-brand-softer"
        case primary
        /// "tw-text-fg-danger hover:tw-text-fg-danger-strong hover:tw-bg-bg-danger-soft"
        case danger
    }

    /// Where the reference puts the icon of the item.
    public enum IconPlace: Sendable {
        /// An `i.bwi.bwi-fw` in the text of the item: the icon, a space, the label.
        case inline
        /// A `bit-icon` without `fixedWidth` in the text of the item: the icon in a box as wide
        /// as the text is high, a space, the label.
        case inlineNarrow
        /// A `bit-icon` with `slot="start"`: the icon and the label in a row with "tw-gap-2".
        case startSlot
    }

    let title: String
    let icon: BWIcon?
    let kind: Kind
    let iconPlace: IconPlace
    let isEnabled: Bool
    let action: () -> Void
    var isDivider = false

    /// `bit-menu-divider`: a line between two groups of items.
    public static var divider: BWMenuItem {
        var item = BWMenuItem("", isEnabled: false) {}
        item.isDivider = true
        return item
    }

    /// - Parameter icon: nil for an item that is its text only.
    public init(_ title: String, icon: BWIcon? = nil, kind: Kind = .primary, iconPlace: IconPlace = .inline,
                isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.iconPlace = iconPlace
        self.isEnabled = isEnabled
        self.action = action
    }
}

public extension View {
    /// `[bitMenuTriggerFor]`: while `isOpen` is set, the nearest `bwMenuHost()` above this view
    /// draws the menu at it.
    ///
    /// - Parameters:
    ///   - minWidth: the least width of the items, for a menu that names one ("tw-min-w-52").
    ///   - rowGap: the space between the rows: "tw-gap-1", or none for a menu whose rows are
    ///     in a block of their own.
    func bwMenu(isOpen: Binding<Bool>, minWidth: CGFloat? = nil, rowGap: CGFloat = Metric.space(1),
                items: @escaping () -> [BWMenuItem]) -> some View {
        anchorPreference(key: BWMenuPreference.self, value: .bounds) { anchor in
            guard isOpen.wrappedValue else { return nil }
            return BWMenuRequest(anchor: anchor, items: items(), minWidth: minWidth, rowGap: rowGap,
                                 dismiss: { isOpen.wrappedValue = false })
        }
    }

    /// Draws the open menu of the views inside this view over it, as the reference appends it to
    /// the page behind a transparent backdrop. A click beside the menu closes it.
    func bwMenuHost(usesNativeGlass: Bool = false) -> some View {
        overlayPreferenceValue(BWMenuPreference.self) { request in
            GeometryReader { proxy in
                if let request {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: request.dismiss)
                        MenuPlacement(trigger: proxy[request.anchor]) {
                            BWMenuPanel(items: request.items, minWidth: request.minWidth, rowGap: request.rowGap,
                                        dismiss: request.dismiss, usesNativeGlass: usesNativeGlass)
                        }
                    }
                    .onExitCommand(perform: request.dismiss)
                    .bwEscapeLayer(close: request.dismiss)
                }
            }
        }
    }
}

struct BWMenuRequest {
    let anchor: Anchor<CGRect>
    let items: [BWMenuItem]
    var minWidth: CGFloat?
    var rowGap: CGFloat = Metric.space(1)
    let dismiss: () -> Void
}

struct BWMenuPreference: PreferenceKey {
    static var defaultValue: BWMenuRequest? { nil }

    static func reduce(value: inout BWMenuRequest?, nextValue: () -> BWMenuRequest?) {
        value = value ?? nextValue()
    }
}

/// The positions of menu-positions.ts in their order: under the trigger from its start, under it
/// to its end, over it from its start, over it to its end. The first one that fits the window wins.
private struct MenuPlacement: Layout {
    let trigger: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let menu = subviews.first else { return }
        let size = menu.sizeThatFits(.unspecified)
        let fromStart = trigger.minX, toEnd = trigger.maxX - size.width
        let under = trigger.maxY, over = trigger.minY - size.height
        let candidates = [CGPoint(x: fromStart, y: under), CGPoint(x: toEnd, y: under),
                          CGPoint(x: fromStart, y: over), CGPoint(x: toEnd, y: over)]
        let fitting = candidates.first { point in
            point.x >= 0 && point.y >= 0 && point.x + size.width <= bounds.width && point.y + size.height <= bounds.height
        }
        var origin = fitting ?? candidates[0]
        // No position fits: the first one, pushed into the window.
        origin.x = max(min(origin.x, bounds.width - size.width), 0)
        origin.y = max(min(origin.y, bounds.height - size.height), 0)
        menu.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
    }
}

/// menu.component.html: "tw-flex tw-shrink-0 tw-flex-col tw-rounded-xl tw-border tw-border-solid tw-border-border-light
/// tw-bg-bg-primary tw-shadow-lg" around "tw-p-2 tw-flex tw-flex-col tw-gap-1". It is as wide as its widest item.
private struct BWMenuPanel: View {
    let items: [BWMenuItem]
    var minWidth: CGFloat?
    var rowGap: CGFloat = Metric.space(1)
    let dismiss: () -> Void
    var usesNativeGlass = false
    /// The item the keyboard is on: the first one that can be chosen when the menu opens
    /// (`setFirstItemActive`). It is marked only when a key opened the menu or was used in it,
    /// as a browser shows the focus only then (`:focus-visible`).
    @State private var active: Int?
    @State private var showsActive = false
    @FocusState private var hasFocus: Bool

    private var canChoose: [Bool] { items.map { !$0.isDivider && $0.isEnabled } }

    var body: some View {
        let radius = Metric.containerCornerRadius
        VStack(alignment: .leading, spacing: rowGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if item.isDivider {
                    // "tw-h-px tw-w-full tw-my-2 tw-bg-border-base"
                    Rectangle()
                        .fill(.theme(.borderBase))
                        .frame(height: 1)
                        .padding(.vertical, Metric.space(2))
                } else {
                    Row(item: item, isActive: showsActive && active == index, dismiss: dismiss, usesNativeGlass: usesNativeGlass)
                }
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
        // The menu has the keyboard while it is open, whatever had it before: FocusKeyManager
        // "withWrap" with the disabled items skipped; Escape and Tab close the menu.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear {
            active = KeyboardList.step(from: nil, by: 1, canChoose: canChoose)
            showsActive = NSApp.currentEvent?.type == .keyDown
            hasFocus = true
        }
        // A request that comes too early is not honoured: the menu asks until it has the keyboard.
        .task {
            for _ in 0..<6 where !Task.isCancelled {
                if !hasFocus { hasFocus = true }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        .onKeyPress { press in
            // The shortcuts of the application menu stay what they are.
            guard !press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case .downArrow: move(1)
            case .upArrow: move(-1)
            case .return, .space: choose()
            case .escape, .tab: dismiss()
            // The key manager of the reference has no Home, End or type-ahead: the other keys do nothing.
            default: break
            }
            return .handled
        }
        .padding(Metric.space(2))
        .padding(1)
        // "tw-shadow-lg": 0 10px 15px -3px rgb(0 0 0 / .1), 0 4px 6px -4px rgb(0 0 0 / .1)
        .background {
            if usesNativeGlass {
                RoundedRectangle(cornerRadius: Metric.quickAccessRowRadius)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metric.quickAccessRowRadius))
            } else {
                RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary))
                    .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 8)
            }
        }
        .overlay {
            if !usesNativeGlass {
                RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderLight), lineWidth: 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    /// The first item has the focus from the start, so the first arrow down goes to the second one.
    private func move(_ step: Int) {
        active = KeyboardList.step(from: active, by: step, canChoose: canChoose)
        showsActive = true
    }

    private func choose() {
        guard let active, canChoose.indices.contains(active), canChoose[active] else { return }
        dismiss()
        items[active].action()
    }

    /// button: "tw-block tw-w-full tw-p-2 tw-rounded-lg tw-text-left". Disabled: "disabled:!tw-text-fg-inactive" and no ground under the pointer.
    private struct Row: View {
        let item: BWMenuItem
        /// The keyboard is on this item: "focus-visible:tw-bg-bg-brand-softer" with
        /// "focus-visible:tw-ring-2 focus-visible:tw-ring-inset focus-visible:tw-ring-border-focus".
        let isActive: Bool
        let dismiss: () -> Void
        var usesNativeGlass = false
        @State private var isPointerOver = false
        private var isHovered: Bool { isPointerOver || isActive }

        /// `.bwi-fw`: "width: 1.2857em".
        private static let iconBox = 18.0 / 14.0 * TextStyle.sm.size

        var body: some View {
            Button {
                dismiss()
                item.action()
            } label: {
                if usesNativeGlass {
                    HStack(spacing: 8) {
                        if let icon = item.icon { IconView(icon, size: TextStyle.sm.size) }
                        Text(item.title).font(QuickAccessStyle.menu).lineLimit(1)
                    }
                    .foregroundStyle(nativeForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? QuickAccessStyle.selection : .clear))
                    .contentShape(Rectangle())
                } else {
                    label
                        .foregroundStyle(.theme(foreground))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metric.space(2))
                        .background(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).fill(.theme(background)))
                        .overlay(RoundedRectangle(cornerRadius: Metric.containerCornerRadius)
                            .strokeBorder(.theme(isActive ? .borderFocus : .clear), lineWidth: 2))
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
            .onHover { isPointerOver = $0 }
            .pointerStyle(item.isEnabled ? .link : .default)
            .accessibilityLabel(item.title)
        }

        private var nativeForeground: Color {
            guard item.isEnabled else { return .secondary }
            switch item.kind {
            case .primary: return .primary
            case .danger: return Color(nsColor: NativeColor.danger)
            }
        }

        /// span "tw-text-sm tw-font-medium": the small text on its line of 150 %.
        @ViewBuilder private var label: some View {
            let style = TextStyle.sm.weight(500)
            let icon = item.icon.map { IconView($0, size: style.size).frame(width: Self.iconBox) }
            switch (item.icon == nil, item.iconPlace) {
            case (true, _):
                Text(item.title).lineLimit(1).textStyle(style)
            case (false, .inline):
                HStack(spacing: 0) {
                    icon
                    Text(" " + item.title).lineLimit(1).textStyle(style)
                }
            case (false, .inlineNarrow):
                HStack(spacing: 0) {
                    item.icon.map { IconView($0, size: style.size) }
                    Text(" " + item.title).lineLimit(1).textStyle(style)
                }
            case (false, .startSlot):
                HStack(spacing: Metric.space(2)) {
                    icon
                    Text(item.title).lineLimit(1).textStyle(style)
                }
            }
        }

        private var foreground: ThemeColor {
            guard item.isEnabled else { return .fgInactive }
            switch item.kind {
            case .primary: return isHovered ? .fgHeading : .fgBody
            case .danger: return isHovered ? .fgDangerStrong : .fgDanger
            }
        }

        private var background: ThemeColor {
            guard item.isEnabled, isHovered else { return .clear }
            return item.kind == .primary ? .bgBrandSofter : .bgDangerSoft
        }
    }
}
