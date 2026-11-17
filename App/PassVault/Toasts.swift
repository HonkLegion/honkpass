import DesignKit
import Observation
import SwiftUI

/// The toasts of the window: short notes at its top right corner that leave by themselves.
/// toast.module.ts of the reference: five seconds and one more for every 120 words, five at most.
@MainActor @Observable
final class ToastCenter {
    struct Toast: Identifiable {
        let id = UUID()
        let variant: BWToast.Variant
        let title: String?
        let message: String
        let lifetime: Duration
    }

    private(set) var toasts: [Toast] = []

    func show(_ variant: BWToast.Variant, title: String? = nil, message: String) {
        let words = message.split(whereSeparator: \.isWhitespace).count
        let toast = Toast(variant: variant, title: title, message: message, lifetime: .seconds(5 + words / 120))
        toasts.append(toast)
        // `maxOpened` with `autoDismiss`: the oldest one makes room.
        if toasts.count > 5 { toasts.removeFirst(toasts.count - 5) }
        Task { [weak self, id = toast.id, lifetime = toast.lifetime] in
            try? await Task.sleep(for: lifetime)
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    func dismissAll() {
        toasts = []
    }
}

/// The place of the toasts: "toast-top-right", 12 pixels from the top and the right edge, the
/// newest at the top, "tw-mb-1" under each.
struct ToastStack: View {
    let center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: Metric.space(1)) {
            ForEach(center.toasts.reversed()) { toast in
                BWToast(variant: toast.variant, title: toast.title, message: toast.message, lifetime: toast.lifetime) {
                    center.dismiss(toast.id)
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.2), value: center.toasts.map(\.id))
    }
}
