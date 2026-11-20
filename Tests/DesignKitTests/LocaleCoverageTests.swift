import Foundation
import Testing
@testable import DesignKit

@Suite struct LocaleCoverageTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Entry: Decodable {
        let m: String
        let p: [String: String]?

        var arguments: Set<String> {
            Set(m.matches(of: /\$([A-Za-z0-9_]+)\$/).map {
                p?[$0.1.lowercased()] ?? String($0.0)
            })
        }
    }

    private func catalog(_ name: String) throws -> [String: Entry] {
        let file = root.appending(path: "Sources/DesignKit/Resources/Locales/\(name).json")
        return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
    }

    private func texts(_ language: String) throws -> [String: Entry] {
        try catalog(language).merging(catalog("honkpass-" + language)) { _, own in own }
    }

    @Test func literalUIKeysHaveAnEnglishText() throws {
        let english = try texts("en")
        let pattern = try NSRegularExpression(pattern: #"BWText\["([^"]+)""#)
        for directory in ["App", "Sources/DesignKit", "Sources/ProviderUI"] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: directory), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    if let range = Range(match.range(at: 1), in: source) {
                        #expect(english[String(source[range])] != nil, "Missing \(source[range]) in \(file.lastPathComponent)")
                    }
                }
            }
        }
    }

    @Test func everyLanguageSuppliesTheEnglishKeysAndTheirArguments() throws {
        let english = try texts("en")
        let arguments = english.mapValues(\.arguments)
        let honkPassKeys = Set(try catalog("honkpass-en").keys)
        for language in BWText.supportedLanguages {
            let localized = try texts(language)
            let own = try catalog("honkpass-" + language)
            #expect(honkPassKeys.isSubset(of: own.keys), "Missing HonkPass wording in \(language)")
            let missing = Set(english.keys).subtracting(localized.keys)
            #expect(missing.isEmpty, "\(language) is missing \(missing.sorted())")
            let invalid = localized.filter { key, entry in
                entry.m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.arguments != arguments[key]
            }
            #expect(invalid.isEmpty, "\(language) has empty text or incompatible arguments in \(invalid.keys.sorted())")
        }
    }

    @Test func languageMenuMatchesBothMacOSBundles() throws {
        let expected = Set(BWText.supportedLanguages)
        for path in ["App/PassVault/Info.plist", "App/Provider/Info.plist"] {
            let data = try Data(contentsOf: root.appending(path: path))
            let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let declared = try #require(plist["CFBundleLocalizations"] as? [String])
            #expect(Set(declared) == expected)
        }
    }

    @Test func preferredLanguagesRespectRegionAndPreferenceOrder() {
        #expect(BWText.systemLanguage(["en-GB"]) == "en-GB")
        #expect(BWText.systemLanguage(["pt-PT"]) == "pt-PT")
        #expect(BWText.systemLanguage(["uk-UA"]) == "uk")
        #expect(BWText.systemLanguage(["ru-RU", "de-AT"]) == "de")
        #expect(BWText.systemLanguage(["ru-RU", "be-BY"]) == "en")
    }
}
