import AppKit
import SwiftUI

// Controls of the vault window: search field, owner chip, checkbox box, card picture, empty state.

/// `bit-search`: libs/components/src/search/search.component.html on a bitFieldContainer.
public struct BWSearchField: View {
    @Binding private var text: String
    private let placeholder: String
    private let takesFocus: Bool
    private let focusRequest: Int
    private let isSmall: Bool
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    /// - Parameters:
    ///   - takesFocus: `appAutofocus`, the field takes the focus when it appears.
    ///   - focusRequest: the field takes the focus whenever this number changes.
    public init(text: Binding<String>, placeholder: String, takesFocus: Bool = false, focusRequest: Int = 0,
                isSmall: Bool = false) {
        _text = text
        self.placeholder = placeholder
        self.takesFocus = takesFocus
        self.focusRequest = focusRequest
        self.isSmall = isSmall
    }

    public var body: some View {
        // form: "tw-items-center tw-w-full tw-ps-3 tw-pe-1", container "tw-text-sm/5 tw-min-h-10"
        HStack(spacing: 0) {
            IconView(.search, size: TextStyle.smTight.size)
                .foregroundStyle(.theme(.fgHeading))
            // input: "tw-bg-transparent tw-text-fg-heading tw-placeholder-fg-body-subtle tw-ps-2 tw-pe-1"
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.theme(.fgBodySubtle)))
                .textFieldStyle(.plain)
                .font(BWFont.inter(TextStyle.smTight.size))
                .foregroundStyle(.theme(.fgHeading))
                .focused($isFocused)
                // handleInputKeydown: Escape alone empties a search that has a text and goes no
                // further, so what is around the field closes on a second press only.
                .onKeyPress(.escape, phases: .down) { press in
                    guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]), !text.isEmpty else {
                        return .ignored
                    }
                    clear()
                    return .handled
                }
                .padding(.leading, Metric.space(2))
                .padding(.trailing, Metric.space(1))
            if !text.isEmpty {
                // `[label]="'resetSearch'"` and `[bitTooltip]="'clearSearchTooltip'"`
                BWIconButton(.clear, label: BWText["resetSearch"], size: .small, tooltip: BWText["clearSearchTooltip"],
                             action: clear)
            }
        }
        .padding(.leading, Metric.space(3))
        .padding(.trailing, Metric.space(1))
        // Match the small Add button, including the surrounding one-point border.
        .frame(minHeight: Metric.space(isSmall ? 8 : 10) - 2,
               maxHeight: isSmall ? Metric.space(8) - 2 : nil)
        .padding(1)
        // "tw-bg-bg-secondary", hover "tw-bg-bg-quaternary" while not focused
        .background(BWControlShape().fill(.theme(isHovered && !isFocused ? .bgQuaternary : .bgSecondary)))
        .overlay(BWControlShape().strokeBorder(.theme(isFocused ? .borderBrand : .borderStrong), lineWidth: 1))
        .overlay(BWControlShape().strokeBorder(.theme(isFocused ? .borderBrand : .clear), lineWidth: 1).padding(-1))
        .onHover { isHovered = $0 }
        .onAppear { if takesFocus { isFocused = true } }
        .onChange(of: focusRequest) { isFocused = true }
    }

    /// `clearSearch`: the field is empty and has the keyboard, also after a click on the button.
    private func clear() {
        text = ""
        isFocused = true
    }
}

/// `bit-chip-action`, variant primary, size large: libs/components/src/chips/shared/base-chip.directive.ts.
public struct BWChip: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        // "tw-rounded-md tw-border tw-font-medium", "tw-text-sm/5 tw-ps-2 tw-py-[calc(theme(spacing.1)_-_1px)] tw-pe-2",
        // "tw-bg-bg-brand-softer tw-border-border-brand-soft tw-text-fg-brand-strong".
        // The chip is a button, and the desktop app has "button { border: none }"
        // (apps/desktop/src/scss/base.scss) and no Tailwind preflight, so "tw-border" sets a
        // width without a style: the chip has no border and is 22.5 pixels high
        // (measured in docs/reference/vault-all-items-*.png).
        Text(text)
            .textStyle(.smTight.weight(500))
            .lineLimit(1)
            .foregroundStyle(.theme(.fgBrandStrong))
            .padding(.horizontal, Metric.space(2))
            .padding(.vertical, Metric.space(1) - 1)
            .background(RoundedRectangle(cornerRadius: 0.375 * Metric.rem).fill(.theme(.bgBrandSofter)))
    }
}

/// The box of `bitCheckbox` alone, as in a table cell: a 24 pixel target around a 16 pixel box.
public struct BWCheckboxBox: View {
    @Binding private var isOn: Bool
    private let label: String
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(isOn: Binding<Bool>, label: String) {
        _isOn = isOn
        self.label = label
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The picture of a card brand: `.credit-card-icon`, 24 by 19 pixels in a list, one file for each appearance.
public struct CardBrandImage: View {
    private let brand: String
    private let width: CGFloat
    private let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(brand: String, width: CGFloat = 24, height: CGFloat = 19) {
        self.brand = brand
        self.width = width
        self.height = height
    }

    /// Whether DesignKit has a picture for this brand name.
    public static func exists(for brand: String) -> Bool {
        url(brand, dark: false) != nil
    }

    public var body: some View {
        if let url = Self.url(brand, dark: colorScheme == .dark), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }

    private static func url(_ brand: String, dark: Bool) -> URL? {
        let file = brand.lowercased().replacingOccurrences(of: " ", with: "_") + (dark ? "-dark" : "-light")
        return Bundle.module.url(forResource: file, withExtension: "png", subdirectory: "Resources/Cards")
    }
}

/// `bit-status-lockup`: the empty state of a list. libs/components/src/status-lockup.
public struct StatusLockup<Action: View>: View {
    private let illustration: Illustration.Name
    private let title: String
    private let description: String
    private let action: Action

    /// `action` is the button slot; pass `EmptyView()` for none.
    public init(illustration: Illustration.Name, title: String, description: String, @ViewBuilder action: () -> Action) {
        self.illustration = illustration
        self.title = title
        self.description = description
        self.action = action()
    }

    public var body: some View {
        // "tw-flex tw-flex-col tw-items-center tw-justify-center tw-p-6", inner "tw-gap-6 tw-max-w-[600px]"
        VStack(spacing: Metric.space(6)) {
            // graphic: "[&_bit-svg]:tw-size-20"
            Illustration(illustration).frame(width: Metric.space(20), height: Metric.space(20))
            // texts: "tw-flex tw-flex-col tw-gap-2"
            VStack(spacing: Metric.space(2)) {
                // h3 "tw-font-medium tw-text-center tw-text-fg-heading" "tw-text-base"
                Text(title)
                    .textStyle(.base.weight(500))
                    .foregroundStyle(.theme(.fgHeading))
                // bitTypography body2 "tw-text-center tw-text-fg-body"
                Text(description)
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.fgBody))
            }
            .multilineTextAlignment(.center)
            // button slot: "tw-space-x-2 empty:tw-hidden"
            action
        }
        .frame(maxWidth: 600)
        .padding(Metric.space(6))
        .frame(maxWidth: .infinity)
    }
}
