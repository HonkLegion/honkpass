import Engine
import Foundation

// Development only: reads the mail the local Vaultwarden sends. The mail catcher of
// support/vaultwarden/compose.yaml keeps every mail and delivers none.

/// The API of the mail catcher (Mailpit).
package struct MailCatcher: Sendable {
    package let base: URL
    private let http = HTTPClient()

    package init(base: URL) {
        self.base = base
    }

    /// Removes the mails to an address, so that the next code found is a new one.
    package func deleteMail(to address: String) async throws {
        let request = try HTTPClient.request("DELETE", base, "api/v1/search", query: [query(to: address)])
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else { throw HTTPClient.refusal(data, status: status) }
    }

    /// The six-digit code of the newest mail to an address. Waits up to ten seconds for the mail.
    package func latestCode(to address: String) async throws -> String {
        for _ in 0..<50 {
            if let code = try await codeOfNewestMail(to: address) { return code }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw EngineError.server("The mail catcher has no mail with a code for \(address).")
    }

    private func codeOfNewestMail(to address: String) async throws -> String? {
        let search = try HTTPClient.request("GET", base, "api/v1/search",
                                            query: [query(to: address), URLQueryItem(name: "limit", value: "1")])
        let (list, status) = try await http.send(search)
        guard status == 200 else { throw HTTPClient.refusal(list, status: status) }
        guard let object = (try? JSONSerialization.jsonObject(with: list)) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]], let id = messages.first?["ID"] as? String,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let (mail, mailStatus) = try await http.send(try HTTPClient.request("GET", base, "api/v1/message/\(id)"))
        guard mailStatus == 200, let message = (try? JSONSerialization.jsonObject(with: mail)) as? [String: Any],
              let text = message["Text"] as? String else { return nil }
        // The code stands alone in the text: a run of exactly six digits.
        return text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).first { $0.count == 6 }.map(String.init)
    }

    /// Only the mails with a code: a log-in from a new device makes the server send another mail.
    private func query(to address: String) -> URLQueryItem {
        URLQueryItem(name: "query", value: "to:\"\(address)\" subject:\"Verification Code\"")
    }
}
