import CryptoKit
import Foundation

/// What one check came to.
enum CheckOutcome: Equatable, Sendable {
    case applied
    case unchanged
    /// The manifest's `sequence` is not above the one held.
    case stale
    /// The release was committed before the app was built.
    case olderThanBuild
    /// An error went to `onError`; the current strings stay.
    case failed
}

struct LoadedFile: Sendable {
    let catalog: String
    let locale: String
    let sha256: String
    let data: Data
    let values: [String: String]
}

/// A verified release held in memory.
struct HeldRelease: Sendable {
    let manifest: Data
    let payload: ReleasePayload
    var etag: String?
    var files: [String: LoadedFile]
}

/// Fetches, verifies and applies releases. It runs off the main actor;
/// the only thing it touches there is the revision counter that redraws SwiftUI.
actor LiveClient {
    private let config: LiveConfiguration
    private let cache: LiveCache
    private var held: HeldRelease?
    private var inflight: Task<CheckOutcome, Never>?
    private var again = false

    init(config: LiveConfiguration, held: HeldRelease?) {
        self.config = config
        self.cache = LiveCache(root: config.cacheRoot, channel: config.channel)
        self.held = held
    }

    // MARK: Cache at start

    /// The cached release, if it still verifies against the app's keys and is not older than the build.
    /// Synchronous: the first frame shows live text, with no flash from bundled to live.
    static func loadCache(config: LiveConfiguration) -> HeldRelease? {
        let cache = LiveCache(root: config.cacheRoot, channel: config.channel)
        guard let manifest = cache.readManifest() else { return nil }
        do {
            let payload = try parse(manifest: manifest, config: config)
            if try olderThanBuild(payload, config: config) { return nil }
            var files: [String: LoadedFile] = [:]
            for entry in payload.entries {
                // A payload the cache lacks or that no longer matches its hash is skipped; a check fetches it.
                guard let data = cache.readPayload(sha256: entry.sha256), sha256Hex(data) == entry.sha256,
                    let values = try? parseFile(data)
                else { continue }
                files[entry.fileKey] = LoadedFile(
                    catalog: entry.catalog, locale: entry.locale, sha256: entry.sha256, data: data, values: values)
            }
            return HeldRelease(manifest: manifest, payload: payload, etag: cache.readEtag(), files: files)
        } catch let error as DialectoLiveError {
            config.report(error)
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Check

    /// Looks for a newer release and applies it. Calls that overlap run once more after the one in
    /// flight, never in parallel.
    @discardableResult
    func check() async -> CheckOutcome {
        if let inflight {
            again = true
            return await inflight.value
        }
        let task = Task { await self.checkUntilQuiet() }
        inflight = task
        let outcome = await task.value
        inflight = nil
        return outcome
    }

    private func checkUntilQuiet() async -> CheckOutcome {
        var outcome = CheckOutcome.failed
        repeat {
            again = false
            do {
                outcome = try await checkOnce()
            } catch let error as DialectoLiveError {
                config.report(error)
                outcome = .failed
            } catch {
                config.report(.init(.network, "Could not check for a release: \(error.localizedDescription)"))
                outcome = .failed
            }
        } while again
        return outcome
    }

    private func checkOnce() async throws -> CheckOutcome {
        let wanted = wantedLocales(in: held?.payload)
        var headers = ["Accept": "application/json"]
        if let held, let etag = held.etag, wanted.allSatisfy({ locale in held.files.values.contains { $0.locale == locale } }) {
            headers["If-None-Match"] = etag
        }

        let manifestURL = try url(for: "manifest.json")
        let (status, body, etag) = try await fetch(manifestURL, headers: headers)
        if status == 304 { return .unchanged }
        guard (200..<300).contains(status) else {
            throw DialectoLiveError(.httpStatus, "The manifest answered \(status)")
        }
        guard body.count <= 2_000_000, !body.isEmpty else {
            throw DialectoLiveError(.badManifest, "The manifest is empty or too large")
        }

        let payload = try Self.parse(manifest: body, config: config)
        if let current = held?.payload {
            if payload.sequence < current.sequence { return .stale }
            if payload.sequence == current.sequence && payload.release != current.release { return .stale }
        }
        if try Self.olderThanBuild(payload, config: config) { return .olderThanBuild }

        let locales = wantedLocales(in: payload)
        var files: [String: LoadedFile] = [:]
        for entry in payload.entries {
            if let prior = held?.files[entry.fileKey], prior.sha256 == entry.sha256 {
                files[entry.fileKey] = prior
                continue
            }
            guard locales.contains(entry.locale) else { continue }
            files[entry.fileKey] = try await download(entry)
        }

        let next = HeldRelease(manifest: body, payload: payload, etag: etag, files: files)
        do {
            let cache = self.cache
            try cache.write(
                manifest: body, etag: etag, payloads: Dictionary(files.values.map { ($0.sha256, $0.data) }, uniquingKeysWith: { first, _ in first }))
        } catch {
            config.report(.init(.storage, "Could not store the release: \(error.localizedDescription)"))
        }
        await apply(next)
        return .applied
    }

    /// The catalog locales the app needs: its current language and the shorter forms of it.
    private func wantedLocales(in payload: ReleasePayload?) -> [String] {
        guard let payload, let language = config.language() else { return [] }
        return LocaleMatching.chain(for: language, available: Array(Set(payload.entries.map(\.locale))))
    }

    private func apply(_ release: HeldRelease) async {
        held = release
        LiveState.replace(Self.snapshot(of: release, config: config))
        await MainActor.run { LiveStore.shared.bump() }
    }

    static func snapshot(of release: HeldRelease, config: LiveConfiguration) -> LiveSnapshot {
        let locales = Array(Set(release.payload.entries.map(\.locale)))
        let chain = config.language().map { LocaleMatching.chain(for: $0, available: locales) } ?? []
        var snapshot = LiveSnapshot(chain: chain)
        for file in release.files.values where chain.contains(file.locale) {
            snapshot.catalogs[file.catalog, default: [:]][file.locale] = file.values
        }
        return snapshot
    }

    // MARK: Manifest and files

    static func parse(manifest bytes: Data, config: LiveConfiguration) throws -> ReleasePayload {
        let envelope: ManifestVerifier.Envelope
        do {
            envelope = try JSONDecoder().decode(ManifestVerifier.Envelope.self, from: bytes)
        } catch {
            throw DialectoLiveError(.badJSON, "The manifest is not JSON of the expected shape")
        }
        guard envelope.format == 1 else { throw DialectoLiveError(.badManifest, "The manifest has an unexpected format") }
        let signed = try ManifestVerifier.verify(envelope, keys: config.keys).get()
        let payload: ReleasePayload
        do {
            payload = try JSONDecoder().decode(ReleasePayload.self, from: signed)
        } catch {
            throw DialectoLiveError(.badManifest, "The signed payload has an unexpected shape")
        }
        // A release signed for another channel of the same repo must not be served as this one.
        // Both the network and the cache come through here.
        guard payload.channel == config.channel else {
            throw DialectoLiveError(.badManifest, "The signed payload is for another channel")
        }
        return payload
    }

    static func olderThanBuild(_ payload: ReleasePayload, config: LiveConfiguration) throws -> Bool {
        guard let builtAt = config.builtAt else { return false }
        guard let committed = payload.committedDate else {
            throw DialectoLiveError(.badManifest, "committed_at is not a time")
        }
        return committed < builtAt
    }

    /// A payload: a flat JSON object of text. Anything that is not text is skipped.
    static func parseFile(_ data: Data) throws -> [String: String] {
        guard String(data: data, encoding: .utf8) != nil else {
            throw DialectoLiveError(.badFile, "A catalog file is not UTF-8")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DialectoLiveError(.badFile, "A catalog file is not a JSON object")
        }
        return object.compactMapValues { $0 as? String }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func download(_ entry: ReleasePayload.Entry) async throws -> LoadedFile {
        let (status, data, _) = try await fetch(url(for: entry.url), headers: [:])
        guard (200..<300).contains(status) else {
            throw DialectoLiveError(.httpStatus, "Fetching \(entry.url) answered \(status)")
        }
        guard data.count <= ReleasePayload.Entry.maxBytes else {
            throw DialectoLiveError(.badFile, "\(entry.url) is too large")
        }
        guard Self.sha256Hex(data) == entry.sha256 else {
            throw DialectoLiveError(.badHash, "\(entry.url) does not match its sha256")
        }
        return LoadedFile(
            catalog: entry.catalog, locale: entry.locale, sha256: entry.sha256, data: data,
            values: try Self.parseFile(data))
    }

    /// `<base><channel>/<relative>`; a relative path that could leave the channel is refused.
    private func url(for relative: String) throws -> URL {
        if relative.range(of: #"^[a-z][a-z0-9+.-]*:|^[/\\]|\\|(^|/)\.\.(/|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw DialectoLiveError(.badManifest, "Unsafe file url \(relative)")
        }
        guard let url = URL(string: relative, relativeTo: channelURL)?.absoluteURL else {
            throw DialectoLiveError(.badManifest, "Unusable file url \(relative)")
        }
        return url
    }

    private var channelURL: URL {
        config.baseURL.appendingPathComponent(config.channel, isDirectory: true)
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> (Int, Data, String?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await config.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                // A folder served as file:// (the demo) has no status.
                return (url.isFileURL ? 200 : 0, data, nil)
            }
            return (http.statusCode, data, http.value(forHTTPHeaderField: "ETag"))
        } catch {
            throw DialectoLiveError(.network, "Could not fetch \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
