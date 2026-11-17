import Foundation

/// Angular's date and time layout, with reusable formatters and no cached vault text.
@MainActor public enum BWDate {
    private struct Formatters {
        let language: String
        let zone: TimeZone
        let mediumDay: DateFormatter
        let mediumTime: DateFormatter
        let shortDay: DateFormatter
        let shortTime: DateFormatter

        init(language: String, zone: TimeZone) {
            self.language = language
            self.zone = zone
            func formatter(_ style: DateFormatter.Style, time: Bool) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: language)
                formatter.timeZone = zone
                formatter.dateStyle = time ? .none : style
                formatter.timeStyle = time ? style : .none
                return formatter
            }
            mediumDay = formatter(.medium, time: false)
            mediumTime = formatter(.medium, time: true)
            shortDay = formatter(.short, time: false)
            shortTime = formatter(.short, time: true)
        }
    }

    private static var cached: Formatters?

    public static func medium(_ date: Date) -> String { format(date, short: false) }
    public static func short(_ date: Date) -> String { format(date, short: true) }

    static func format(_ date: Date, short: Bool, language: String = BWText.settings.language,
                       zone: TimeZone = .current) -> String {
        if cached?.language != language || cached?.zone != zone {
            cached = Formatters(language: language, zone: zone)
        }
        guard let cached else { return "" }
        let day = short ? cached.shortDay : cached.mediumDay
        let time = short ? cached.shortTime : cached.mediumTime
        return (day.string(from: date) + (language == "en" ? ", " : " ") + time.string(from: date))
            .replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }
}
