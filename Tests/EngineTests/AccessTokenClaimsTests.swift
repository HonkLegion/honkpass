import Engine
import Foundation
import Testing

@Suite struct AccessTokenClaimsTests {
    /// A synthetic token: the claims as base64url without padding, between a header and a signature.
    private func token(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0." + payload + ".c2lnbmF0dXJl"
    }

    @Test func theNameIsReadFromTheClaims() throws {
        #expect(AccessTokenClaims.name(in: try token(["name": "Test User", "email": "test@passvault.test"])) == "Test User")
        // Characters that base64url writes otherwise than base64.
        #expect(AccessTokenClaims.name(in: try token(["name": "Žluťoučký kůň ~~~ ???"])) == "Žluťoučký kůň ~~~ ???")
    }

    @Test func aTokenWithoutANameNamesNone() throws {
        #expect(AccessTokenClaims.name(in: try token(["email": "test@passvault.test"])) == nil)
        #expect(AccessTokenClaims.name(in: try token(["name": "  "])) == nil)
        #expect(AccessTokenClaims.name(in: "fake-access-token") == nil)
        #expect(AccessTokenClaims.name(in: "a.%%%.c") == nil)
    }
}
