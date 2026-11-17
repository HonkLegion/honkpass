import Foundation

/// Parts of a web address, as the reference takes them (`Utils.getHostname`, `getHost` and
/// `getDomain` of libs/common/src/platform/misc/utils.ts, which uses the library tldts).
public enum WebAddress {
    /// The host name of an address, in lower case and with international names in Unicode.
    /// An address without a scheme counts as a web address. nil when there is no host.
    public static func hostname(of address: String) -> String? {
        components(of: address)?.host
    }

    /// The host name with its port, when the address names one that is not the usual one of
    /// its scheme: what a browser calls the host of a URL.
    public static func host(of address: String) -> String? {
        guard let parts = components(of: address) else { return nil }
        guard let port = parts.port, port != (parts.scheme == "https" ? 443 : parts.scheme == "http" ? 80 : -1) else { return parts.host }
        return "\(parts.host):\(port)"
    }

    /// The base domain of an address: the part that one owner registered, by the public suffix
    /// list with its private part ("example.co.uk", "someone.github.io"). "localhost" and an
    /// IP address are their own domain. nil when the address has no such domain.
    public static func domain(of address: String) -> String? {
        guard let host = hostname(of: address) else { return nil }
        if host == "localhost" || isIPAddress(host) { return host }
        return PublicSuffixes.shared.registrableDomain(of: host)
    }

    private static func components(of address: String) -> (scheme: String, host: String, port: Int?)? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("data:"), !text.hasPrefix("about:") else { return nil }
        // "Assume http if no other protocol is present"
        let hasScheme = text.contains("://")
        guard hasScheme || text.contains(".") || text.hasPrefix("localhost") else { return nil }
        guard let parts = URLComponents(string: hasScheme ? text : "http://" + text), var host = parts.host, !host.isEmpty else { return nil }
        host = (host.removingPercentEncoding ?? host).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let unicode = host.split(separator: ".", omittingEmptySubsequences: false).map { Punycode.unicode(String($0)) }.joined(separator: ".")
        return ((parts.scheme ?? "http").lowercased(), unicode, parts.port)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in (UInt8(part) != nil) }
    }
}

/// The rules of the public suffix list (Resources/public-suffixes.txt) and the lookup of
/// https://publicsuffix.org/list/: the longest rule wins, a "*" stands for one label, and a
/// rule with "!" takes its label out of a wildcard rule.
struct PublicSuffixes: Sendable {
    static let shared = PublicSuffixes()

    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    private init() {
        var rules: Set<String> = [], wildcards: Set<String> = [], exceptions: Set<String> = []
        let text = Bundle.module.url(forResource: "public-suffixes", withExtension: "txt", subdirectory: "Resources")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("//") {
            if line.hasPrefix("!") {
                exceptions.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                wildcards.insert(String(line.dropFirst(2)))
            } else {
                rules.insert(String(line))
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    /// Whether the list was found. Without it no base domain is known.
    var isLoaded: Bool { !rules.isEmpty }

    /// The public suffix of the host and one label more. nil when the host is a public suffix
    /// itself, or has one label only.
    func registrableDomain(of host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard isLoaded, labels.count >= 2, !labels.contains("") else { return nil }
        // How many labels at the end are the public suffix. An unknown ending counts as one label.
        var suffixLength = 1
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if exceptions.contains(candidate) {
                // "!www.ck": the suffix is the rule without its first label.
                suffixLength = labels.count - start - 1
                break
            }
            if rules.contains(candidate) {
                suffixLength = max(suffixLength, labels.count - start)
            }
            // "*.ck" covers "anything.ck": the candidate without its first label is a wildcard.
            if start + 1 < labels.count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) {
                suffixLength = max(suffixLength, labels.count - start)
            }
        }
        guard labels.count > suffixLength else { return nil }
        return labels[(labels.count - suffixLength - 1)...].joined(separator: ".")
    }
}

/// The decoding of an international label ("xn--0zwm56d" is "测试"): RFC 3492.
enum Punycode {
    static func unicode(_ label: String) -> String {
        guard label.hasPrefix("xn--"), let decoded = decode(String(label.dropFirst(4))) else { return label }
        return decoded
    }

    private static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var n = 128, bias = 72, i = 0
        var output: [UInt32] = []
        var rest = Array(input.unicodeScalars)
        if let delimiter = rest.lastIndex(of: "-") {
            guard rest[..<delimiter].allSatisfy(\.isASCII) else { return nil }
            output = rest[..<delimiter].map(\.value)
            rest = Array(rest[(delimiter + 1)...])
        }
        var position = 0
        while position < rest.count {
            let oldI = i
            var weight = 1, k = base
            while true {
                guard position < rest.count else { return nil }
                let scalar = rest[position].value
                position += 1
                let digit: Int
                switch scalar {
                case 48...57: digit = Int(scalar) - 22
                case 65...90: digit = Int(scalar) - 65
                case 97...122: digit = Int(scalar) - 97
                default: return nil
                }
                let (product, overflow) = digit.multipliedReportingOverflow(by: weight)
                guard !overflow, i <= Int.max - product else { return nil }
                i += product
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                let (next, overflows) = weight.multipliedReportingOverflow(by: base - t)
                guard !overflows else { return nil }
                weight = next
                k += base
            }
            // The adaptation of the bias.
            var delta = oldI == 0 ? (i - oldI) / damp : (i - oldI) / 2
            delta += delta / (output.count + 1)
            var steps = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                steps += base
            }
            bias = steps + (base - tMin + 1) * delta / (delta + skew)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var text = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(value) else { return nil }
            text.append(scalar)
        }
        return String(text).lowercased()
    }
}

public extension ItemDraft.Website {
    /// Whether this website of a login is the web page with this address: `matchesUri` of
    /// libs/common/src/vault/models/view/login-uri.view.ts.
    ///
    /// - Parameters:
    ///   - page: the address of the page.
    ///   - equivalentDomains: the domains the account counts as the domain of the page.
    ///   - defaultMatch: the way of an address that names none; the base domain in Bitwarden.
    func matches(page: String, equivalentDomains: Set<String> = [], defaultMatch: WebsiteMatch = .baseDomain) -> Bool {
        // The address of an app is no website, whatever its match says: it is the page of no browser.
        guard !address.isEmpty, !page.isEmpty, app == nil else { return false }
        switch match ?? defaultMatch {
        case .baseDomain:
            guard let own = WebAddress.domain(of: address), let pageDomain = WebAddress.domain(of: page),
                  own == pageDomain || equivalentDomains.contains(own) else { return false }
            // `DomainMatchBlacklist`: a page of this host is not a page of its domain.
            if let excluded = Self.hostsOutsideTheirDomain[own], let host = WebAddress.host(of: page), excluded.contains(host) {
                return false
            }
            return true
        case .host:
            guard let host = WebAddress.host(of: page) else { return false }
            return host == WebAddress.host(of: address)
        case .exact:
            return page == address
        case .startsWith:
            return page.hasPrefix(address)
        case .regularExpression:
            guard let expression = try? NSRegularExpression(pattern: address, options: .caseInsensitive) else { return false }
            return expression.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)) != nil
        case .never:
            return false
        }
    }

    private static let hostsOutsideTheirDomain: [String: Set<String>] = ["google.com": ["script.google.com"]]
}

public extension VaultContents {
    /// The domains the account counts as the domain of this page (`getUrlEquivalentDomains`).
    func equivalentDomains(ofPage page: String) -> Set<String> {
        guard let domain = WebAddress.domain(of: page) else { return [] }
        return Set(equivalentDomains.filter { $0.contains(domain) }.joined())
    }

    /// The logins of a web page, in name order: the ones with a website that matches it. Not
    /// the items of the trash and the archive.
    func logins(ofPage page: String) -> [VaultItemSummary] {
        let equivalents = equivalentDomains(ofPage: page)
        return items(in: .type(.login)).filter { item in
            !item.isUndecryptable && item.websites.contains { $0.matches(page: page, equivalentDomains: equivalents) }
        }
    }
}
