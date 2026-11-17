import BitwardenSdk
import Engine
import Foundation
import VaultModel

// The SSH keys of the vault for the agent. The SDK decrypts the item; the signature is made by
// CryptoKit of the system (`OpenSSHEd25519Key`), since the SDK signs nothing with an SSH key.
// The private key is read for one signature and is kept nowhere.

extension SDKVault {
    /// The Ed25519 keys of the items that are not in the trash and not archived. A key that
    /// two items hold is offered once, for the first of them.
    func sshIdentities() async -> [SSHAgentIdentity] {
        let ids = encryptedItems.withLock { items in
            items.filter { $0.value.type == .sshKey && $0.value.deletedDate == nil && $0.value.archivedDate == nil }.map(\.key)
        }
        var identities: [SSHAgentIdentity] = []
        for id in ids.sorted() {
            guard let view = try? await decrypted(id), let key = view.sshKey,
                  let blob = SSHWire.publicKeyBlob(ofLine: key.publicKey), Self.canSign(with: blob),
                  !identities.contains(where: { $0.publicKeyBlob == blob }) else { continue }
            identities.append(SSHAgentIdentity(itemID: id, name: view.name, publicKeyBlob: blob,
                                               publicKeyFingerprint: SSHWire.fingerprint(of: blob)))
        }
        return identities
    }

    /// The agent signs with Ed25519 keys (PLAN.md, differences).
    private static func canSign(with publicKeyBlob: Data) -> Bool {
        var reader = SSHReader(publicKeyBlob)
        return reader.string(maximum: 64) == OpenSSHEd25519Key.keyType
    }

    func sshSignature(itemID: String, publicKeyBlob: Data, data: Data, flags: UInt32) async throws -> Data {
        guard let stored = try await decrypted(itemID).sshKey else { throw EngineError.notFound }
        // The flags choose the hash of an RSA signature; an Ed25519 key takes none.
        guard flags == 0, let key = OpenSSHEd25519Key(privateKeyText: stored.privateKey), key.publicKeyBlob == publicKeyBlob else {
            throw EngineError.notFound
        }
        guard let signature = key.signature(over: data) else { throw EngineError.unexpected("The SSH key could not sign.") }
        return signature
    }
}
