import SwiftUI

public extension VerticalAlignment {
    private enum InputCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let inputCenter = VerticalAlignment(InputCenter.self)
}

/// `bit-form-field` with `bitInput`: libs/components/src/form-field/form-field.component.html,
/// field-container.directive.ts and input/input.directive.ts.
public struct BWFormField<Field: View, Suffix: View>: View {
    private let label: String
    private let isRequired: Bool
    private let isFocused: Bool
    private let error: String?
    private let hint: String?
    private let bottomMargin: CGFloat
    private let help: BWHelp?
    private let field: Field
    private let suffix: Suffix

    private let isTextArea: Bool

    /// - Parameters:
    ///   - bottomMargin: "tw-mb-4" unless the reference overrides it on the field.
    ///   - isTextArea: the field is a `BWTextArea`: "has-[textarea]:!tw-py-3" around it.
    ///   - help: the question mark at the end of the label (`slot="end"` of `bit-label`) and its popover.
    ///   - suffix: a `BWIconButton` of size small, or `EmptyView`.
    public init(_ label: String, isRequired: Bool = false, isFocused: Bool, error: String? = nil, hint: String? = nil,
                bottomMargin: CGFloat = Metric.space(4), isTextArea: Bool = false, help: BWHelp? = nil,
                @ViewBuilder field: () -> Field, @ViewBuilder suffix: () -> Suffix = { EmptyView() }) {
        self.label = label
        self.isRequired = isRequired
        self.isFocused = isFocused
        self.error = error
        self.hint = hint
        self.bottomMargin = bottomMargin
        self.isTextArea = isTextArea
        self.help = help
        self.field = field()
        self.suffix = suffix()
    }

    public var body: some View {
        // "tw-flex tw-flex-col tw-gap-2"
        VStack(alignment: .leading, spacing: Metric.space(2)) {
            // bit-label: "tw-inline-flex tw-gap-1 tw-items-baseline"
            HStack(alignment: .center, spacing: Metric.space(1)) {
                BWFieldLabel(label, isRequired: isRequired)
                if let help { BWHelpButton(help) }
            }
            container
            if let error {
                // bit-error: an icon and the message, small and in the danger colour.
                HStack(alignment: .firstTextBaseline, spacing: Metric.space(1)) {
                    IconView(.error, size: TextStyle.xs.size)
                    Text(error).textStyle(.xs)
                }
                .foregroundStyle(.theme(.fgDanger))
            } else if let hint {
                BWHint(hint)
            }
        }
        .padding(.bottom, bottomMargin)
    }

    private var container: some View {
        let hasSuffix = Suffix.self != EmptyView.self
        return BWFieldContainer(isFocused: isFocused, hasError: error != nil) {
            HStack(spacing: 0) {
                // content: "tw-px-3"; the input itself has no padding inside a form field.
                // A text area has its own lines of 20 pixels: the line of a one line input
                // would make it 2.5 pixels lower for each of its rows.
                Group {
                    if isTextArea { field } else { field.textStyle(.smTight) }
                }
                .foregroundStyle(.theme(.fgHeading))
                .padding(.horizontal, Metric.space(3))
                .padding(.vertical, isTextArea ? Metric.space(3) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                suffix
            }
            // "tw-pe-3 has-[[biticonbutton]:last-child]:tw-pe-1"
            .padding(.trailing, hasSuffix ? Metric.space(1) : Metric.space(3))
        }
    }
}

/// The label of a form field: "tw-flex tw-items-center tw-gap-0.5 tw-text-sm/5 tw-font-medium",
/// with the mark of a required field.
public struct BWFieldLabel: View {
    private let label: String
    private let isRequired: Bool

    public init(_ label: String, isRequired: Bool = false) {
        self.label = label
        self.isRequired = isRequired
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Metric.space(0.5)) {
            Text(label).textStyle(.smTight.weight(500))
            if isRequired {
                // sup: "tw-text-sm/5 tw-text-fg-danger tw-relative tw-top-[-1px]"
                Text("*")
                    .textStyle(.smTight)
                    .foregroundStyle(.theme(.fgDanger))
                    // The sup is a flex item, so it is not raised; only "tw-top-[-1px]" moves it.
                    .offset(y: -1)
                    .accessibilityLabel(BWText["required"])
            }
        }
    }
}

/// `bit-hint`: "tw-text-muted tw-font-normal tw-text-xs"
public struct BWHint: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .textStyle(.xs)
            .foregroundStyle(.theme(.textMuted))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `bitFieldContainer`: "tw-flex tw-w-full tw-border tw-rounded-xl tw-border-solid tw-border-border-strong
/// tw-bg-bg-secondary ... has-[:focus-visible]:tw-border-border-brand has-[:focus-visible]:tw-ring-1
/// has-[:focus-visible]:tw-ring-border-brand", "tw-text-sm/5 tw-min-h-10"
/// (libs/components/src/form-field/field-container.directive.ts).
public struct BWFieldContainer<Content: View>: View {
    private let isFocused: Bool
    private let hasError: Bool
    private let isHovered: Bool
    private let content: Content

    /// - Parameter isHovered: the ground of a field under the pointer, "tw-bg-bg-quaternary", for
    ///   the fields that have it (a select, the search field).
    public init(isFocused: Bool, hasError: Bool = false, isHovered: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.isFocused = isFocused
        self.hasError = hasError
        self.isHovered = isHovered
        self.content = content()
    }

    public var body: some View {
        let radius = Metric.fieldCornerRadius
        content
            .frame(minHeight: Metric.space(10) - 2)
            .padding(1)
            .background(RoundedRectangle(cornerRadius: radius).fill(.theme(isHovered && !isFocused ? .bgQuaternary : .bgSecondary)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(borderColour), lineWidth: 1))
            // The ring is one more pixel outside the border.
            .overlay(RoundedRectangle(cornerRadius: radius + 1).strokeBorder(.theme(ringColour), lineWidth: 1).padding(-1))
            .alignmentGuide(.inputCenter) { $0[VerticalAlignment.center] }
    }

    private var borderColour: ThemeColor {
        if isFocused { return .borderBrand }
        return hasError ? .borderDanger : .borderStrong
    }

    private var ringColour: ThemeColor {
        if isFocused { return .borderBrand }
        return hasError ? .borderDanger : .clear
    }
}

/// The text input inside a form field. `bitInput` draws nothing of its own there:
/// "tw-border-none focus:tw-outline-none tw-bg-transparent tw-text-fg-heading".
public struct BWTextInput: View {
    @Binding private var text: String
    private let isSecure: Bool
    private let isMonospaced: Bool
    private let placeholder: String

    public init(text: Binding<String>, isSecure: Bool = false, isMonospaced: Bool = false, placeholder: String = "") {
        _text = text
        self.isSecure = isSecure
        self.placeholder = placeholder
        self.isMonospaced = isMonospaced
    }

    public var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        // The desktop styles set every input to 14 pixels on a 20 pixel line (apps/desktop/src/scss/base.scss).
        // "tw-font-mono" where the reference asks for it.
        .font(Font(isMonospaced ? BWFont.monoCT(TextStyle.body.size) : BWFont.interCT(TextStyle.body.size)))
        .frame(height: TextStyle.body.lineHeight)
    }
}

/// `textarea bitInput` inside a form field: several lines in the font of a desktop input.
public struct BWTextArea: View {
    @Binding private var text: String
    private let rows: Int

    public init(text: Binding<String>, rows: Int = 5) {
        _text = text
        self.rows = rows
    }

    public var body: some View {
        let font = BWFont.interCT(TextStyle.body.size)
        TextEditor(text: $text)
            .font(Font(font))
            // A line of 20 pixels, as every input of the desktop app has.
            .lineSpacing(max(TextStyle.body.lineHeight - CTFontGetAscent(font) - CTFontGetDescent(font) - CTFontGetLeading(font), 0))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            // The text view keeps five pixels beside its text; the reference has none.
            .padding(.horizontal, -5)
            .frame(height: CGFloat(rows) * TextStyle.body.lineHeight)
    }
}
