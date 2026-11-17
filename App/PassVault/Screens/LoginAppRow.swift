import AppKit
import DesignKit
import EngineLive
import SwiftUI
import VaultModel

/// One app of a login, in the section "app" of the item view and of the item form: the
/// picture and the name of the app as the system has them for an app that is installed, and
/// its address below. An app the system does not know is shown by its bundle identifier.
/// PassVault's own: the reference has no such row (PLAN.md, "Differences from the reference").
struct LoginAppRow<Suffix: View>: View {
    let app: AppAddress
    let suffix: Suffix
    @State private var installed: Installed?

    private struct Installed {
        let name: String
        let icon: NSImage
    }

    /// - Parameter suffix: `BWIconButton`s of size small at the end of the row.
    init(_ app: AppAddress, @ViewBuilder suffix: () -> Suffix) {
        self.app = app
        self.suffix = suffix()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Metric.space(3)) {
            Group {
                if let icon = installed?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    IconView(.desktop, size: TextStyle.body.size * 4 / 3)
                        .foregroundStyle(.theme(.textMuted))
                }
            }
            .frame(width: Metric.space(6), height: Metric.space(6))
            .background {
                if installed != nil {
                    RoundedRectangle(cornerRadius: Metric.containerCornerRadius)
                        .fill(.theme(.bgQuaternary))
                        .padding(-Metric.space(1))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(installed?.name ?? app.bundleID)
                    .lineLimit(1)
                    .textStyle(.body)
                    .foregroundStyle(.theme(.fgHeading))
                Text(app.address)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textStyle(.xs)
                    .foregroundStyle(.theme(.textMuted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) { suffix }
        }
        .frame(minHeight: Metric.space(10))
        .accessibilityElement(children: .contain)
        .task(id: app) {
            installed = InstalledApps.location(of: app).map { location in
                Installed(name: FileManager.default.displayName(atPath: location.path).replacingOccurrences(of: ".app", with: ""),
                          icon: NSWorkspace.shared.icon(forFile: location.path))
            }
        }
    }
}
