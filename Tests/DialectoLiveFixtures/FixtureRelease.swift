import CryptoKit
import Foundation

/// Signed releases for the tests and the demo, made with the test-only key. Never a product: nothing
/// here signs a real release.
public struct FixtureRelease {
    public struct File {
        public var catalog: String
        public var locale: String
        public var values: [String: String]

        public init(catalog: String = "localizable", locale: String, values: [String: String]) {
            self.catalog = catalog
            self.locale = locale
            self.values = values
        }
    }

    public var channel = "production"
    public var sequence: Int
    public var release: String
    public var commit = String(repeating: "9d2b7e1c", count: 5)
    public var committedAt = "2026-10-09T12:00:00Z"
    public var publishedAt = "2026-10-09T12:00:41Z"
    public var files: [File]

    public init(sequence: Int, release: String, files: [File]) {
        self.sequence = sequence
        self.release = release
        self.files = files
    }

    /// The payload file for one language: a flat JSON object, keys sorted.
    public static func payloadData(_ values: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Relative path (as the channel serves it) -> bytes: `manifest.json` and each payload. A manifest
    /// signed by `keys`, in that order; the bytes can be altered afterwards to make a bad release.
    public func served(signedBy keys: [Curve25519.Signing.PrivateKey]) -> [String: Data] {
        var served: [String: Data] = [:]
        var entries: [[String: Any]] = []
        for file in files.sorted(by: { ($0.catalog, $0.locale) < ($1.catalog, $1.locale) }) {
            let data = Self.payloadData(file.values)
            let url = "r/\(release)/\(file.catalog)/\(file.locale).json"
            served[url] = data
            entries.append([
                "catalog": file.catalog, "locale": file.locale, "format": "xcstrings", "url": url,
                "sha256": Self.hex(SHA256.hash(data: data)), "bytes": data.count,
                "git_blob": Self.hex(Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data)),
            ])
        }
        let payload = try! JSONSerialization.data(
            withJSONObject: [
                "channel": channel, "sequence": sequence, "release": release, "commit": commit,
                "committed_at": committedAt, "published_at": publishedAt, "files": entries,
            ] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes])
        served["manifest.json"] = Self.envelope(payload: payload, keys: keys)
        return served
    }

    /// Writes `served(signedBy:)` into `directory` (the channel's folder).
    public func write(to directory: URL, signedBy keys: [Curve25519.Signing.PrivateKey]) throws {
        for (path, data) in served(signedBy: keys) {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// A `manifest.json`: the payload in base64url and a signature per key over the prefix and the payload bytes.
    public static func envelope(payload: Data, keys: [Curve25519.Signing.PrivateKey]) -> Data {
        let signed = Data("dialecto-live-manifest-v1.".utf8) + payload
        let sigs: [[String: String]] = keys.map { key in
            [
                "key": "ed25519:" + base64url(key.publicKey.rawRepresentation),
                "sig": base64url(try! key.signature(for: signed)),
            ]
        }
        return try! JSONSerialization.data(
            withJSONObject: ["format": 1, "payload": base64url(payload), "sigs": sigs] as [String: Any],
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The contract release the Dialecto server's fixture generator writes under `Tests/Fixtures/contract/`, and its key.
public enum ContractFixture {
    /// `Tests/Fixtures/contract`, found from this file's place in the package.
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/contract", isDirectory: true)

    /// The test-only key pair the contract manifest is signed with. It signs nothing real.
    public static func testKey() throws -> (privateKey: Curve25519.Signing.PrivateKey, publicText: String) {
        let data = try Data(contentsOf: directory.appendingPathComponent("test-key.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var secret = (json["secret"] as! String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        secret += String(repeating: "=", count: (4 - secret.count % 4) % 4)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: secret)!)
        return (key, json["public"] as! String)
    }

    /// Relative path (as the channel serves it) -> bytes, for the checked-in contract release.
    public static func served() throws -> [String: Data] {
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        var served = ["manifest.json": manifest]
        for locale in ["de", "en", "zh-Hans"] {
            served["r/rel_swiftfixture0001/localizable/\(locale).json"] = try Data(
                contentsOf: directory.appendingPathComponent("localizable/\(locale).json"))
        }
        return served
    }
}
