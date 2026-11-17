import Foundation
import Testing

@Suite struct LocaleCoverageTests {
    @Test func literalUIKeysHaveALocalizedOrFallbackText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"BWText\["([^"]+)""#)
        var keys: [String: String] = [:]
        for directory in ["App", "Sources/DesignKit", "Sources/ProviderUI"] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: directory), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                for match in pattern.matches(in: source, range: range) {
                    if let range = Range(match.range(at: 1), in: source) { keys[String(source[range])] = file.lastPathComponent }
                }
            }
        }
        func texts(_ language: String) throws -> [String: Any] {
            var result: [String: Any] = [:]
            for name in [language, "honkpass-" + language] {
                let file = root.appending(path: "Sources/DesignKit/Resources/Locales/\(name).json")
                let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                result.merge(entries) { _, own in own }
            }
            return result
        }
        let english = try texts("en")
        for language in ["en", "cs"] {
            let locale = try texts(language)
            for (key, source) in keys {
                // BWText uses English when the reference has not translated a key yet.
                #expect(locale[key] != nil || english[key] != nil, "Missing \(language) text and fallback for \(key) in \(source)")
            }
        }
    }
}
