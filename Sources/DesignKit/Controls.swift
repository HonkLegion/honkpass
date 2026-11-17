import SwiftUI

// Copies of the controls of libs/components. Each comment names the source and quotes the
// classes it copies. Sizes are in points with one rem = 14 (Metric).

// MARK: Button

/// `bitButton`, size default: libs/components/src/button/button.component.ts and
/// shared/base-button.directive.ts.
public struct BWButton: View {
    public enum Kind: Sendable {
        case primary, secondary
        /// "tw-bg-bg-danger tw-border-border-danger hover:tw-bg-bg-danger-strong hover:tw-border-border-danger-strong"
        case danger
        /// The primary button with its colours turned around: its text has the colour of the
        /// primary ground, and its ground the colour of the primary text. PassVault's own,
        /// for the strip at the top of the window (PLAN.md, "Differences from the reference").
        case primaryInverted
    }

    private let title: String
    private let kind: Kind
    private let icon: BWIcon?
    private let startIcon: BWIcon?
    private let isBlock: Bool
    private let isSmall: Bool
    private let isCapsule: Bool
    private let action: () -> Void
    @Environment(\.hasFloatingActionBackdrop) private var hasFloatingActionBackdrop

    /// - Parameters:
    ///   - icon: an icon inside the label, which has "tw-mr-1".
    ///   - startIcon: the `startIcon` input of bitButton, which sits in a row with "tw-gap-2".
    ///   - isSmall: `size="small"`.
    ///   - isCapsule: round both ends without changing the control's dimensions.
    public init(_ title: String, kind: Kind = .secondary, icon: BWIcon? = nil, startIcon: BWIcon? = nil, isBlock: Bool = true,
                isSmall: Bool = false, isCapsule: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.icon = icon
        self.startIcon = startIcon
        self.isBlock = isBlock
        self.isSmall = isSmall
        self.isCapsule = isCapsule
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: startIcon == nil ? Metric.space(1) : Metric.space(2)) {
                if let icon = startIcon ?? icon { IconView(icon, size: TextStyle.smTight.size) }
                Text(title)
            }
            // "tw-pt-[calc(0.625rem_-_1px)] tw-pb-[calc(0.625rem_-_1px)] tw-px-4 tw-text-sm/5", "tw-font-medium";
            // small: "tw-pt-[calc(theme(spacing.2)_-_1px)] tw-pb-[...] tw-px-3 tw-text-xs/4"
            .textStyle(isSmall ? TextStyle(size: 0.75 * Metric.rem, lineHeight: Metric.rem, weight: 500) : .smTight.weight(500))
            .padding(.vertical, (isSmall ? Metric.space(2) : 0.625 * Metric.rem) - 1)
            .padding(.horizontal, Metric.space(isSmall ? 3 : 4))
            .frame(maxWidth: isBlock ? .infinity : nil)
            // The one pixel border is outside the padding.
            .padding(1)
        }
        .buttonStyle(Style(kind: kind, isCapsule: isCapsule))
        .background {
            if hasFloatingActionBackdrop {
                BWFloatingActionBackdrop(cornerRadius: 0)
                    .clipShape(BWControlShape(isCapsule: isCapsule))
            }
        }
    }

    private struct Style: ButtonStyle {
        let kind: Kind
        let isCapsule: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            let active = isHovered || configuration.isPressed
            let colours = colours(active: active)
            let shape = BWControlShape(isCapsule: isCapsule)
            configuration.label
                .foregroundStyle(.theme(colours.text))
                // "tw-rounded-xl", "tw-border tw-border-solid"
                .background(shape.fill(.theme(colours.background)))
                .overlay(shape.strokeBorder(.theme(colours.border), lineWidth: 1))
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .pointerStyle(isEnabled ? .link : .default)
        }

        private func colours(active: Bool) -> (text: ThemeColor, background: ThemeColor, border: ThemeColor) {
            guard isEnabled else {
                // "aria-disabled:!tw-text-fg-inactive", "aria-disabled:!tw-bg-bg-inactive aria-disabled:tw-border-border-base"
                return (.fgInactive, .bgInactive, .borderBase)
            }
            switch kind {
            case .primary:
                // "tw-border-border-brand tw-bg-bg-brand hover:tw-bg-bg-brand-strong hover:tw-border-border-brand-strong", "tw-text-fg-contrast"
                return (.fgContrast, active ? .bgBrandStrong : .bgBrand, active ? .borderBrandStrong : .borderBrand)
            case .secondary:
                // "tw-bg-bg-secondary tw-border-border-base tw-text-fg-heading hover:tw-bg-bg-quaternary hover:tw-text-fg-brand-strong"
                return (active ? .fgBrandStrong : .fgHeading, active ? .bgQuaternary : .bgSecondary, .borderBase)
            case .danger:
                return (.fgContrast, active ? .bgDangerStrong : .bgDanger, active ? .borderDangerStrong : .borderDanger)
            case .primaryInverted:
                return (active ? .bgBrandStrong : .bgBrand, .fgContrast, active ? .borderBrandStrong : .borderBrand)
            }
        }
    }
}

// MARK: Icon button

public extension EnvironmentValues {
    /// Changes only icon artwork, preserving button frames and hit areas.
    @Entry var iconButtonGlyphSize: CGFloat? = nil
    /// Changes only the hover surface, preserving button frames and hit areas.
    @Entry var iconButtonHoverSize: CGFloat? = nil
}

/// `bitIconButton`: libs/components/src/icon-button/icon-button.component.ts.
public struct BWIconButton: View {
    public enum Size: Sendable {
        /// "tw-text-xl tw-size-8": the size inside a form field (`bitSuffix`).
        case small
        /// "tw-text-2xl tw-size-10"
        case regular

        /// The side of the button.
        public var box: CGFloat { self == .small ? Metric.space(8) : Metric.space(10) }
        var icon: CGFloat { self == .small ? 1.25 * Metric.rem : 1.5 * Metric.rem }
    }

    public enum Kind: Sendable {
        /// The default: "tw-text-fg-heading hover:tw-text-fg-brand" on a transparent ground.
        case primaryGhost
        /// "tw-text-fg-heading tw-bg-bg-primary tw-border-bg-primary hover:tw-bg-bg-quaternary"
        case contrast
        /// "tw-text-fg-danger hover:tw-text-fg-danger" on a transparent ground.
        case dangerGhost
    }

    private let icon: BWIcon
    private let label: String
    private let tooltip: String?
    private let size: Size
    private let kind: Kind
    private let isRound: Bool
    private let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hasFloatingActionBackdrop) private var hasFloatingActionBackdrop
    @Environment(\.iconButtonGlyphSize) private var glyphSize
    @Environment(\.iconButtonHoverSize) private var hoverSize

    /// - Parameter tooltip: `bitTooltip` of the button, where it says more than the label,
    ///   which then is the name of the button only.
    public init(_ icon: BWIcon, label: String, size: Size = .regular, kind: Kind = .primaryGhost, isRound: Bool = false,
                tooltip: String? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.tooltip = tooltip
        self.size = size
        self.kind = kind
        self.isRound = isRound
        self.action = action
    }

    public var body: some View {
        let radius = isRound ? size.box / 2 : Metric.containerCornerRadius
        let hoverBox = hoverSize ?? size.box
        let hoverRadius = isRound ? hoverBox / 2 : Metric.containerCornerRadius
        Button(action: action) {
            IconView(icon, size: glyphSize ?? size.icon)
                .frame(width: size.box, height: size.box)
                .foregroundStyle(.theme(foreground))
                .background {
                    RoundedRectangle(cornerRadius: hoverRadius).fill(.theme(background))
                        .frame(width: hoverBox, height: hoverBox)
                }
                .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .background {
            if hasFloatingActionBackdrop { BWFloatingActionBackdrop(cornerRadius: radius) }
        }
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : .default)
        .help(tooltip ?? label)
        .accessibilityLabel(label)
    }

    private var foreground: ThemeColor {
        guard isEnabled else { return .fgInactive }
        switch kind {
        case .primaryGhost: return isHovered ? .fgBrand : .fgHeading
        case .contrast: return .fgHeading
        case .dangerGhost: return .fgDanger
        }
    }

    private var background: ThemeColor {
        switch kind {
        case .primaryGhost, .dangerGhost: isHovered && isEnabled ? .bgHover : .clear
        case .contrast: isHovered && isEnabled ? .bgQuaternary : .bgPrimary
        }
    }
}

// MARK: Link

/// `bitLink`, linkType primary: libs/components/src/link/link.component.ts.
public struct BWLink: View {
    private let title: String
    private let size: CGFloat
    private let weight: CGFloat
    private let colour: ThemeColor
    private let lineHeight: CGFloat?
    private let startIcon: BWIcon?
    private let leadingIcon: BWIcon?
    private let trailingIcon: BWIcon?
    private let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    /// A link takes the font size of the text around it. `weight` and `colour` are for the places
    /// where the reference wraps the text in its own classes. The icons have "bwi-fw bwi-sm".
    /// `lineHeight` is for a link with its own leading class; the default is "tw-leading-none".
    /// `startIcon` is the input of bitLink: the icon at the size of the text, and "tw-gap-2"
    /// before the title (link.component.html).
    public init(_ title: String, size: CGFloat = TextStyle.body.size, weight: CGFloat = 600, colour: ThemeColor = .fgBrand,
                lineHeight: CGFloat? = nil, startIcon: BWIcon? = nil, leadingIcon: BWIcon? = nil, trailingIcon: BWIcon? = nil,
                action: @escaping () -> Void) {
        self.startIcon = startIcon
        self.title = title
        self.size = size
        self.weight = weight
        self.colour = colour
        self.lineHeight = lineHeight
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            // "tw-font-semibold", "tw-text-fg-brand hover:tw-text-fg-brand-strong", "[&:hover_span]:tw-underline"
            // "tw-leading-none": the line is as high as the font size.
            // div "tw-flex tw-gap-2 tw-items-center" around the start icon and the text.
            HStack(alignment: .center, spacing: Metric.space(2)) {
                if let startIcon { IconView(startIcon, size: size) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let leadingIcon { smallIcon(leadingIcon) }
                    Text(title)
                        .underline(isHovered && isEnabled)
                        .lineLimit(1)
                        .textStyle(TextStyle(size: size, lineHeight: lineHeight ?? size, weight: weight))
                    if let trailingIcon { smallIcon(trailingIcon) }
                }
            }
            .foregroundStyle(.theme(isEnabled ? (isHovered ? .fgBrandStrong : colour) : .fgInactive))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : .default)
    }
}

extension BWLink {
    /// "bwi-fw bwi-sm": 0.875 of the text size in a box 18/14 of that wide.
    fileprivate func smallIcon(_ icon: BWIcon) -> some View {
        IconView(icon, size: 0.875 * size)
            .frame(width: 0.875 * size * 18 / 14)
    }
}

// MARK: Checkbox

/// `bitCheckbox` inside `bit-form-control`: libs/components/src/checkbox/checkbox.component.ts and
/// form-control/form-control.component.html. `hint` is the `bit-hint` under the label; `help`
/// adds the question mark after the label, which opens its popover.
public struct BWCheckbox: View {
    private let title: String
    private let code: String?
    private let hint: String?
    private let help: BWHelp?
    @Binding private var isOn: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter code: a `code` element after the title, as the shortcut in the label of the
    ///   autotype row of the reference's settings.
    public init(_ title: String, code: String? = nil, isOn: Binding<Bool>, hint: String? = nil, help: BWHelp? = nil) {
        self.title = title
        self.code = code
        self.hint = hint
        self.help = help
        _isOn = isOn
    }

    public var body: some View {
        // label: "tw-items-start tw-gap-2 tw-inline-flex"
        HStack(alignment: .top, spacing: Metric.space(2)) {
            box
            // span "tw-inline-flex tw-flex-col tw-pt-px"
            VStack(alignment: .leading, spacing: 0) {
                // bit-label: "tw-inline-flex tw-gap-1 tw-items-baseline"
                HStack(alignment: .center, spacing: Metric.space(1)) {
                    // "tw-leading-5 tw-font-medium" on body2, "tw-text-fg-heading" or, disabled, "tw-text-fg-inactive"
                    Text(title)
                        .textStyle(.smTight.weight(500))
                        .foregroundStyle(.theme(isEnabled ? .fgHeading : .fgInactive))
                    if let code {
                        // span "tw-flex tw-items-center tw-gap-2" around the text and the code.
                        Text(code)
                            .font(Font(BWFont.monoCT(TextStyle.sm.size)))
                            .foregroundStyle(.theme(isEnabled ? .fgHeading : .fgInactive))
                            .padding(.leading, Metric.space(1))
                    }
                    if let help { BWHelpButton(help).offset(y: -1) }
                }
                if let hint {
                    // bit-hint in a span "tw-leading-none". Its line box is a little higher than
                    // its text lines (measured in docs/reference/settings-app-*.png).
                    BWHint(hint).padding(.bottom, 1.25)
                }
            }
            .padding(.top, 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : .default)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        // Without a hint the label is an inline box on the 20 pixel line of its block: the row is
        // 24.5 pixels high (measured in docs/reference/log-in-email-*.png).
        .frame(height: hint == nil ? 24.5 : nil, alignment: .top)
    }

    /// Disabled: "disabled:before:tw-border-border-base disabled:before:tw-bg-bg-inactive" and
    /// "checked:disabled:after:tw-bg-fg-inactive".
    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0.5 * Metric.rem).fill(.theme(isHovered && isEnabled ? .bgHover : .clear))
            RoundedRectangle(cornerRadius: 0.25 * Metric.rem)
                .fill(.theme(isEnabled ? (isOn ? .bgBrand : .bgTertiary) : .bgInactive))
                .frame(width: Metric.space(4), height: Metric.space(4))
            RoundedRectangle(cornerRadius: 0.25 * Metric.rem)
                .strokeBorder(.theme(isEnabled ? (isOn ? .borderBrand : .borderStrong) : .borderBase), lineWidth: 1)
                .frame(width: Metric.space(4), height: Metric.space(4))
            if isOn {
                IconView(.check, size: 0.75 * Metric.rem).foregroundStyle(.theme(isEnabled ? .fgContrast : .fgInactive))
            }
        }
        .frame(width: Metric.space(6), height: Metric.space(6))
        .padding(.top, -1)
        .padding(.bottom, -1)
        .padding(.leading, -1)
    }
}

// MARK: Avatar

/// `bit-avatar`, size base: libs/components/src/avatar/avatar.component.ts and avatar-color.ts.
public struct BWAvatar: View {
    private let text: String
    private let id: String?
    private let image: NSImage?

    public init(text: String, id: String? = nil, image: NSImage? = nil) {
        self.text = text
        self.id = id
        self.image = image
    }

    public var body: some View {
        // "tw-size-8"; the letters are 12 units high in a 32 unit box.
        let size = Metric.space(8)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(Self.initials(text))
            }
        }
            .font(BWFont.inter(12 * size / 32))
            .foregroundStyle(.theme(.fgWhite))
            .frame(width: size, height: size)
            .background(Circle().fill(.theme(Self.colour(id: id, text: text))))
            .clipShape(Circle())
    }

    /// The first letters of the first two words, else the first two characters, in upper case.
    static func initials(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : String(text.prefix(2))
        return letters.uppercased()
    }

    /// `getAvatarDefaultColor`: a hash of the id, or of the upper-case text, picks one of five colours.
    static func colour(id: String?, text: String) -> ThemeColor {
        let seed = (id?.isEmpty == false) ? id! : text.uppercased()
        // JavaScript: hash = char + ((hash << 5) - hash). Only the shift works on 32 bits.
        var hash: Int64 = 0
        for unit in seed.utf16 {
            let shifted = Int64(Int32(truncatingIfNeeded: hash) &<< 5)
            hash = Int64(unit) + (shifted - hash)
        }
        let palette: [ThemeColor] = [
            ThemeColor(light: 0x007C95FF, dark: 0x007C95FF), // teal
            ThemeColor(light: 0xC71800FF, dark: 0xC71800FF), // coral
            ThemeColor(light: 0x175DDCFF, dark: 0x175DDCFF), // brand
            ThemeColor(light: 0x008236FF, dark: 0x008236FF), // green
            ThemeColor(light: 0x8200DBFF, dark: 0x8200DBFF), // purple
        ]
        return palette[Int(hash.magnitude) % palette.count]
    }
}
