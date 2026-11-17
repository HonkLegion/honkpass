import Foundation
import Synchronization

/// The texts of Bitwarden desktop, looked up by the key of its locale files.
/// HonkPass additions live separately from the imported locale files.
public enum BWText {
    public struct Settings: Sendable {
        /// "en" or "cs".
        public var language: String
        /// The name that replaces "Bitwarden" in the texts.
        public var productName: String

        public init(language: String, productName: String) {
            self.language = language
            self.productName = productName
        }
    }

    public static let supportedLanguages = ["en", "cs"]

    private struct Entry: Decodable {
        let m: String
        let p: [String: String]?
    }

    private struct State {
        var settings: Settings
        var tables: [String: [String: Entry]] = [:]
    }

    private static let state = Mutex(State(settings: Settings(language: systemLanguage(), productName: "HonkPass")))

    /// Changes the language or the product name. The app calls it once, before the first window.
    public static func configure(_ change: (inout Settings) -> Void) {
        state.withLock { change(&$0.settings) }
    }

    public static var settings: Settings {
        state.withLock { $0.settings }
    }

    /// The text of a key with its placeholders filled in order. An unknown key returns the key itself.
    public static subscript(_ key: String, _ arguments: String...) -> String {
        text(key, arguments)
    }

    public static func text(_ key: String, _ arguments: [String] = []) -> String {
        let (entry, productName): (Entry?, String) = state.withLock { state in
            let language = state.settings.language
            if state.tables[language] == nil { state.tables[language] = load(language) }
            return (state.tables[language]?[key] ?? fallback(key, &state), state.settings.productName)
        }
        guard let entry else {
            assertionFailure("Unknown text key \(key)")
            return key
        }
        // Rename the app in the template only. Arguments can name an import format, another
        // product or user content and must remain verbatim.
        let describesExportFormat = key == "accountRestrictedOptionDescription" || key == "passwordProtectedOptionDescription"
        var message = describesExportFormat ? entry.m : productNamed(entry.m, productName)
        for (name, content) in entry.p ?? [:] {
            var value = content
            for (index, argument) in arguments.enumerated() {
                value = value.replacingOccurrences(of: "$\(index + 1)", with: argument)
            }
            message = message.replacingOccurrences(of: "$\(name.uppercased())$", with: value)
        }
        return message
    }

    /// "Bitwarden" becomes the name of this app, except in the names of other products of Bitwarden.
    static func productNamed(_ message: String, _ productName: String) -> String {
        let kept = ["Bitwarden Authenticator"]
        var text = message
        for (index, name) in kept.enumerated() { text = text.replacingOccurrences(of: name, with: "\u{1}\(index)\u{1}") }
        text = text.replacingOccurrences(of: "Bitwarden", with: productName)
        for (index, name) in kept.enumerated() { text = text.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: name) }
        return text
    }

    private static func fallback(_ key: String, _ state: inout State) -> Entry? {
        if state.tables["en"] == nil { state.tables["en"] = load("en") }
        return state.tables["en"]?[key]
    }

    private static func load(_ language: String) -> [String: Entry] {
        guard let url = Bundle.module.url(forResource: language, withExtension: "json", subdirectory: "Resources/Locales"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            assertionFailure("DesignKit texts for \(language) are missing")
            return [:]
        }
        guard let additionsURL = Bundle.module.url(forResource: "honkpass-" + language, withExtension: "json",
                                                    subdirectory: "Resources/Locales"),
              let additionsData = try? Data(contentsOf: additionsURL),
              let additions = try? JSONDecoder().decode([String: Entry].self, from: additionsData) else {
            assertionFailure("HonkPass texts for \(language) are missing")
            return table
        }
        return table.merging(additions) { _, own in own }
    }

    private static func systemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return supportedLanguages.contains(preferred) ? preferred : "en"
    }
}
