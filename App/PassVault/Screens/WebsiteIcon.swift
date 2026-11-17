import AppKit
import DesignKit
import SwiftUI

/// The picture of a website: img "tw-rounded-md", 24 pixels in a list row ("tw-size-6") and 36 in
/// the item view. `placeholder` is shown until the server has answered, and when it has no picture.
struct WebsiteIcon<Placeholder: View>: View {
    let model: AppModel
    let host: String
    let size: CGFloat
    let placeholder: Placeholder
    @State private var image: NSImage?

    private struct Request: Hashable {
        let host: String
        let isAllowed: Bool
    }

    init(model: AppModel, host: String, size: CGFloat = Metric.space(6), @ViewBuilder placeholder: () -> Placeholder) {
        self.model = model
        self.host = host
        self.size = size
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 0.375 * Metric.rem))
            } else {
                placeholder
            }
        }
        // The setting "show website icons" can change while the picture is on screen.
        .task(id: Request(host: host, isAllowed: model.state.settings.showsWebsiteIcons)) {
            image = await model.websiteIcon(host: host).flatMap(NSImage.init(data:))
        }
        .accessibilityHidden(true)
    }
}
