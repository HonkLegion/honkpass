import CoreGraphics
@testable import DesignKit
import Testing

/// The column widths of a table with "table-layout: auto".
struct TableLayoutTests {
    private func rounded(_ widths: [CGFloat]) -> [Int] {
        widths.map { Int($0.rounded()) }
    }

    /// The empty table of the Sends in docs/reference/send-dark.png: three titles in 855 pixels.
    @Test func aTableWiderThanItsContentSharesTheRestByTheContent() {
        let widths = BWTableLayout.widths(of: [.init(89), .init(152), .init(60)], in: 855)
        #expect(rounded(widths) == [253, 432, 170])
        #expect(abs(widths.reduce(0, +) - 855) < 0.001)
    }

    @Test func aColumnWithAWidthOfItsOwnTakesNoneOfTheRest() {
        let widths = BWTableLayout.widths(of: [.init(200), .init(100), .init(60, hasOwnWidth: true)], in: 660)
        #expect(rounded(widths) == [400, 200, 60])
    }

    @Test func columnsThatAllHaveTheirOwnWidthShareTheRest() {
        let widths = BWTableLayout.widths(of: [.init(100, hasOwnWidth: true), .init(300, hasOwnWidth: true)], in: 800)
        #expect(rounded(widths) == [200, 600])
    }

    @Test func aTableNarrowerThanItsContentTakesTheSameShareFromEachColumnThatCanBreak() {
        let columns: [BWTableLayout.Column] = [.init(minimum: 100, maximum: 300), .init(minimum: 50, maximum: 150), .init(60)]
        // Half of the way from 210 to 510.
        #expect(rounded(BWTableLayout.widths(of: columns, in: 360)) == [200, 100, 60])
    }

    @Test func aTableNarrowerThanItsBrokenContentKeepsThatContent() {
        let columns: [BWTableLayout.Column] = [.init(minimum: 100, maximum: 300), .init(60)]
        #expect(rounded(BWTableLayout.widths(of: columns, in: 120)) == [100, 60])
    }
}
