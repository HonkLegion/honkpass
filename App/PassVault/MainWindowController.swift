import AppKit
import DesignKit
import SwiftUI

/// The window of the app. A key that no view took comes here: Escape then closes the dialog,
/// menu or list on top, as in the reference, where a dialog closes wherever the keyboard is.
final class MainWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        // 53 is Escape.
        if event.keyCode == 53, BWEscapeLayers.closeTop() { return }
        super.keyDown(with: event)
    }
}

/// Keeps the window at its smallest size or larger. `contentMinSize` alone does not hold:
/// the hosting controller of SwiftUI sets it back to nothing once the window shows, as a
/// trial outside the app showed, and the window could then be made as small as its buttons.
private final class SmallestSize: NSObject, NSWindowDelegate {
    /// "minWidth: 600, minHeight: 500" of apps/desktop/src/main/window.main.ts.
    static let content = NSSize(width: 600, height: 500)

    static func frameSize(of window: NSWindow) -> NSSize {
        window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let smallest = Self.frameSize(of: sender)
        return NSSize(width: max(frameSize.width, smallest.width), height: max(frameSize.height, smallest.height))
    }

    /// Keep native window buttons on the same centre line as the SwiftUI controls.
    static func alignWindowButtons(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.minX,
                y: bar.bounds.height - Metric.windowStripHeight / 2 - button.frame.height / 2))
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { Self.alignWindowButtons(window) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow { Self.alignWindowButtons(window) }
    }
}

/// The main window. It can be closed and shown again at any time; the engine does not notice.
///
/// The content fills the whole window, as in the reference, and draws the strip at the top
/// itself. The title bar is transparent and holds only the window buttons.
@MainActor
final class MainWindowController {
    let window: NSWindow
    private let smallestSize = SmallestSize()

    /// - Parameters:
    ///   - size: an explicit size, for a comparison with a reference picture.
    ///   - remembersFrame: the window comes back where the user left it. A test or picture
    ///     run has its own size and leaves the remembered frame of the user alone.
    init(model: AppModel, flow: LogInFlow, navigation: VaultNavigation, preferences: AppPreferences, size: NSSize?,
         remembersFrame: Bool) {
        let content = NSHostingController(rootView: RootView(model: model, flow: flow, navigation: navigation,
                                                             preferences: preferences))
        content.sizingOptions = []
        let requestedSize = size
        let size = size ?? NSSize(width: 1272, height: 828)
        window = MainWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isRestorable = false
        window.title = BWText.settings.productName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setContentSize(size)
        window.contentMinSize = SmallestSize.content
        window.delegate = smallestSize
        window.center()
        if remembersFrame { window.setFrameAutosaveName("PassVaultMainWindow") }
        // A frame that was remembered while the smallest size did not hold is made large enough.
        let smallest = SmallestSize.frameSize(of: window)
        if window.frame.width < smallest.width || window.frame.height < smallest.height {
            let grown = NSSize(width: max(window.frame.width, smallest.width), height: max(window.frame.height, smallest.height))
            // The top left corner stays where it is.
            let origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - grown.height)
            window.setFrame(NSRect(origin: origin, size: grown), display: false)
        }
        // An explicit size (a comparison with a reference picture) wins over the remembered frame.
        if let requestedSize {
            window.setFrame(NSRect(origin: window.frame.origin, size: requestedSize), display: false)
        }
        releaseFocusOnClicks()
    }

    /// A click beside a text field takes the keyboard from it, as on a page of the reference.
    /// AppKit alone leaves the cursor in the field until another control takes the keyboard.
    /// A click into a text keeps the keyboard, or moves it there.
    private func releaseFocusOnClicks() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, let content = window.contentView else { return event }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            let hit = content.hitTest(point)
            if !(hit is NSText || hit is NSTextField) { window.makeFirstResponder(nil) }
            return event
        }
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        // Every entry point restores the Dock and application menu before activating the window.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        SmallestSize.alignWindowButtons(window)
        NSApp.activate()
    }

    func close() {
        window.performClose(nil)
    }
}
