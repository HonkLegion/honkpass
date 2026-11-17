import Foundation
import Testing
import VaultModel

@Suite struct ItemDisplayTests {
    @Test func aWebsiteShowsItsHostWithThePort() {
        #expect(LoginContent.displayText(ofWebsite: "https://mail.example.com/inbox?x=1") == "mail.example.com")
        #expect(LoginContent.displayText(ofWebsite: "www.example.com") == "www.example.com")
        #expect(LoginContent.displayText(ofWebsite: "http://localhost:8642/path") == "localhost:8642")
        #expect(LoginContent.displayText(ofWebsite: "androidapp://com.example") == "com.example")
        #expect(LoginContent.displayText(ofWebsite: "not an address") == "not an address")
    }

    @Test func onlyWebAddressesCanBeOpened() {
        #expect(LoginContent.launchURL(ofWebsite: "https://mail.example.com/inbox")?.absoluteString == "https://mail.example.com/inbox")
        #expect(LoginContent.launchURL(ofWebsite: "shop.example.com")?.absoluteString == "https://shop.example.com")
        #expect(LoginContent.launchURL(ofWebsite: "file:///etc/hosts") == nil)
        #expect(LoginContent.launchURL(ofWebsite: "javascript:alert(1)") == nil)
        #expect(LoginContent.launchURL(ofWebsite: "androidapp://com.example") == nil)
        #expect(LoginContent.launchURL(ofWebsite: "  ") == nil)
    }

    @Test func aCardNumberIsWrittenInTheBlocksOfItsBrand() {
        #expect(CardContent(brand: "Visa", number: "4111111111111111").formattedNumber == "4111 1111 1111 1111")
        #expect(CardContent(brand: "Amex", number: "378282246310005").formattedNumber == "3782 822463 10005")
        #expect(CardContent(brand: nil, number: "4111-1111-1111-1111-99").formattedNumber == "4111 1111 1111 1111 99")
        #expect(CardContent(brand: "Visa", number: "").formattedNumber == nil)
    }

    @Test func theExpirationNamesAMissingPart() {
        #expect(CardContent(expirationMonth: "12", expirationYear: "2030").expiration == "12 / 2030")
        #expect(CardContent(expirationMonth: "3", expirationYear: "30").expiration == "03 / 2030")
        #expect(CardContent(expirationMonth: nil, expirationYear: "2030").expiration == "__ / 2030")
        #expect(CardContent(expirationMonth: "7", expirationYear: nil).expiration == "07 / ____")
        #expect(CardContent().expiration == nil)
    }

    @Test func aVerificationCodeIsShownInTwoHalves() {
        #expect(VerificationCode(code: "123456", period: 30).formatted == "123 456")
        #expect(VerificationCode(code: "12345678", period: 30).formatted == "1234 5678")
        #expect(VerificationCode(code: "1234", period: 30).formatted == "1234")
    }

    @Test func aVerificationCodeCountsDownToTheEndOfItsPeriod() {
        let code = VerificationCode(code: "123456", period: 30)
        #expect(code.remainingSeconds(at: Date(timeIntervalSince1970: 60)) == 30)
        #expect(code.remainingSeconds(at: Date(timeIntervalSince1970: 61.4)) == 29)
        #expect(code.remainingSeconds(at: Date(timeIntervalSince1970: 89.9)) == 1)
    }

    @Test func anAddressHasOneLineForEachPart() {
        var identity = IdentityContent()
        #expect(identity.fullAddress == nil)
        identity.address1 = "1 Example Street"
        identity.city = "Prague"
        identity.postalCode = "110 00"
        identity.country = "CZ"
        #expect(identity.fullAddress == "1 Example Street\nPrague, 110 00\nCZ")
        identity.city = nil
        identity.state = "Bohemia"
        #expect(identity.fullAddress == "1 Example Street\n-, Bohemia, 110 00\nCZ")
    }
}
