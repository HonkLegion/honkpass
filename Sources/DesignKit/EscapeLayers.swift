import SwiftUI

/// The open layers that Escape closes: dialogs, and the menus, lists and popovers over them.
///
/// In the reference the `OverlayKeyboardDispatcher` of the CDK gives a key to the overlay on
/// top, wherever the keyboard is. SwiftUI gives Escape (`onExitCommand`) to a view only while
/// the keyboard is in it, and a click beside a text field takes the keyboard away. A window
/// asks here when no view took the key: the layer that opened last closes.
@MainActor
public enum BWEscapeLayers {
    final class Layer {
        var close: () -> Void = {}
    }

    /// A layer is held by its view. One whose view went away without saying so is not there.
    private struct Entry {
        weak var layer: Layer?
    }

    private static var open: [Entry] = []

    static func add(_ layer: Layer) {
        guard !open.contains(where: { $0.layer === layer }) else { return }
        open.append(Entry(layer: layer))
    }

    static func remove(_ layer: Layer) {
        open.removeAll { $0.layer === layer }
    }

    /// Closes the layer on top. False when no layer is open: the key is not for a layer.
    public static func closeTop() -> Bool {
        open.removeAll { $0.layer == nil }
        guard let layer = open.last?.layer else { return false }
        layer.close()
        return true
    }
}

private struct EscapeLayer: ViewModifier {
    let close: () -> Void
    @State private var layer = BWEscapeLayers.Layer()

    func body(content: Content) -> some View {
        // The layer closes with what the view says now, not with what it said when it opened.
        layer.close = close
        return content
            .onAppear { BWEscapeLayers.add(layer) }
            .onDisappear { BWEscapeLayers.remove(layer) }
    }
}

extension View {
    /// While this view is there, it is a layer that Escape closes when no view took the key.
    func bwEscapeLayer(close: @escaping () -> Void) -> some View {
        modifier(EscapeLayer(close: close))
    }
}
