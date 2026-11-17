import AppKit
import SwiftUI

/// One colour of the Bitwarden theme with its light and dark value, as 0xRRGGBBAA in sRGB.
/// The values are in Generated/Colors.generated.swift. Views use these and no literal colours.
public struct ThemeColor: Sendable, Hashable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public var color: Color { Color(nsColor: nsColor) }

    public var nsColor: NSColor {
        let light = light, dark = dark
        return NSColor(name: nil) { appearance in
            Self.make(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }

    /// The same colour with its alpha multiplied, like Tailwind's `/50` suffix.
    public func opacity(_ factor: Double) -> ThemeColor {
        func scaled(_ value: UInt32) -> UInt32 {
            let alpha = UInt32((Double(value & 0xFF) * factor).rounded())
            return (value & 0xFFFF_FF00) | min(alpha, 255)
        }
        return ThemeColor(light: scaled(light), dark: scaled(dark))
    }

    public static let clear = ThemeColor(light: 0, dark: 0)

    private static func make(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 24) & 0xFF) / 255, green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
    }
}

public extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.theme(.fgHeading))`
    static func theme(_ color: ThemeColor) -> Color { color.color }
}

/// System semantic colors for native surfaces that manage their own material and contrast.
public enum NativeColor {
    public static var label: NSColor { .labelColor }
    public static var secondaryLabel: NSColor { .secondaryLabelColor }
    public static var danger: NSColor { .systemRed }
    public static var accent: NSColor { .controlAccentColor }
}
