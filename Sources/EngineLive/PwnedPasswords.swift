import CryptoKit
import Engine
import Foundation

/// The check of a leaked password as Bitwarden does it (libs/common/src/services/audit.service.ts):
/// the range API of Pwned Passwords. Only the first five characters of the SHA-1 of the password
/// leave this Mac; the service answers with every known ending for them and the comparison is
/// done here. This request is sent only when the user asks for the check.
///
/// The hash is the one the service asks for, computed by CryptoKit. It is not vault cryptography.
public struct PwnedPasswords: PasswordLeaksPort {
    private static let api = URL(string: "https://api.pwnedpasswords.com/range/")!
    let http = HTTPClient()

    public init() {}

    public func timesLeaked(_ password: String) async throws -> Int {
        let hash = Self.hashParts(of: password)
        var request = URLRequest(url: Self.api.appending(path: hash.start))
        // The service then pads its answer, so that its size says nothing about the range.
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, status) = try await http.send(request)
        // An error page must not read as "no ending matches".
        guard (200..<300).contains(status), data.count <= 4_194_304, let answer = String(data: data, encoding: .utf8) else {
            throw EngineError.server("The leaked password service answered with HTTP \(status).")
        }
        return Self.count(of: hash.ending, in: answer)
    }

    /// The SHA-1 of the password in upper-case hexadecimal: its first five characters and the rest.
    static func hashParts(of password: String) -> (start: String, ending: String) {
        let hash = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        return (String(hash.prefix(5)), String(hash.dropFirst(5)))
    }

    /// The answer has one line "ENDING:COUNT" for each known hash of the range.
    static func count(of ending: String, in answer: String) -> Int {
        for line in answer.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0] == ending { return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return 0
    }
}
