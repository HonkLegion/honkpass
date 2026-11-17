import Foundation

/// Conservative metadata matching. Generic codes, PINs, card security codes and recovery
/// codes are not authenticator fields. Never infer a purpose from the field's value.
enum VerificationCodeField {
    enum Kind { case verification, ambiguous, other }

    static func matches(identifier: String?, labels: [String]) -> Bool {
        classify(identifier: identifier, labels: labels) == .verification
    }

    static func classify(identifier: String?, labels: [String]) -> Kind {
        let metadata = labels.map(normalized) + [normalized(identifier ?? "")]
        let excluded: Set<String> = [
            "pin", "recoverycode", "backupcode", "totpsecret", "otpsecret", "cardsecuritycode",
            "cvv", "cvc", "postalcode", "zipcode", "apitoken", "accesstoken", "refreshtoken",
        ]
        if metadata.contains(where: excluded.contains) { return .ambiguous }
        let identifiers: Set<String> = [
            "otp", "totp", "onetimecode", "onetimepassword", "verificationcode",
            "authenticatorcode", "authenticationcode", "twofactorcode", "twofactorauthenticationcode",
            "otc", "verificationtoken", "authenticatortoken", "2fatoken", "idtxtbxsaotccotc",
        ]
        if let identifier {
            let value = normalized(identifier)
            if identifiers.contains(value)
                || identifiers.contains(where: { value == "field" + $0 || value == "input" + $0 || value == $0 + "input" }) {
                return .verification
            }
        }
        let names = identifiers.union(["kodzautentizatoru", "overovacikod", "jednorazovykod", "2facode", "2fakod"])
        if labels.contains(where: { names.contains(normalized($0)) }) { return .verification }
        let ambiguous: Set<String> = ["code", "entercode", "securitycode", "token", "kod", "zadejtekod", "bezpecnostnikod"]
        return metadata.contains(where: ambiguous.contains) ? .ambiguous : .other
    }

    private static func normalized(_ value: String) -> String {
        guard value.utf8.count <= 256 else { return "" }
        return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
