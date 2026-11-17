import SwiftUI

/// `bit-toast`: libs/components/src/toast/toast.component.html. The app shows toasts at the top
/// right of the window, 12 pixels from the edges (the "toast-top-right" place of ngx-toastr).
public struct BWToast: View {
    public enum Variant: Sendable {
        case success, error, info, warning

        var icon: BWIcon {
            switch self {
            case .success: .checkCircle
            case .error: .error
            case .info: .infoCircle
            case .warning: .exclamationTriangle
            }
        }

        /// "tw-bg-success-100", "tw-bg-danger-100", "tw-bg-info-100", "tw-bg-warning-100"
        var background: ThemeColor {
            switch self {
            case .success: .success100
            case .error: .danger100
            case .info: .info100
            case .warning: .warning100
            }
        }
    }

    /// `--bit-toast-width`
    public static let width: CGFloat = 19 * Metric.rem

    private let variant: Variant
    private let title: String?
    private let message: String
    private let lifetime: Duration
    private let onClose: () -> Void
    @State private var progress: CGFloat = 1

    /// - Parameter lifetime: how long the bar under the text takes to run out.
    public init(variant: Variant, title: String? = nil, message: String, lifetime: Duration, onClose: @escaping () -> Void) {
        self.variant = variant
        self.title = title
        self.message = message
        self.lifetime = lifetime
        self.onClose = onClose
    }

    public var body: some View {
        let radius = Metric.containerCornerRadius
        VStack(alignment: .leading, spacing: 0) {
            // "tw-flex tw-items-center tw-gap-4 tw-px-2 tw-pb-1 tw-pt-2"
            HStack(alignment: .center, spacing: Metric.space(4)) {
                // i "bwi tw-text-xl tw-py-1.5 tw-px-2.5"
                IconView(variant.icon, size: 1.25 * Metric.rem)
                    .padding(.vertical, Metric.space(1.5))
                    .padding(.horizontal, Metric.space(2.5))
                VStack(alignment: .leading, spacing: 0) {
                    if let title {
                        // p "tw-font-medium tw-mb-0"
                        Text(title).textStyle(.body.weight(500))
                    }
                    // p bitTypography="body2" "tw-mb-2 last:tw-mb-0"
                    Text(message).textStyle(.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // "tw-ms-auto", bitIconButton="bwi-close" size="small"
                BWIconButton(.close, label: BWText["close"], size: .small, action: onClose)
            }
            .padding(.horizontal, Metric.space(2))
            .padding(.top, Metric.space(2))
            .padding(.bottom, Metric.space(1))
            // "tw-h-1 tw-w-full tw-bg-text-main/30", as wide as the time that is left.
            Rectangle()
                .fill(.theme(ThemeColor.textMain.opacity(0.3)))
                .frame(width: Self.width * progress, height: Metric.space(1))
        }
        .foregroundStyle(.theme(.textMain))
        .frame(width: Self.width, alignment: .leading)
        // "tw-rounded-md tw-overflow-hidden tw-shadow-lg" on the ground of the variant.
        .background(.theme(variant.background))
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 8)
        .onAppear {
            withAnimation(.linear(duration: Double(lifetime.components.seconds))) { progress = 0 }
        }
        .accessibilityElement(children: .combine)
    }
}
