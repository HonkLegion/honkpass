import AppKit
import DesignKit
import Engine
import SwiftUI
import VaultModel

/// The window strip holds native window controls, the navigation toggle and the current
/// page's New menu. Its empty surface supports native window dragging.
struct WindowTopBar: View {
    let model: AppModel
    @Bindable var navigation: VaultNavigation

    @State private var isFullScreen = false

    var body: some View {
        Group {
            if model.state.session.isUnlocked {
                HStack(spacing: 0) {
                    SidebarToggleButton(label: BWText["toggleSideNavigation"]) { navigation.sideNavigation.toggle() }
                        .padding(.leading, isFullScreen ? Metric.space(3) : Metric.windowButtonsWidth)
                        .padding(.trailing, Metric.space(3))
                    Spacer(minLength: 0)
                    newButton
                        .padding(.horizontal, Metric.space(3))
                }
                .background { WindowDragRegion() }
            } else {
                WindowDragRegion()
                    .padding(.leading, isFullScreen ? 0 : Metric.windowButtonsWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metric.windowStripHeight)
        .background(.theme(model.state.session.isUnlocked ? .navBgPrimary : .bgTertiary))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if notification.object is MainWindow { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if notification.object is MainWindow { isFullScreen = false }
        }
    }

    /// vault-new-cipher-menu and tools-new-send-dropdown-v2: "add" with the menu of the item
    /// types and "folder", or "create" with the two types of a Send.
    @ViewBuilder private var newButton: some View {
        if navigation.page == .sends {
            NavIconButton(.plus, label: BWText["create"]) {
                navigation.isNewSendMenuOpen = true
            }
            .bwMenu(isOpen: $navigation.isNewSendMenuOpen) {
                let actions = SendActions(model: model, navigation: navigation)
                return [
                    BWMenuItem(BWText["sendTypeText"], icon: .fileText, iconPlace: .startSlot) { actions.add(.text) },
                    BWMenuItem(BWText["sendTypeFile"], icon: .file, iconPlace: .startSlot) { actions.add(.file) },
                ]
            }
        } else {
            NavIconButton(.plus, label: BWText["add"]) {
                navigation.isNewMenuOpen = true
            }
            .bwMenu(isOpen: $navigation.isNewMenuOpen) { newMenuItems }
        }
    }

    private var newMenuItems: [BWMenuItem] {
        [
            newItem("typeLogin", .login), newItem("typeCard", .card), newItem("typeIdentity", .identity),
            newItem("typeNote", .secureNote),
            newItem("typeSshKey", .sshKey),
            .divider,
            BWMenuItem(BWText["folder"], icon: .folder, iconPlace: .startSlot) { navigation.folderDialog = .add },
        ]
    }

    private func newItem(_ key: String, _ type: ItemType) -> BWMenuItem {
        BWMenuItem(BWText[key], icon: ItemRowIcon.icon(for: type), iconPlace: .startSlot) {
            ItemActions(model: model, navigation: navigation).add(type)
        }
    }
}

/// Only the empty strip receives mouse events. Buttons and modal overlays keep their own events.
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    private var frameBeforeFill: NSRect?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { window?.performDrag(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        performDoubleClickAction(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }

    func performDoubleClickAction(_ action: String?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "Fill":
            guard let screen = window.screen else { return }
            if window.frame == screen.visibleFrame, let previous = frameBeforeFill {
                window.setFrame(previous, display: true, animate: true)
                frameBeforeFill = nil
            } else {
                frameBeforeFill = window.frame
                window.setFrame(screen.visibleFrame, display: true, animate: true)
            }
        case nil, "Maximize": window.performZoom(nil)
        default: break
        }
    }
}
