import SwiftUI

// The side navigation of the vault window: libs/components/src/navigation (version "default").

/// `bit-nav-item`: nav-item.component.html. A group is the same row with a chevron before it.
public struct NavItem<Trailing: View>: View {
    public enum Chevron: Sendable {
        case open, closed
    }

    private let icon: BWIcon
    private let text: String
    private let depth: Int
    private let isActive: Bool
    private let chevron: Chevron?
    private let onToggle: () -> Void
    private let action: () -> Void
    private let trailing: Trailing
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isSideNavigationCollapsed) private var isCollapsed

    public init(_ text: String, icon: BWIcon, depth: Int = 0, isActive: Bool = false, chevron: Chevron? = nil,
                onToggle: @escaping () -> Void = {}, action: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.icon = icon
        self.depth = depth
        self.isActive = isActive
        self.chevron = chevron
        self.onToggle = onToggle
        self.action = action
        self.trailing = trailing()
    }

    /// "padding-inline-start = (2.25 + treeDepth * 1.5)rem"
    private var indentation: CGFloat { (2.25 + CGFloat(depth) * 1.5) * Metric.rem }

    public var body: some View {
        if isCollapsed {
            // The rail shows the items of the top level only, as icons: "tw-text-center tw-justify-center".
            if depth == 0 { rail }
        } else {
            row
        }
    }

    private var rail: some View {
        Button(action: action) {
            IconView(icon, size: Metric.rem)
                .frame(maxWidth: .infinity)
                .frame(height: Metric.space(10))
                .foregroundStyle(.theme(.navFgPrimary))
                .background(BWControlShape().fill(.theme(background)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : .default)
        .opacity(isEnabled ? 1 : 0.5)
        .help(text)
        .accessibilityLabel(text)
        .padding(.horizontal, Metric.space(3))
    }

    private var row: some View {
        // The row: "tw-rounded-xl tw-h-10 tw-bg-bg-nav hover:tw-bg-bg-nav-hover"; active swaps in the strong colours.
        HStack(spacing: 0) {
            Button(action: action) {
                // "tw-gap-2 tw-py-0 tw-flex tw-items-center tw-h-full", icon "tw-w-4", text "tw-font-normal" | "tw-font-semibold"
                HStack(spacing: Metric.space(2)) {
                    IconView(icon, size: Metric.rem).frame(width: Metric.space(4))
                    Text(text)
                        .font(BWFont.inter(TextStyle.body.size, weight: isActive ? 600 : 400))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // end slot: "tw-flex tw-items-center tw-gap-1 tw-pe-3 [&:has(button)]:tw-pe-2"
            if Trailing.self != EmptyView.self {
                trailing.padding(.trailing, Metric.space(2))
            }
        }
        .padding(.leading, indentation)
        .frame(height: Metric.space(10))
        .foregroundStyle(.theme(.navFgPrimary))
        .background(BWControlShape().fill(.theme(background)))
        // The chevron of a group sits before the content: "tw-absolute tw-left-[0px] tw--translate-x-[calc(100%_+_4px)]".
        .overlay(alignment: .leading) {
            if let chevron {
                NavIconButton(.downSolid, label: BWText["toggleCollapse"] + " " + text, size: .xsmall, action: onToggle)
                    .rotationEffect(.degrees(chevron == .closed ? -90 : 0))
                    .offset(x: indentation - Metric.space(6) - 4)
            }
        }
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : .default)
        // A row of a part PassVault does not have yet is dimmed; the reference has no such state.
        .opacity(isEnabled ? 1 : 0.5)
        // "tw-ps-3 tw-pe-3"
        .padding(.horizontal, Metric.space(3))
    }

    private var background: ThemeColor {
        let hovered = isHovered && isEnabled
        if isActive { return hovered ? .navBgPrimaryHoverStrong : .navBgPrimaryStrong }
        return hovered ? .navBgPrimaryHover : .clear
    }
}

public extension NavItem where Trailing == EmptyView {
    init(_ text: String, icon: BWIcon, depth: Int = 0, isActive: Bool = false, chevron: Chevron? = nil,
         onToggle: @escaping () -> Void = {}, action: @escaping () -> Void) {
        self.init(text, icon: icon, depth: depth, isActive: isActive, chevron: chevron, onToggle: onToggle,
                  action: action) { EmptyView() }
    }
}

public extension EnvironmentValues {
    /// Whether the side navigation is the narrow rail. `SideNavigation` sets it for its items.
    @Entry var isSideNavigationCollapsed = false
}

/// `bitIconButton` with buttonType "side-nav": "!tw-text-fg-nav tw-border-transparent tw-bg-transparent hover:tw-bg-bg-nav-hover".
public struct NavIconButton: View {
    public enum Size: Sendable {
        /// A smaller disclosure symbol inside the original 21-point target.
        case xsmall
        /// "tw-text-xl tw-size-8", "tw-rounded-xl"
        case small
    }

    private let icon: BWIcon
    private let label: String
    private let size: Size
    private let action: () -> Void
    @State private var isHovered = false

    public init(_ icon: BWIcon, label: String, size: Size = .small, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        let box = size == .xsmall ? Metric.space(6) : Metric.space(8)
        let radius = Metric.containerCornerRadius
        Button(action: action) {
            IconView(icon, size: size == .xsmall ? Metric.navigationChevronSize : 1.25 * Metric.rem)
                .frame(width: box, height: box)
                .foregroundStyle(.theme(.navFgPrimary))
                .background(RoundedRectangle(cornerRadius: radius).fill(.theme(isHovered ? .navBgPrimaryHover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The button of the strip at the top of the window that closes and opens the side
/// navigation. PassVault's own, in place of the arrow at the bottom of the navigation
/// (PLAN.md, "Differences from the reference"): the symbol macOS has for a sidebar, in the
/// colours of an icon button of the navigation.
public struct SidebarToggleButton: View {
    private let label: String
    private let action: () -> Void
    @State private var isHovered = false

    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        let box = Metric.space(8)
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .regular))
                .frame(width: box, height: box)
                .foregroundStyle(.theme(.navFgPrimary))
                .background(BWControlShape().fill(.theme(isHovered ? .navBgPrimaryHover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The account at the bottom of the side navigation, as the reference has it behind the flag
/// `vfo1-foundation`: apps/desktop/src/auth/components/account-switcher/account-switcher-v2.component.html
/// with `expanded` and the menu "above-start" (PLAN.md, "Differences from the reference"). The
/// avatar is the button; beside it in the open navigation the name and the address.
public struct NavAccountButton: View {
    private let name: String?
    private let email: String
    private let id: String?
    private let image: NSImage?
    private let action: () -> Void
    @Environment(\.isSideNavigationCollapsed) private var isCollapsed

    /// - Parameters:
    ///   - name: the name of the account; without one the address stands in its place.
    ///   - action: opens the menu of the accounts.
    public init(name: String?, email: String, id: String?, image: NSImage? = nil, action: @escaping () -> Void) {
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = normalized?.isEmpty == false ? normalized : nil
        self.email = email
        self.id = id
        self.image = image
        self.action = action
    }

    /// The body text of the desktop app: `$font-size-base` 14 px, `$line-height-base` 1.42857143.
    static let nameStyle = TextStyle(size: 14, lineHeight: 20)
    /// `<small>` without a style of its own: the browser makes it "smaller", 14 / 1.2 px, with the
    /// same line height factor.
    static let emailStyle = TextStyle(size: 14 / 1.2, lineHeight: 14 / 1.2 * 1.42857143)

    public var body: some View {
        // "tw-flex tw-w-full tw-overflow-hidden tw-gap-2"; open "tw-justify-start tw-pl-1", on the rail "tw-justify-center"
        HStack(spacing: Metric.space(2)) {
            // button "tw-border-0 tw-bg-transparent tw-px-0 tw-py-3" around bit-avatar of the size "base"
            Button(action: action) {
                BWAvatar(text: name ?? email, id: id, image: image)
                    .padding(.vertical, Metric.space(3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            // The aria-label of the avatar: "name ?? email".
            .accessibilityLabel(name ?? email)
            if !isCollapsed {
                // "tw-flex tw-justify-center tw-flex-col tw-overflow-hidden", the colour of the navigation
                VStack(alignment: .leading, spacing: 0) {
                    // "tw-truncate"
                    Text(name ?? email)
                        .lineLimit(1)
                        .textStyle(Self.nameStyle)
                        .foregroundStyle(.theme(.navFgPrimary))
                    // small "tw-truncate tw-text-fg-body-subtle"
                    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       name.caseInsensitiveCompare(email) != .orderedSame {
                        Text(email)
                        .lineLimit(1)
                        .textStyle(Self.emailStyle)
                        .foregroundStyle(.theme(.navFgPrimary).opacity(0.85))
                    }
                }
            }
        }
        .padding(.leading, isCollapsed ? 0 : Metric.space(1))
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    }
}

/// The side navigation: the logo block, the items in a scroll area, and the bar at its bottom.
/// Source: side-nav.component.html and nav-logo.component.html. The bar of the reference has
/// the button that closes the navigation; PassVault has that button in the strip at the top
/// of the window and gives the bar to the account (PLAN.md, "Differences from the reference").
public struct SideNavigation<Items: View, Footer: View>: View {
    private let isCollapsed: Bool
    private let items: Items
    private let footer: Footer
    private let onHome: () -> Void
    @State private var isLogoHovered = false

    /// - Parameters:
    ///   - isCollapsed: the rail of icons. It is as wide as one item: 56 pixels.
    ///   - footer: what stands in the bar at the bottom, under the divider.
    public init(isCollapsed: Bool = false, onHome: @escaping () -> Void = {}, @ViewBuilder items: () -> Items, @ViewBuilder footer: () -> Footer) {
        self.isCollapsed = isCollapsed
        self.onHome = onHome
        self.items = items()
        self.footer = footer()
    }

    public static var railWidth: CGFloat { Metric.space(10) + 2 * Metric.space(3) }

    public var body: some View {
        VStack(spacing: 0) {
            logo
            BWScrollView(isNavigation: true) {
                VStack(spacing: 0) { items }
                    .environment(\.isSideNavigationCollapsed, isCollapsed)
            }
            // data-footer: "tw-shrink-0 tw-py-3 tw-flex tw-flex-col tw-gap-2 tw-border-solid tw-border-0 tw-border-t
            // tw-border-border-nav-divider", open "tw-px-3", on the rail a padding that centres 2.5 rem.
            Rectangle()
                .fill(.theme(.navBorderPrimary))
                .frame(height: 1)
            footer
                .environment(\.isSideNavigationCollapsed, isCollapsed)
                .padding(.horizontal, isCollapsed ? 0 : Metric.space(3))
                .padding(.vertical, Metric.space(3))
                .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        }
        // "tw-bg-bg-nav tw-text-fg-nav"
        .background(.theme(.navBgPrimary))
    }

    /// Compact home link approved in PLAN.md. The collapsed rail keeps only the goose key.
    private var logo: some View {
        Button(action: onHome) {
            HStack(spacing: Metric.space(3)) {
                Illustration(.gooseKey, isTemplate: true)
                    .frame(width: Metric.space(8), height: Metric.space(8))
                if !isCollapsed {
                    Text(BWText.settings.productName)
                        .font(BWFont.inter(26, weight: 700))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.theme(.navFgPrimary))
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .frame(height: Metric.space(16))
            .padding(.horizontal, Metric.space(3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isLogoHovered ? Color.theme(.navBgPrimaryHover) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Metric.space(2)))
        .onHover { isLogoHovered = $0 }
        .pointerStyle(.link)
        .accessibilityLabel(BWText["vault"])
        .help(BWText["vault"])
        .padding(.horizontal, Metric.space(2))
        .padding(.vertical, Metric.space(2))
    }
}
