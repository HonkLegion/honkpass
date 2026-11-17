import Engine
@testable import EngineLive
import Foundation
import Testing

@Suite struct PwnedPasswordsTests {
    @Test func onlyTheFirstFiveCharactersOfTheHashAreTheRange() {
        // The SHA-1 of "password" is 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8.
        let hash = PwnedPasswords.hashParts(of: "password")
        #expect(hash.start == "5BAA6")
        #expect(hash.ending == "1E4C9B93F3F0682250B6CF8331B7EE68FD8")
        #expect(PwnedPasswords.hashParts(of: "").start.count == 5)
    }

    @Test func theCountIsReadFromTheLineOfTheEnding() {
        let answer = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:52256179\r\n"
            + "011053FD0102E94D6AE2F8B83D76FAF94F6:0\r\n"
        #expect(PwnedPasswords.count(of: "1E4C9B93F3F0682250B6CF8331B7EE68FD8", in: answer) == 52_256_179)
        // A line the service adds as padding has the count zero.
        #expect(PwnedPasswords.count(of: "011053FD0102E94D6AE2F8B83D76FAF94F6", in: answer) == 0)
        #expect(PwnedPasswords.count(of: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", in: answer) == 0)
        #expect(PwnedPasswords.count(of: "1E4C9B93F3F0682250B6CF8331B7EE68FD8", in: "") == 0)
    }

    /// Asks the real service. Off unless PASSVAULT_TEST_PWNED=1: the tests use the local server only.
    /// The two passwords are synthetic: a well-known one and a random one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASSVAULT_TEST_PWNED"] == "1"))
    func theRealServiceKnowsAWellKnownPasswordAndNotARandomOne() async throws {
        #expect(try await PwnedPasswords().timesLeaked("password") > 1_000)
        #expect(try await PwnedPasswords().timesLeaked("synthetic-" + UUID().uuidString + UUID().uuidString) == 0)
    }
}
