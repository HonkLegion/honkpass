import CoreGraphics
@testable import DesignKit
import Testing

/// The three columns of the window: what gives way to the least main content, and when.
struct LayoutTests {
    private let rem = Metric.rem
    private let panel = BWLayout.drawerMaxWidth

    private func columns(_ window: CGFloat, _ size: SideNavigationSize, drawer: CGFloat = 0) -> [CGFloat] {
        let layout = BWLayout(window: window, size: size, drawer: drawer)
        return [layout.navigation, layout.main, layout.drawer]
    }

    @Test func aWindowWithRoomHasTheNavigationTheContentAndTheWholePanel() {
        var size = SideNavigationSize()
        size.fit(window: 1272, drawer: 0)
        #expect(size.isOpen && columns(1272, size) == [18.5 * rem, 1272 - 18.5 * rem, 0])
        // The reference pictures of an open item: the navigation, 425 pixels of list, the panel.
        size.fit(window: 1272, drawer: panel)
        #expect(size.isOpen && columns(1272, size, drawer: panel) == [18.5 * rem, 1272 - 18.5 * rem - 42 * rem, 42 * rem])
    }

    @Test func theSmallestWindowKeepsANavigationOfTheStandardWidth() {
        var size = SideNavigationSize()
        size.fit(window: 600, drawer: 0)
        #expect(size.isOpen && size.isPushMode)
        #expect(columns(600, size) == [18.5 * rem, 600 - 18.5 * rem, 0])
    }

    @Test func aNavigationTooWideForTheWindowClosesToItsRailAndComesBack() {
        var size = SideNavigationSize(saved: 22 * rem)
        size.fit(window: 900, drawer: 0)
        #expect(size.isOpen)
        // 600 - 308 leaves less than the 336 pixels of the main content.
        size.fit(window: 600, drawer: 0)
        #expect(!size.isOpen && !size.isPushMode && size.preference == nil)
        #expect(columns(600, size) == [4 * rem, 600 - 4 * rem, 0])
        size.fit(window: 900, drawer: 0)
        #expect(size.isOpen && size.displayWidth == 22 * rem)
    }

    @Test func aNavigationThatTheUserClosedStaysClosedInAWiderWindow() {
        var size = SideNavigationSize(saved: 22 * rem)
        size.fit(window: 900, drawer: 0)
        size.toggle()
        size.fit(window: 600, drawer: 0)
        size.fit(window: 1272, drawer: 0)
        #expect(!size.isOpen && size.preference == .closed)
        size.toggle()
        #expect(size.isOpen && size.preference == .open)
    }

    @Test func thePanelOfAnItemTakesTheRoomOfTheNavigationFirst() {
        var size = SideNavigationSize()
        size.fit(window: 900, drawer: 0)
        // 900 - 259 - 336 leaves 305: the navigation yields, and the panel gets what the rail
        // and the least content leave.
        size.fit(window: 900, drawer: panel)
        #expect(!size.isOpen)
        #expect(columns(900, size, drawer: panel) == [4 * rem, 24 * rem, 900 - 28 * rem])
        // The panel closes: the navigation is back.
        size.fit(window: 900, drawer: 0)
        #expect(size.isOpen && columns(900, size) == [18.5 * rem, 900 - 18.5 * rem, 0])
    }

    @Test func inANarrowWindowThePanelLiesOverTheContent() {
        var size = SideNavigationSize()
        size.fit(window: 700, drawer: 0)
        // 700 - 56 - 336 leaves 308, less than the least content: the panel takes the row.
        size.fit(window: 700, drawer: panel)
        #expect(!size.isOpen)
        #expect(columns(700, size, drawer: panel) == [4 * rem, 0, 700 - 4 * rem])
    }

    @Test func aNavigationOpenedWhereItHasNoColumnLiesOverTheContent() {
        var size = SideNavigationSize(saved: 22 * rem)
        size.fit(window: 600, drawer: 0)
        #expect(!size.isOpen)
        size.toggle()
        size.fit(window: 600, drawer: 0)
        let layout = BWLayout(window: 600, size: size, drawer: 0)
        // Open, without a column: the rail holds its place, and the content keeps its width.
        #expect(size.isOpen && layout.navigationOverlays)
        #expect(layout.navigation == 4 * rem && layout.main == 600 - 4 * rem)
    }

    @Test func aRememberedWidthThatDoesNotFitClosesTheNavigation() {
        var size = SideNavigationSize()
        size.fit(window: 600, drawer: 0)
        #expect(size.isOpen)
        // The width of the last run arrives after the first layout: 600 - 361 is too little.
        size.restore(361)
        size.fit(window: 600, drawer: 0)
        #expect(!size.isOpen && size.saved == 361)
        #expect(columns(600, size) == [4 * rem, 600 - 4 * rem, 0])
        size.fit(window: 1272, drawer: 0)
        #expect(size.isOpen && size.displayWidth == 361)
    }

    @Test func aNavigationMadeWiderThanTheRoomIsNotClosedForIt() {
        var size = SideNavigationSize()
        size.fit(window: 700, drawer: 0)
        // The user drags the handle out: the window did not change.
        size.drag(to: 30 * rem)
        size.endDrag()
        size.fit(window: 700, drawer: 0)
        #expect(size.isOpen && !size.isPushMode)
        #expect(BWLayout(window: 700, size: size, drawer: 0).navigationOverlays)
    }
}
