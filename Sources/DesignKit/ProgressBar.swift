import SwiftUI

/// `bit-progress-bar`, variant primary, with the hint at its start:
/// libs/components/src/progress/progress-bar.component.html.
public struct BWProgressBar: View {
    private let value: Int

    /// - Parameter value: the per cent that is done.
    public init(value: Int) {
        self.value = value
    }

    /// `clampedValue`: the value between 0 and 100.
    public static func clamped(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    /// `defaultStartText`: "$PERCENT$% complete".
    public static func startText(_ value: Int) -> String {
        BWText["percentageCompleted", String(clamped(value))]
    }

    public var body: some View {
        let percent = Self.clamped(value)
        let radius = 0.25 * Metric.rem
        // "tw-flex tw-flex-col". The label is "tw-sr-only" without a label of the caller, and
        // takes no room.
        VStack(alignment: .leading, spacing: 0) {
            // "tw-overflow-hidden tw-rounded tw-bg-secondary-100 tw-h-2 tw-my-1"
            GeometryReader { track in
                // "tw-transition-all tw-h-2 tw-rounded tw-bg-primary-600", as wide as the per cent
                RoundedRectangle(cornerRadius: radius)
                    .fill(.theme(.primary600))
                    .frame(width: track.size.width * CGFloat(percent) / 100)
                    .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: percent)
            }
            .frame(height: Metric.space(2))
            .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.secondary100)))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .padding(.vertical, Metric.space(1))
            // "tw-flex tw-text-fg-body" around a bit-hint, "tw-mt-1 tw-text-xs tw-text-muted"
            BWHint(Self.startText(percent))
                .padding(.top, Metric.space(1))
        }
        // role="progressbar", named "Progress bar" and a number of its own where no label names it
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BWText["progressBar"])
        .accessibilityValue(Self.startText(percent))
    }
}
