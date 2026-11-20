import Testing
import VaultModel

@Suite struct GeneratorOptionsTests {
    @Test func everyEnabledCharacterClassHasRoomInThePassword() {
        var options = PasswordOptions()
        options.length = 5
        options.special = true
        options.minSpecial = 0
        options.minNumbers = 7
        #expect(options.normalized.length == 10)
    }

    @Test func theDefaultsAreTheOnesOfTheReference() {
        let password = PasswordOptions()
        #expect(password.length == 14 && password.uppercase && password.lowercase && password.numbers && !password.special)
        #expect(password.minNumbers == 1 && password.minSpecial == 0 && !password.avoidAmbiguous)
        #expect(password.normalized == password)
        let passphrase = PassphraseOptions()
        #expect(passphrase.words == 6 && passphrase.separator == "-" && !passphrase.capitalize && !passphrase.includeNumber)
        #expect(passphrase.normalized == passphrase)
        #expect(GeneratorOptions().kind == .password && UsernameOptions().kind == .randomWord)
    }

    @Test func passwordOptionsAreBroughtInsideTheirLimits() {
        var options = PasswordOptions()
        options.length = 3
        #expect(options.normalized.length == 5)
        options.length = 500
        #expect(options.normalized.length == 128)
        options.minNumbers = 40
        options.special = true
        options.minSpecial = -2
        #expect(options.normalized.minNumbers == 9 && options.normalized.minSpecial == 0)

        // A least number counts only for a kind of character that is included.
        options = PasswordOptions()
        options.numbers = false
        options.minSpecial = 4
        #expect(options.normalized.minNumbers == 0 && options.normalized.minSpecial == 0)

        // Without any kind of character the lower-case letters stand in.
        options.uppercase = false
        options.lowercase = false
        #expect(options.normalized.lowercase)

        // The length has room for every least number.
        options = PasswordOptions()
        options.length = 5
        options.special = true
        options.minNumbers = 9
        options.minSpecial = 9
        #expect(options.normalized.length == 20)
    }

    @Test func passphraseOptionsAreBroughtInsideTheirLimits() {
        var options = PassphraseOptions()
        options.words = 1
        options.separator = "--"
        #expect(options.normalized.words == 3 && options.normalized.separator == "-")
        options.words = 99
        options.separator = ""
        #expect(options.normalized.words == 20 && options.normalized.separator == "")
    }
}
