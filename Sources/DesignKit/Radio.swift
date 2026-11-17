import SwiftUI

/// `bit-radio-button` in a block `bit-radio-group`: libs/components/src/radio-button. The input is
/// "tw-w-6 tw-h-6 tw-rounded-full" around a circle of "before:tw-size-4" with the border
/// "before:tw-border-border-strong" on "before:tw-bg-bg-tertiary"; the chosen one is filled in the
/// brand colour with a dot of "after:tw-size-2" in its middle. No reference picture yet.
public struct BWRadio: View {
    private let title: String
    private let isOn: Bool
    private let action: () -> Void
    @State private var isHovered = false

    public init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        // bit-form-control: "tw-items-start tw-gap-2 tw-inline-flex", the label "tw-leading-5 tw-font-medium".
        HStack(alignment: .center, spacing: Metric.space(2)) {
            ZStack {
                Circle().fill(.theme(isHovered ? .bgHover : .clear))
                Circle().fill(.theme(isOn ? .bgBrand : .bgTertiary))
                    .frame(width: Metric.space(4), height: Metric.space(4))
                Circle().strokeBorder(.theme(isOn ? .borderBrand : .borderStrong), lineWidth: 1)
                    .frame(width: Metric.space(4), height: Metric.space(4))
                if isOn {
                    Circle().fill(.theme(.fgContrast)).frame(width: Metric.space(2), height: Metric.space(2))
                }
            }
            .frame(width: Metric.space(6), height: Metric.space(6))
            .padding(.leading, -1)
            Text(title)
                .textStyle(.smTight.weight(500))
                .foregroundStyle(.theme(.fgHeading))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
