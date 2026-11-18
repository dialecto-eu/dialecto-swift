import Foundation

/// The last verified release on disk, so the app shows live text offline after a restart:
/// `<root>/<channel>/manifest.json` (the bytes as served), `etag`, and `p-<sha256>.json` per payload.
/// Everything read back is verified again by the caller; the cache is never trusted.
struct LiveCache: Sendable {
    let directory: URL

    /// `~/Library/Application Support/Dialecto/Live` (inside the container for a sandboxed app).
    static func defaultRoot() -> URL {
        let support =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Dialecto", isDirectory: true).appendingPathComponent("Live", isDirectory: true)
    }

    init(root: URL, channel: String) {
        directory = root.appendingPathComponent(channel, isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var etagURL: URL { directory.appendingPathComponent("etag") }
    private func payloadURL(_ sha256: String) -> URL { directory.appendingPathComponent("p-\(sha256).json") }

    func readManifest() -> Data? { try? Data(contentsOf: manifestURL) }
    func readEtag() -> String? { (try? String(contentsOf: etagURL, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } }
    func readPayload(sha256: String) -> Data? { try? Data(contentsOf: payloadURL(sha256)) }

    /// Writes the release whole; each file lands by atomic replace. Payloads no longer referenced go.
    func write(manifest: Data, etag: String?, payloads: [String: Data]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (sha256, data) in payloads { try data.write(to: payloadURL(sha256), options: .atomic) }
        try manifest.write(to: manifestURL, options: .atomic)
        if let etag { try Data(etag.utf8).write(to: etagURL, options: .atomic) } else { try? FileManager.default.removeItem(at: etagURL) }

        let keep = Set(payloads.keys.map { "p-\($0).json" })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("p-") && name.hasSuffix(".json") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
