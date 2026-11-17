import SwiftUI

/// Sizes of the reference. Bitwarden desktop sets the root font size to 14 pixels
/// (apps/desktop/src/scss/variables.scss), so one rem is 14 points here, not 16.
public enum Metric {
    public static let rem: CGFloat = 14

    /// Tailwind's spacing scale: `tw-p-4` is `space(4)`, a quarter of a rem for each unit.
    public static func space(_ units: CGFloat) -> CGFloat {
        units * rem / 4
    }

    /// HonkPass's top strip adds two points above and below the original controls.
    public static let windowStripHeight: CGFloat = 44

    /// PassVault's window frame and aligned list/detail headers (PLAN.md, M7 polish).
    public static let panelHeaderHeight: CGFloat = 64
    public static let headerFadeHeight: CGFloat = 12
    public static let windowSearchWidth: CGFloat = 420
    public static let sshPromptWidth: CGFloat = 420
    public static let sshPromptMinHeight: CGFloat = 240
    public static let sshPromptInset: CGFloat = 24
    public static let sshPromptCornerRadius: CGFloat = 24
    public static let quickAccessWidth: CGFloat = 760
    public static let quickAccessHeight: CGFloat = 440
    public static let quickAccessCornerRadius: CGFloat = 26
    public static let quickAccessRowRadius: CGFloat = 14
    public static let quickAccessInset: CGFloat = 24
    public static let quickAccessSearchHeight: CGFloat = 76
    public static let quickAccessRowHeight: CGFloat = 60
    public static let quickAccessChromeHeight: CGFloat = 168
    public static let quickAccessLockedHeight: CGFloat = 360
    public static let quickAccessQuestionHeight: CGFloat = 600
    public static let containerCornerRadius: CGFloat = 0.75 * rem
    public static let panelRadius: CGFloat = containerCornerRadius
    public static let windowInset: CGFloat = 3
    public static let windowButtonsWidth: CGFloat = 86
    public static let statusItemSymbolSize: CGFloat = 18
    public static let shortcutFieldWidth: CGFloat = 126
    /// Variant B shares the container's corners across controls and fields.
    public static let fieldCornerRadius: CGFloat = containerCornerRadius
    public static let vaultActionIconSize: CGFloat = space(4.5)
    public static let vaultActionHoverSize: CGFloat = space(8)
    public static let navigationChevronSize: CGFloat = space(3)
}

/// Actions share the container radius unless a capsule is explicitly requested.
public struct BWControlShape: InsettableShape {
    var isCapsule = false
    private var insetAmount: CGFloat = 0

    public init(isCapsule: Bool = false) { self.isCapsule = isCapsule }

    public func path(in rect: CGRect) -> Path {
        if isCapsule {
            Capsule().inset(by: insetAmount).path(in: rect)
        } else {
            RoundedRectangle(cornerRadius: Metric.containerCornerRadius).inset(by: insetAmount).path(in: rect)
        }
    }

    public func inset(by amount: CGFloat) -> Self {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// The font sizes of libs/components/tailwind.config.base.js, with their line heights.
public extension TextStyle {
    /// `tw-text-3xl`, medium: bitTypography h1.
    static let h1 = TextStyle(size: 1.875 * Metric.rem, lineHeight: 1.875 * Metric.rem * 1.5, weight: 500)
    /// `tw-text-base`: bitTypography body1.
    static let base = TextStyle(size: Metric.rem, lineHeight: Metric.rem * 1.5)
    /// `tw-text-sm`: bitTypography body2.
    static let sm = TextStyle(size: 0.875 * Metric.rem, lineHeight: 0.875 * Metric.rem * 1.5)
    /// `tw-text-sm/5`: labels, inputs and buttons.
    static let smTight = TextStyle(size: 0.875 * Metric.rem, lineHeight: 1.25 * Metric.rem)
    /// `tw-text-xs`
    static let xs = TextStyle(size: 0.75 * Metric.rem, lineHeight: 0.75 * Metric.rem * 1.5)
    /// `tw-text-lg`, medium: bitTypography h4.
    static let h4 = TextStyle(size: 1.125 * Metric.rem, lineHeight: 1.125 * Metric.rem * 1.5, weight: 500)
    /// `tw-text-xl`, medium: bitTypography h3.
    static let h3 = TextStyle(size: 1.25 * Metric.rem, lineHeight: 1.25 * Metric.rem * 1.5, weight: 500)
    /// Text without a size class: the body style of the desktop app, 14 pixels with line height 1.42857.
    /// The desktop styles give it to every input, select, textarea and button as well
    /// (apps/desktop/src/scss/base.scss).
    static let body = TextStyle(size: 14, lineHeight: 20)
}
