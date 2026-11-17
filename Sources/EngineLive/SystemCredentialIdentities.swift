import AuthenticationServices
import Engine
import VaultModel

/// The store of macOS that holds what AutoFill may offer (`ASCredentialIdentityStore`). The
/// user turns PassVault on as a source of AutoFill in the settings of the system; before
/// that the store takes nothing. An entry names a website, a user name and the item, and no
/// secret.
public struct SystemCredentialIdentities: CredentialIdentitiesPort {
    public init() {}

    public func isEnabled() async -> Bool {
        await ASCredentialIdentityStore.shared.state().isEnabled
    }

    public func replace(with identities: [AutoFillIdentity]) async {
        let entries = identities.map { identity -> any ASCredentialIdentity in
            // A website with a scheme is a URL for the system; a bare name is a domain.
            let service = ASCredentialServiceIdentifier(identifier: identity.website,
                                                        type: identity.website.contains("://") ? .URL : .domain)
            switch identity.kind {
            case .password:
                return ASPasswordCredentialIdentity(serviceIdentifier: service, user: identity.username, recordIdentifier: identity.itemID)
            case .verificationCode:
                return ASOneTimeCodeCredentialIdentity(serviceIdentifier: service, label: identity.username,
                                                       recordIdentifier: identity.itemID)
            case .passkey:
                // The website of a passkey is the identifier of its relying party.
                return ASPasskeyCredentialIdentity(relyingPartyIdentifier: identity.website, userName: identity.username,
                                                   credentialID: identity.credentialID ?? Data(),
                                                   userHandle: identity.userHandle ?? Data(), recordIdentifier: identity.itemID)
            }
        }
        // A store that refuses keeps what it had; the next change of the vault tries again.
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(entries)
    }

    public func removeAll() async {
        try? await ASCredentialIdentityStore.shared.removeAllCredentialIdentities()
    }
}
