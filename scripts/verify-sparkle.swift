import CryptoKit
import Foundation
let args = CommandLine.arguments
guard args.count == 4, let raw = Data(base64Encoded: args[1]), let signature = Data(base64Encoded: args[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
let message = try Data(contentsOf: URL(fileURLWithPath: args[3]))
exit(key.isValidSignature(signature, for: message) ? 0 : 1)
