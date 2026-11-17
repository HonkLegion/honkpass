import SwiftUI

/// The layout of the screens before the vault is open: log-in and lock.
/// Source: libs/components/src/anon-layout and landing-layout (header, hero, card, footer).
/// PassVault centres the form on a plain background (PLAN.md, M7 polish).
/// A short window scrolls instead of clipping the form.
public struct AnonLayout<HeaderActions: View, Content: View, Secondary: View, Footer: View>: View {
    private let illustration: Illustration.Name
    private let title: String
    private let subtitle: String?
    private let onHome: (() -> Void)?
    private let headerActions: HeaderActions
    private let content: Content
    private let secondary: Secondary
    private let footer: Footer

    /// - Parameter onHome: the logo is a link to the first screen; a click on it runs this.
    public init(illustration: Illustration.Name, title: String, subtitle: String? = nil, onHome: (() -> Void)? = nil,
                @ViewBuilder headerActions: () -> HeaderActions,
                @ViewBuilder content: () -> Content,
                @ViewBuilder secondary: () -> Secondary = { EmptyView() },
                @ViewBuilder footer: () -> Footer) {
        self.illustration = illustration
        self.title = title
        self.subtitle = subtitle
        self.onHome = onHome
        self.headerActions = headerActions()
        self.content = content()
        self.secondary = secondary()
        self.footer = footer()
    }

    public var body: some View {
        GeometryReader { area in
            BWScrollView {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: Metric.space(4))
                    main
                    Spacer(minLength: Metric.space(4))
                    // footer: "tw-bg-background-alt tw-text-center tw-px-5", "tw-pb-5 tw-pt-4 sm:tw-pt-6"
                    footer
                        .textStyle(.sm)
                        .foregroundStyle(.theme(.textMain))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Metric.space(5))
                        .padding(.top, Metric.space(6))
                        .padding(.bottom, Metric.space(5))
                }
                // The page is at least as high as the window: the footer stands at its bottom.
                .frame(minHeight: area.size.height)
            }
        }
        // "tw-bg-background-alt"
        .background(.theme(.bgTertiary))
    }

    /// header: "tw-flex tw-w-full tw-bg-background-alt tw-px-5"
    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            // logo link: "tw-py-5 sm:tw-w-[200px] sm:tw-self-start". PassVault shows its own name here.
            Button { onHome?() } label: {
                Wordmark().frame(width: 200, alignment: .leading)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(onHome != nil)
            .padding(.vertical, Metric.space(5))
            Spacer(minLength: 0)
            // "[&:has(*)]:tw-ms-auto [&:has(*)]:tw-py-5"
            headerActions.padding(.vertical, Metric.space(5))
        }
        .padding(.horizontal, Metric.space(5))
    }

    /// landing-content: "tw-flex tw-flex-col tw-flex-1 tw-items-center tw-bg-background-alt tw-p-5 tw-text-main" + "tw-pt-12",
    /// inner column "tw-flex tw-flex-col tw-w-full tw-max-w-md".
    private var main: some View {
        VStack(spacing: 0) {
            hero
            card
            secondary
                .textStyle(.body)
                .foregroundStyle(.theme(.textMain))
        }
        .frame(maxWidth: 28 * Metric.rem)
        .padding(.horizontal, Metric.space(5))
        .padding(.top, Metric.space(4))
        .padding(.bottom, Metric.space(5))
        .frame(maxWidth: .infinity)
    }

    /// landing-hero: "tw-mb-4 sm:tw-mb-6", "tw-text-center tw-mx-auto".
    private var hero: some View {
        VStack(spacing: 0) {
            // "tw-size-20 sm:tw-size-24 [&_svg]:tw-w-full [&_svg]:tw-max-w-24 tw-mx-auto tw-content-center"
            Illustration(illustration)
                .frame(width: Metric.space(24), height: Metric.space(24))
            // h1 bitTypography="h1": "tw-mt-2", "!tw-text-3xl tw-text-main tw-font-medium", "tw-mb-2"
            // Without a subtitle the bottom margin of the title collapses into the margin of the hero.
            Text(title)
                .textStyle(.h1)
                .padding(.top, Metric.space(2))
                .padding(.bottom, subtitle == nil ? 0 : Metric.space(2))
            if let subtitle {
                // "tw-text-sm tw-mt-4 sm:tw-mt-0 sm:tw-text-base"
                Text(subtitle).textStyle(.base)
            }
        }
        .foregroundStyle(.theme(.textMain))
        .multilineTextAlignment(.center)
        .padding(.bottom, Metric.space(6))
    }

    /// landing-card on bit-base-card: "!tw-rounded-2xl sm:tw-mb-10 tw-w-full sm:tw-bg-background sm:tw-border
    /// sm:tw-border-solid sm:tw-border-secondary-100 sm:tw-shadow sm:tw-p-8", "tw-text-fg-heading".
    private var card: some View {
        content
            .foregroundStyle(.theme(.fgHeading))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metric.space(8))
            .padding(1)
            // "tw-shadow": 0 1px 3px 0 rgb(0 0 0 / .1), 0 1px 2px -1px rgb(0 0 0 / .1). Only the card casts it.
            .background(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).fill(.theme(.bgPrimary))
                .shadow(color: .black.opacity(0.1), radius: 1.5, x: 0, y: 1))
            .overlay(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).strokeBorder(.theme(.secondary100), lineWidth: 1))
            .padding(.bottom, Metric.space(10))
    }

}

/// The HonkPass text wordmark in authentication headers.
struct Wordmark: View {
    var colour = ThemeColor.marketingLogo
    var width: CGFloat = 200

    var body: some View {
        Text(BWText.settings.productName)
            .font(BWFont.inter(26 * width / 200, weight: 700))
            .foregroundStyle(.theme(colour))
            .frame(height: width * 45 / 290, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }
}
