/// An opaque reference to one unlocked session. A lock or account change invalidates it.
/// It contains no credentials and grants no additional permissions.
public struct VaultSessionToken: Sendable, Equatable {
    let epoch: Int
}
