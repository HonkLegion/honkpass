@testable import EngineLive
import Foundation
import Testing

@Suite struct FillInputTests {
    @Test func microsoftCodeFieldsAndAmbiguousTokens() {
        for identifier in ["idTxtBx_SAOTCC_OTC", "otc"] {
            #expect(VerificationCodeField.matches(identifier: identifier, labels: ["Code"]))
        }
        #expect(VerificationCodeField.matches(identifier: "token", labels: ["Verification code"]))
        for name in ["token", "Code", "PIN", "Security code", "Recovery code", "totp-secret"] {
            #expect(VerificationCodeField.classify(identifier: name, labels: []) == .ambiguous)
        }
        #expect(VerificationCodeField.classify(identifier: "otp", labels: ["Recovery code"]) == .ambiguous)
        #expect(VerificationCodeField.classify(identifier: "email", labels: ["Email"]) == .other)
    }

    @Test func verificationFieldsNeedSpecificMetadata() {
        for identifier in ["totp", "field-totp", "one-time-code", "input_otp", "verificationCode"] {
            #expect(VerificationCodeField.matches(identifier: identifier, labels: []))
        }
        for label in ["Verification code", "Kód z autentizátoru", "Ověřovací kód", "One-time password"] {
            #expect(VerificationCodeField.matches(identifier: nil, labels: [label]))
        }
        for ambiguous in ["code", "PIN", "Security code", "Postal code", "Recovery code", "totp-secret", "Verification code help"] {
            #expect(!VerificationCodeField.matches(identifier: ambiguous, labels: [ambiguous]))
        }
    }

    @Test func browserInputPreservesUnicodeWithoutControlKeys() throws {
        let value = "synthetic-" + String(repeating: "a", count: 67) + "é👨‍👩‍👧‍👦e\u{301}!"
        let chunks = try #require(BrowserInputText.chunks(value))
        #expect(chunks.joined() == value)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
        #expect(chunks.flatMap { Array($0) } == Array(value))
        for value in ["test\n", "test\r", "test\t", "test\u{1b}", "test\u{0}"] {
            #expect(BrowserInputText.chunks(value) == nil)
        }
    }
}
