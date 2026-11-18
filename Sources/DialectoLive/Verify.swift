import CryptoKit
import Foundation

/// The manifest envelope and its signatures: one signature must match one of the app's
/// public keys, over the prefix and the payload's decoded bytes exactly as given, never re-serialized.
enum ManifestVerifier {
    static let prefix = Data("dialecto-live-manifest-v1.".utf8)
    static let keyScheme = "ed25519:"

    struct Envelope: Decodable {
        struct Signature: Decodable {
            let key: String
            let sig: String
        }

        let format: Int
        let payload: String
        let sigs: [Signature]
    }

    /// `ed25519:<base64url of 32 bytes>` as a key, or nil.
    static func parseKey(_ text: String) -> Curve25519.Signing.PublicKey? {
        guard text.hasPrefix(keyScheme), let raw = Base64URL.decode(String(text.dropFirst(keyScheme.count))),
            raw.count == 32
        else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// The signed payload bytes, or why the manifest is refused.
    static func verify(
        _ envelope: Envelope, keys: [String: Curve25519.Signing.PublicKey]
    ) -> Result<Data, DialectoLiveError> {
        guard let payload = Base64URL.decode(envelope.payload) else {
            return .failure(.init(.badManifest, "The manifest payload is not base64url"))
        }
        let signed = prefix + payload
        var knownKey = false
        for entry in envelope.sigs {
            guard let key = keys[entry.key] else { continue }
            knownKey = true
            guard let signature = Base64URL.decode(entry.sig), signature.count == 64 else { continue }
            if key.isValidSignature(signature, for: signed) { return .success(payload) }
        }
        return .failure(
            knownKey
                ? .init(.badSignature, "No signature on the manifest verifies")
                : .init(.unknownKey, "The manifest is signed only by keys this app does not know"))
    }
}
