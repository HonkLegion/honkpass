import SwiftUI

/// `bit-simple-dialog` with the content of the configurable one: a question with an icon, a title,
/// a text and the buttons under each other. Source: libs/components/src/dialog/simple-dialog/
/// simple-dialog.component.html and simple-configurable-dialog. Put it over the whole window content.
public struct BWSimpleDialog: View {
    /// `SimpleDialogType`: it chooses the icon and its colour.
    public enum Kind: Sendable {
        /// "bwi-info-circle" in "tw-text-info"
        case info
        /// "bwi-exclamation-triangle" in "tw-text-warning"
        case warning
        /// "bwi-error" in "tw-text-danger", and the accept button is a danger button
        case danger

        var icon: BWIcon {
            switch self {
            case .info: .infoCircle
            case .warning: .exclamationTriangle
            case .danger: .error
            }
        }

        var colour: ThemeColor {
            switch self {
            case .info: .info600
            case .warning: .warning600
            case .danger: .danger600
            }
        }
    }

    private let kind: Kind
    private let title: String
    private let text: String
    private let acceptTitle: String
    private let cancelTitle: String
    private let hasCancel: Bool
    private let onAnswer: (Bool) -> Void

    /// - Parameters:
    ///   - acceptTitle: the reference says "yes" unless the dialog names its own.
    ///   - cancelTitle: "no" beside "yes", and "cancel" beside an own accept text.
    ///   - hasCancel: false for a dialog that only tells: it has the accept button alone (`cancelButtonText: null`).
    ///   - onAnswer: true for the accept button; false for the other button, a click beside the dialog and Escape.
    public init(kind: Kind, title: String, text: String, acceptTitle: String? = nil, cancelTitle: String? = nil,
                hasCancel: Bool = true, onAnswer: @escaping (Bool) -> Void) {
        self.hasCancel = hasCancel
        self.kind = kind
        self.title = title
        self.text = text
        self.acceptTitle = acceptTitle ?? BWText["yes"]
        self.cancelTitle = cancelTitle ?? BWText[acceptTitle == nil ? "no" : "cancel"]
        self.onAnswer = onAnswer
    }

    public var body: some View {
        GeometryReader { window in
            ZStack {
                // backdrop: "tw-fixed tw-bg-bg-overlay tw-inset-0"
                Rectangle()
                    .fill(.theme(.bgOverlay))
                    .onTapGesture { onAnswer(false) }
                panel
                    // "tw-w-96 tw-max-w-90vw", "tw-my-4"
                    .frame(width: min(24 * Metric.rem, 0.9 * window.size.width))
                    .padding(.vertical, Metric.space(4))
            }
            .frame(width: window.size.width, height: window.size.height)
        }
        .onExitCommand { onAnswer(false) }
        .bwEscapeLayer { onAnswer(false) }
    }

    /// "tw-pb-6 tw-pt-8 tw-flex tw-flex-col tw-overflow-hidden tw-rounded-3xl tw-border tw-border-solid
    /// tw-border-secondary-100 tw-shadow-lg tw-bg-text-contrast tw-text-main"
    private var panel: some View {
        let radius = Metric.containerCornerRadius
        return VStack(spacing: 0) {
            // "tw-flex tw-px-6 tw-flex-col tw-items-center tw-gap-2 tw-text-center"
            VStack(spacing: Metric.space(2)) {
                // i "bwi tw-text-3xl": 1.875 rem on a line of 150 %.
                IconView(kind.icon, size: 1.875 * Metric.rem)
                    .foregroundStyle(.theme(kind.colour))
                    .frame(height: 1.5 * 1.875 * Metric.rem)
                // h1 bitTypography="h3" noMargin, "tw-w-full tw-text-main tw-break-words"
                Text(title)
                    .textStyle(.h3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            // "tw-px-6 tw-mb-6 tw-text-center tw-text-base tw-break-words"
            Text(text)
                .textStyle(.base)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Metric.space(6))
            // "tw-flex tw-flex-col tw-gap-2 tw-px-6"
            VStack(spacing: Metric.space(2)) {
                BWButton(acceptTitle, kind: kind == .danger ? .danger : .primary) { onAnswer(true) }
                if hasCancel { BWButton(cancelTitle) { onAnswer(false) } }
            }
        }
        .padding(.horizontal, Metric.space(6))
        .padding(.top, Metric.space(8))
        .padding(.bottom, Metric.space(6))
        .foregroundStyle(.theme(.textMain))
        .padding(1)
        // "tw-shadow-lg": 0 10px 15px -3px rgb(0 0 0 / .1), 0 4px 6px -4px rgb(0 0 0 / .1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.textContrast))
            .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 8))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.secondary100), lineWidth: 1))
    }
}
