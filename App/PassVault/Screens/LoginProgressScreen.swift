import DesignKit
import Engine
import SwiftUI

/// Covers the existing form without destroying its fields if authentication fails.
struct LoginProgressScreen: View {
    var phase: AuthenticationPhase

    private var label: String {
        switch phase {
        case .authenticating: BWText["authenticating"]
        case .syncing: BWText["sync"]
        case .loadingVault, .saving: BWText["loadingVault"]
        case .preparingPin: BWText["unlockWithPin"]
        }
    }

    var body: some View {
        VStack(spacing: Metric.space(5)) {
            Illustration(.gooseKey)
                .frame(width: Metric.space(24), height: Metric.space(24))
            Text(label)
                .textStyle(.h3)
                .foregroundStyle(.theme(.textMain))
            HStack(spacing: Metric.space(3)) {
                ProgressView().controlSize(.small)
                Text(BWText["loading"]).textStyle(.body)
                    .foregroundStyle(.theme(.textMuted))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.theme(.bgTertiary))
        .accessibilityElement(children: .combine)
    }
}
