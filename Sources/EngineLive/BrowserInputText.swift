import Foundation

/// Small Unicode batches preserve surrogate pairs and composed characters. Control
/// characters are refused because a text-input event must never submit or navigate a form.
enum BrowserInputText {
    static func chunks(_ value: String) -> [String]? {
        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
        }) else { return nil }
        var result: [String] = []
        var chunk = ""
        for character in value {
            let text = String(character)
            guard text.utf16.count <= 20 else { return nil }
            if chunk.utf16.count + text.utf16.count > 20 {
                result.append(chunk)
                chunk = ""
            }
            chunk += text
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
