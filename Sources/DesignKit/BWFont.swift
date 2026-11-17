import AppKit
import CoreText
import SwiftUI
import Synchronization

/// Inter text metrics, monospaced text and native shortcut typography.
public enum BWFont {
    private struct FontKey: Hashable {
        let family: String
        let size: CGFloat
        let weight: CGFloat
    }

    // CTFont values are immutable. Keep only font objects, never measured vault strings.
    private static let fonts = Mutex<[FontKey: CTFont]>([:])

    private static func cached(_ family: String, size: CGFloat, weight: CGFloat = 400,
                               make: () -> CTFont) -> CTFont {
        let key = FontKey(family: family, size: size, weight: weight)
        return fonts.withLock { fonts in
            if let font = fonts[key] { return font }
            let font = make()
            if fonts.count >= 128 { fonts.removeAll(keepingCapacity: true) }
            fonts[key] = font
            return font
        }
    }

    private static let registered: Bool = {
        for name in ["inter.woff2"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/Fonts") else {
                assertionFailure("DesignKit font \(name) is missing")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    // Variation axes of Inter: weight and optical size.
    private static let weightAxis = 0x7767_6874 // "wght"
    private static let opticalSizeAxis = 0x6F70_737A // "opsz"

    /// Inter at a CSS pixel size and a CSS weight (400 regular, 500 medium, 600 semibold, 700 bold).
    /// The optical size follows the font size, as `font-optical-sizing: auto` does in the reference.
    public static func interCT(_ size: CGFloat, weight: CGFloat = 400) -> CTFont {
        _ = registered
        return cached("Inter Variable", size: size, weight: weight) {
            let attributes: [CFString: Any] = [
                kCTFontFamilyNameAttribute: "Inter Variable",
                kCTFontVariationAttribute: [weightAxis: weight, opticalSizeAxis: min(max(size, 14), 32)],
            ]
            return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
        }
    }

    public static func inter(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        Font(interCT(size, weight: weight))
    }

    /// "tw-font-mono": `--font-mono` of libs/components/src/theme.css starts with Menlo.
    public static func monoCT(_ size: CGFloat) -> CTFont {
        cached("Menlo", size: size) { CTFontCreateWithName("Menlo" as CFString, size, nil) }
    }

    /// Native shortcut glyphs share one font and baseline with their key names.
    public static var shortcut: Font {
        Font(NSFont.systemFont(ofSize: TextStyle.body.size, weight: .medium))
    }

    /// Native typography for independent AppKit permission windows.
    public static func nativeAppKit(_ size: CGFloat = TextStyle.body.size, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    public static func nativeMonospacedAppKit(_ size: CGFloat = TextStyle.xs.size) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// CSS text metrics: a font size, a line height and a weight. `isMonospaced` is "tw-font-mono".
public struct TextStyle: Sendable, Hashable {
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: CGFloat
    public let isMonospaced: Bool

    public init(size: CGFloat, lineHeight: CGFloat, weight: CGFloat = 400, isMonospaced: Bool = false) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.isMonospaced = isMonospaced
    }

    public func weight(_ weight: CGFloat) -> TextStyle {
        TextStyle(size: size, lineHeight: lineHeight, weight: weight, isMonospaced: isMonospaced)
    }

    public var monospaced: TextStyle {
        TextStyle(size: size, lineHeight: lineHeight, weight: weight, isMonospaced: true)
    }

    var font: CTFont {
        isMonospaced ? BWFont.monoCT(size) : BWFont.interCT(size, weight: weight)
    }

    /// The width of a text on one line in this style. A table needs it to size its columns
    /// by their content before it lays out a row.
    public func width(of text: String) -> CGFloat {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

private struct TextStyleModifier: ViewModifier {
    let style: TextStyle

    func body(content: Content) -> some View {
        let font = style.font
        let spacing = max(style.lineHeight - CTFontGetAscent(font) - CTFontGetDescent(font), 0)
        LineBox(lineHeight: style.lineHeight, spacing: spacing) {
            // One line of the same font, to learn how high SwiftUI makes a line.
            Text("Ág")
                .font(Font(font))
                .hidden()
                .accessibilityHidden(true)
            content
                .font(Font(font))
                .lineSpacing(spacing)
        }
    }
}

/// Gives text the box of CSS: every line is exactly `lineHeight` high and the glyphs sit in the
/// middle of it. SwiftUI's own line height depends on rounding, so it is measured, not computed.
/// The first subview is the measuring line; the others are the content, one under the other.
private struct LineBox: Layout {
    let lineHeight: CGFloat
    let spacing: CGFloat

    private func height(of subview: LayoutSubview, proposal: ProposedViewSize, line: CGFloat) -> CGSize {
        let size = subview.sizeThatFits(proposal)
        guard size.height > 0 else { return size }
        let lines = max(1, ((size.height + spacing) / (line + spacing)).rounded())
        return CGSize(width: size.width, height: lines * lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let probe = subviews.first else { return .zero }
        let line = probe.sizeThatFits(.unspecified).height
        var result = CGSize.zero
        for subview in subviews.dropFirst() {
            let size = height(of: subview, proposal: ProposedViewSize(width: proposal.width, height: nil), line: line)
            result.width = max(result.width, size.width)
            result.height += size.height
        }
        return result
    }

    /// The text baselines of the first content view, so that a row can align this text with others.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline, subviews.count >= 2 else { return nil }
        let line = subviews[0].sizeThatFits(.unspecified).height
        let width = ProposedViewSize(width: proposal.width, height: nil)
        let dimensions = subviews[1].dimensions(in: width)
        let box = height(of: subviews[1], proposal: width, line: line)
        return bounds.minY + (box.height - dimensions.height) / 2 + dimensions[guide]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let probe = subviews.first else { return }
        probe.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
        let line = probe.sizeThatFits(.unspecified).height
        var top = bounds.minY
        for subview in subviews.dropFirst() {
            // The same proposal as in sizeThatFits. The measured width, rounded to a pixel, can be a
            // fraction too narrow and would wrap the text.
            let width = ProposedViewSize(width: proposal.width, height: nil)
            let box = height(of: subview, proposal: width, line: line)
            subview.place(at: CGPoint(x: bounds.midX, y: top + box.height / 2), anchor: .center, proposal: width)
            top += box.height
        }
    }
}

public extension View {
    /// Text with the metrics of a CSS line box.
    func textStyle(_ style: TextStyle) -> some View {
        modifier(TextStyleModifier(style: style))
    }
}

/// A semantic interface icon backed by a native SF Symbol.
public struct BWIcon: Sendable, Hashable {
    public let systemName: String
    public let rotationDegrees: Double

    public init(systemName: String, rotationDegrees: Double = 0) {
        self.systemName = systemName
        self.rotationDegrees = rotationDegrees
    }
}

public extension EnvironmentValues {
    /// Center visible artwork for adjacent controls whose symbols have different baselines.
    @Entry var centersIconArtwork = false
}

/// Native symbol artwork in the existing square layout box.
public struct IconView: View {
    private let icon: BWIcon
    private let size: CGFloat
    @Environment(\.centersIconArtwork) private var centersArtwork

    public init(_ icon: BWIcon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Group {
            if centersArtwork {
                Image(systemName: icon.systemName)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: icon.systemName)
                    .font(.system(size: size * 0.9, weight: .regular))
            }
        }
            .symbolRenderingMode(.monochrome)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(icon.rotationDegrees))
            .accessibilityHidden(true)
    }
}
