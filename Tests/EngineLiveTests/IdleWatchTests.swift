@testable import EngineLive
import Testing

@Suite struct IdleWatchTests {
    /// What the watch reports for a row of idle times, one for each look at the clock.
    private func reports(_ idleSeconds: [Double]) -> [Bool] {
        var watch = IdleWatch()
        return idleSeconds.map { watch.becameIdle(idleSeconds: $0) }
    }

    @Test func idleIsReportedOnceAfterFiveMinutesWithoutInput() {
        #expect(reports([30, 299, 300, 330]) == [false, false, true, false])
    }

    @Test func idleIsReportedAgainAfterNewInput() {
        #expect(reports([400, 2, 301]) == [true, false, true])
    }
}
