import Foundation

/// What an access token says of its account. The token is a JWT; its claims are read and not
/// checked, as the reference reads them for the name of an account it adds
/// (`decodeAccessToken` in libs/auth/src/common/login-strategies/login.strategy.ts). The name
/// only labels the account on the screen.
public enum AccessTokenClaims {
    /// The claim "name"; nil for a token that is no JWT, has no name or an empty one.
    public static func name(in token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // base64url without padding.
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = claims["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
