import SwiftUI

// The parts of a read-only item view: card, section title, read-only form field, coloured password
// and the countdown of a verification code. Sources: libs/components/src/card, section, form-field,
// color-password and libs/vault/src/components/totp-countdown.

// MARK: Card

/// `bit-card`: "tw-box-border tw-block tw-bg-bg-primary tw-text-fg-heading tw-border tw-border-solid
/// tw-border-border-base tw-rounded-xl", "tw-p-4 [@media(min-width:769px)]:tw-p-6".
public struct BWCard<Content: View>: View {
    private let content: Content
    @Environment(\.bwWindowWidth) private var windowWidth

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let radius = Metric.containerCornerRadius
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.theme(.fgHeading))
            .padding(windowWidth >= 769 ? Metric.space(6) : Metric.space(4))
            .padding(1)
            .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderBase), lineWidth: 1))
    }
}

public extension EnvironmentValues {
    /// The width of the window content, for the classes of the reference that ask the viewport
    /// (media queries). The default is a wide window.
    @Entry var bwWindowWidth: CGFloat = 1200
}

/// `bit-section-header` with an `h2 bitTypography="h6"` before a card: "tw-pb-1 tw-px-1", the title
/// "!tw-text-sm tw-text-main tw-font-medium" without its margin.
public struct BWSectionHeader: View {
    private let title: String
    private let isLarge: Bool

    /// - Parameter isLarge: the heading has bitTypography "h5", "!tw-text-base", where the
    ///   other sections have "h6", "!tw-text-sm".
    public init(_ title: String, isLarge: Bool = false) {
        self.title = title
        self.isLarge = isLarge
    }

    public var body: some View {
        Text(title)
            .textStyle((isLarge ? TextStyle.base : .sm).weight(500))
            .foregroundStyle(.theme(.textMain))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.space(1))
            .padding(.bottom, Metric.space(1))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Read-only field

/// `bit-form-field` around a read-only `bitInput`: the label directly over a container without ground
/// and border ("tw-bg-transparent tw-border-transparent", "tw-min-h-10"), the value flush with the
/// label and the `bitSuffix` buttons edge to edge at the end ("has-[[biticonbutton]:last-child]:tw-pe-1").
/// The fields of one card are 14 pixels apart ("tw-mb-4", none after the last one): put them in a
/// `VStack` with that spacing.
public struct BWReadOnlyField<Value: View, Suffix: View>: View {
    private let label: String
    private let isTextArea: Bool
    private let value: Value
    private let suffix: Suffix

    /// - Parameters:
    ///   - label: an empty label takes no room, as in the reference.
    ///   - isTextArea: the value is a `textarea`: "has-[textarea]:!tw-py-3" around it, the buttons at the
    ///     top with "group-has-[textarea]/form-field:tw-pt-1".
    ///   - suffix: `BWIconButton`s of size small, or `EmptyView`.
    public init(_ label: String, isTextArea: Bool = false,
                @ViewBuilder value: () -> Value, @ViewBuilder suffix: () -> Suffix = { EmptyView() }) {
        self.label = label
        self.isTextArea = isTextArea
        self.value = value()
        self.suffix = suffix()
    }

    public var body: some View {
        let hasSuffix = Suffix.self != EmptyView.self
        VStack(alignment: .leading, spacing: 0) {
            if !label.isEmpty {
                // label: "tw-flex tw-items-center tw-gap-0.5 tw-text-sm/5 tw-font-medium"
                Text(label)
                    .lineLimit(1)
                    .textStyle(.smTight.weight(500))
            }
            HStack(alignment: isTextArea ? .top : .center, spacing: 0) {
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, isTextArea ? Metric.space(3) : 0)
                HStack(spacing: 0) { suffix }
                    .padding(.top, isTextArea ? Metric.space(1) : 0)
            }
            .padding(.trailing, hasSuffix ? Metric.space(1) : Metric.space(3))
            .frame(minHeight: Metric.space(10) - 2)
            // The transparent border of the container.
            .padding(1)
        }
        .foregroundStyle(.theme(.fgHeading))
    }
}

/// The value of a read-only `input`: one line in the font of a desktop input, cut at the end of
/// the field. `isHidden` is `type="password"`: one bullet for each character.
public struct BWFieldValue: View {
    private let text: String
    private let isHidden: Bool
    private let isMonospaced: Bool

    public init(_ text: String, isHidden: Bool = false, isMonospaced: Bool = false) {
        self.text = text
        self.isHidden = isHidden
        self.isMonospaced = isMonospaced
    }

    public var body: some View {
        let style = isMonospaced ? TextStyle.body.monospaced : TextStyle.body
        // The field is as wide as its place, whatever the length of the text; the text lies over it
        // and is cut at its end without an ellipsis, like the value of an `input`.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: style.lineHeight)
            .overlay(alignment: .leading) {
                Group {
                    if isHidden {
                        Text(String(repeating: "\u{2022}", count: text.count))
                    } else {
                        Text(text).textSelection(.enabled)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .textStyle(style)
            }
            .clipped()
    }
}

/// The value of a read-only `textarea`: lines of the desktop input font. With `rows` the area is
/// that many lines high and scrolls; without, it is as high as its text (`cdkTextareaAutosize`).
public struct BWFieldText: View {
    private let text: String
    private let rows: Int?
    private let isMonospaced: Bool

    public init(_ text: String, rows: Int? = nil, isMonospaced: Bool = false) {
        self.text = text
        self.rows = rows
        self.isMonospaced = isMonospaced
    }

    public var body: some View {
        let style = isMonospaced ? TextStyle.body.monospaced : TextStyle.body
        let lines = Text(text)
            .textSelection(.enabled)
            .textStyle(style)
            .frame(maxWidth: .infinity, alignment: .leading)
        // "[&:is(textarea)]:tw-min-h-[30px]": one line of text still makes an area of 30 pixels.
        if let rows {
            ScrollView { lines }
                .frame(height: max(CGFloat(rows) * style.lineHeight, 30))
        } else {
            lines.frame(minHeight: 30, alignment: .top)
        }
    }
}

// MARK: Coloured password

/// `bit-color-password`: every character in "tw-font-mono", a letter in "tw-text-main", a digit in
/// "tw-text-primary-600" and any other sign in "tw-text-danger". It breaks anywhere.
public struct BWColorPassword: View {
    private let password: String
    private let showsCount: Bool
    private let style: TextStyle

    /// - Parameters:
    ///   - showsCount: every character in its own cell with its position under it.
    ///   - style: the text of the place: a form field by default; "tw-text-base" in the generator.
    public init(_ password: String, showsCount: Bool = false, style: TextStyle = .smTight) {
        self.password = password
        self.showsCount = showsCount
        self.style = style
    }

    public var body: some View {
        if showsCount {
            // "tw-inline-flex tw-flex-col tw-items-center tw-w-7 tw-py-1 odd:tw-bg-secondary-100 even:tw-bg-background"
            FlowLayout {
                ForEach(Array(password.enumerated()), id: \.offset) { index, character in
                    VStack(spacing: 0) {
                        Text(String(character))
                            .textStyle(.smTight.monospaced)
                            .foregroundStyle(.theme(Self.colour(of: character)))
                        // "tw-whitespace-nowrap tw-text-xs tw-leading-5 tw-text-main"
                        Text(String(index + 1))
                            .textStyle(TextStyle(size: TextStyle.xs.size, lineHeight: 1.25 * Metric.rem, isMonospaced: true))
                            .foregroundStyle(.theme(.textMain))
                    }
                    .padding(.vertical, Metric.space(1))
                    .frame(width: Metric.space(7))
                    .background(.theme(index.isMultiple(of: 2) ? .secondary100 : .bgPrimary))
                }
            }
        } else {
            Text(Self.coloured(password))
                .textSelection(.enabled)
                .textStyle(style.monospaced)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func colour(of character: Character) -> ThemeColor {
        if character.isLetter { return .textMain }
        if character.isNumber { return .primary600 }
        // An emoji keeps the text colour.
        if character.unicodeScalars.contains(where: \.properties.isEmojiPresentation) { return .textMain }
        return .danger600
    }

    private static func coloured(_ password: String) -> AttributedString {
        var result = AttributedString()
        for character in password {
            var piece = AttributedString(String(character))
            piece.foregroundColor = colour(of: character).color
            result.append(piece)
        }
        return result
    }
}

/// Rows of views that continue on the next row when one is full, like inline boxes.
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let places = arrange(width: bounds.width, subviews: subviews).places
        for (subview, place) in zip(subviews, places) {
            subview.place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), anchor: .topLeading,
                          proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, places: [CGPoint]) {
        var places: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            places.append(CGPoint(x: x, y: y))
            x += size.width
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x)
        }
        return (CGSize(width: widest, height: y + rowHeight), places)
    }
}

// MARK: Verification code countdown

/// `bitTotpCountdown`: the seconds a verification code still lives, inside a ring that runs out.
/// The picture is 28 units wide and shown in "tw-size-7". In the last seven seconds it is in the
/// danger colour.
public struct BWTotpCountdown: View {
    private let remaining: Int
    private let period: Int

    public init(remaining: Int, period: Int) {
        self.remaining = remaining
        self.period = max(period, 1)
    }

    public var body: some View {
        let size = Metric.space(7)
        let scale = size / 28
        let isLow = remaining <= 7
        ZStack {
            // circle r="11" stroke-width="1" stroke-dasharray="71": the whole thin ring.
            Circle()
                .strokeBorder(lineWidth: scale)
                .frame(width: (22 + 1) * scale, height: (22 + 1) * scale)
            // circle r="9.5" stroke-width="2" stroke-dasharray="60": what is left of the period,
            // from the top (the picture is turned by -90 degrees).
            Circle()
                .inset(by: scale)
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(period))
                .stroke(lineWidth: 2 * scale)
                .rotationEffect(.degrees(-90))
                .frame(width: (19 + 2) * scale, height: (19 + 2) * scale)
            // span bitTypography="helper"
            Text(String(remaining))
                .textStyle(.xs)
                .foregroundStyle(.theme(isLow ? .danger600 : .textMain))
        }
        // "tw-stroke-text-main" or "tw-stroke-danger-600"; the text is "tw-text-danger".
        .foregroundStyle(.theme(isLow ? .danger600 : .textMain))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
