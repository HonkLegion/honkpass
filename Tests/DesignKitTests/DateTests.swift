import Foundation
import Testing
@testable import DesignKit

@Suite @MainActor struct DateTests {
    @Test func reusedFormattersKeepTheReferenceTextAcrossLanguageAndTimeZoneChanges() throws {
        let dates = [Date(timeIntervalSince1970: 1_768_000_000), Date(timeIntervalSince1970: 1_783_000_000)]
        for language in ["en", "cs", "en"] {
            for identifier in ["Europe/Prague", "America/New_York", "Europe/Prague"] {
                let zone = try #require(TimeZone(identifier: identifier))
                for short in [false, true] {
                    let day = DateFormatter()
                    day.locale = Locale(identifier: language)
                    day.timeZone = zone
                    day.dateStyle = short ? .short : .medium
                    let time = DateFormatter()
                    time.locale = day.locale
                    time.timeZone = zone
                    time.timeStyle = short ? .short : .medium
                    for date in dates {
                        let expected = (day.string(from: date) + (language == "en" ? ", " : " ") + time.string(from: date))
                            .replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
                        #expect(BWDate.format(date, short: short, language: language, zone: zone) == expected)
                    }
                }
            }
        }
    }
}
