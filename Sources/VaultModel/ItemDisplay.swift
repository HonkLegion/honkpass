import Foundation

// How Bitwarden writes the fields of an item in its item view. Pure functions, no texts of the user interface.

public extension LoginContent {
    /// What the item view shows for a website: its host with the port, else the address as it is
    /// stored (`hostOrUri` of the reference). A bare name with a dot counts as an http address.
    static func displayText(ofWebsite address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespaces)
        let candidate = !text.contains("://") && text.contains(".") ? "http://" + text : text
        guard let components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else { return address }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// The address a browser may open for a website: http or https only. A bare name gets "https".
    /// (The reference puts "http" before a bare name; PassVault does not open a plain connection by itself.)
    static func launchURL(ofWebsite address: String) -> URL? {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

public extension CardContent {
    /// The number in the blocks of its brand: "4111 1111 1111 1111" (the `creditCardNumber` pipe).
    var formattedNumber: String? {
        guard let number, !number.isEmpty else { return nil }
        let digits = number.filter { $0.isASCII && $0.isNumber }
        let rules = Self.blocks[brand ?? ""] ?? Self.blocks["Other"]!
        let rule = rules.first { $0.reduce(0, +) == digits.count } ?? rules[0]
        var chunks: [Substring] = []
        var rest = Substring(digits)
        for length in rule {
            chunks.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        if !rest.isEmpty { chunks.append(rest) }
        return chunks.joined(separator: " ")
    }

    private static let blocks: [String: [[Int]]] = [
        "Visa": [[4, 4, 4, 4]],
        "Mastercard": [[4, 4, 4, 4]],
        "Maestro": [[4, 4, 4, 4], [4, 4, 5], [4, 6, 5], [4, 4, 4, 4, 3]],
        "Discover": [[4, 4, 4, 4]],
        "Diners Club": [[4, 6, 4]],
        "JCB": [[4, 4, 4, 4]],
        "UnionPay": [[4, 4, 4, 4], [6, 13]],
        "Amex": [[4, 6, 5]],
        "Other": [[4, 4, 4, 4]],
    ]

    /// "12 / 2030", with "__" or "____" for a missing part; nil when both are missing.
    var expiration: String? {
        let month = expirationMonth?.isEmpty == false ? expirationMonth : nil
        let year = expirationYear?.isEmpty == false ? expirationYear : nil
        guard month != nil || year != nil else { return nil }
        let twoDigits = month.map { $0.count == 1 ? "0" + $0 : $0 } ?? "__"
        return twoDigits + " / " + (year.map(Self.fullYear) ?? "____")
    }

    /// A two digit year belongs to this century.
    private static func fullYear(_ year: String) -> String {
        year.count == 2 ? "20" + year : year
    }

    /// The brand in a section title, unless it is unknown or "Other".
    var namedBrand: String? {
        guard let brand, !brand.isEmpty, brand != "Other" else { return nil }
        return brand
    }
}

public extension VerificationCode {
    /// A code of more than four characters in two halves: "123 456".
    var formatted: String {
        guard code.count > 4 else { return code }
        let half = code.count / 2
        return code.prefix(half) + " " + code.dropFirst(half)
    }

    /// The seconds the code that is valid at `date` still lives: from `period` down to 1.
    func remainingSeconds(at date: Date) -> Int {
        let period = max(self.period, 1)
        return period - Int(date.timeIntervalSince1970) % period
    }
}
