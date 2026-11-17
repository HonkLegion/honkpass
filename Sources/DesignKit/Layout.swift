import CoreGraphics

/// The three columns of `bit-layout`: the side navigation, the main content and the drawer
/// (libs/components/src/layout/layout.component.ts). The main content keeps a least width;
/// what does not fit beside it gives way: first the open navigation, which closes to its
/// rail, then the drawer, which gets narrower and at last lies over the content.
public struct BWLayout: Equatable, Sendable {
    /// `MAIN_CONTENT_MIN_WIDTH_REM`
    public static let mainMinWidth = 24 * Metric.rem
    /// `drawerSizeToWidthRem.small`: the least width of a drawer beside the content.
    public static let drawerMinWidth = 24 * Metric.rem
    /// `drawerSizeToWidthRem.large`: what the panel of an item asks for.
    public static let drawerMaxWidth = 42 * Metric.rem

    /// What fits beside the least main content in a window: the decisions of `update()`.
    public struct Fit: Equatable, Sendable {
        /// The open navigation has room for a column of its own.
        public let navigationPushes: Bool
        /// The rail of the closed navigation has room for a column of its own.
        public let railPushes: Bool
        /// The drawer has room beside the content, at its full width or narrower.
        public let drawerPushes: Bool

        /// - Parameters:
        ///   - navigation: the width of the open navigation.
        ///   - drawer: the width the drawer asks for; 0 without a drawer.
        public init(window: CGFloat, navigation: CGFloat, drawer: CGFloat) {
            let rail = SideNavigationSize.rail
            let main = BWLayout.mainMinWidth
            let least = BWLayout.drawerMinWidth
            let hasDrawer = drawer > 0
            let drawerWithNavigation = hasDrawer && window - navigation - drawer >= main
            let drawerWithRail = hasDrawer && window - rail - drawer >= main
            let leastDrawerWithNavigation = hasDrawer && window - navigation - least >= main
            let leastDrawerWithRail = hasDrawer && window - rail - least >= main
            drawerPushes = drawerWithNavigation || drawerWithRail || leastDrawerWithNavigation || leastDrawerWithRail
            // With a drawer the full navigation yields first; without one it needs its own room.
            navigationPushes = drawerPushes ? drawerWithNavigation || leastDrawerWithNavigation
                : window - navigation >= main && !hasDrawer
            let drawerNow = drawerPushes ? min(drawer, max(0, window - rail - main)) : 0
            railPushes = window - rail - drawerNow >= main
        }
    }

    /// The width of the first column: the navigation, its rail, or nothing.
    public let navigation: CGFloat
    public let main: CGFloat
    public let drawer: CGFloat
    /// The open navigation has no column of its own and lies over the content; its column
    /// then holds the place of the rail.
    public let navigationOverlays: Bool

    /// `gridTemplateColumns`: the columns for a navigation in the state `size`, which
    /// `SideNavigationSize.fit` keeps, and a drawer that asks for `drawer` (0 without one).
    public init(window: CGFloat, size: SideNavigationSize, drawer: CGFloat) {
        let fit = Fit(window: window, navigation: size.width, drawer: drawer)
        navigationOverlays = size.isOpen && !size.isPushMode
        if !(size.isPushMode || fit.railPushes) {
            navigation = 0
        } else if navigationOverlays {
            navigation = SideNavigationSize.rail
        } else {
            navigation = min(size.displayWidth, window)
        }
        let room = max(window - navigation, 0)
        if drawer <= 0 {
            self.drawer = 0
            main = room
        } else if fit.drawerPushes {
            // "minmax(0px, declared)" beside "minmax(least main, 1fr)": the content is served first.
            self.drawer = min(drawer, max(room - Self.mainMinWidth, 0))
            main = room - self.drawer
        } else {
            // The drawer takes the row, and the content has no column.
            self.drawer = room
            main = 0
        }
    }
}
