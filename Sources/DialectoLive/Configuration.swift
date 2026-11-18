import CryptoKit
import Foundation

/// Everything the client needs, fixed at start. Tests replace the session, the cache folder and the
/// language; apps pass only the channel, the keys and `builtAt`.
struct LiveConfiguration: Sendable {
    static let defaultBaseURL = URL(string: "https://cdn.dialecto.eu/v1/")!

    var channel: String
    var keys: [String: Curve25519.Signing.PublicKey]
    var builtAt: Date?
    var baseURL: URL = Self.defaultBaseURL
    var session: URLSession = .shared
    var cacheRoot: URL = LiveCache.defaultRoot()
    var language: @Sendable () -> String? = { LocaleMatching.currentLanguage() }
    var onError: (@Sendable (DialectoLiveError) -> Void)?
    var requestTimeout: TimeInterval = 10

    /// Validates the app's options. Returns the first problem, as the JS client does.
    static func make(
        channel: String, publicKeys: [String], builtAt: String?, baseURL: URL?,
        onError: (@Sendable (DialectoLiveError) -> Void)?
    ) -> Result<LiveConfiguration, DialectoLiveError> {
        guard channel.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            return .failure(.init(.config, "channel must be the channel's public id"))
        }
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for text in publicKeys { if let key = ManifestVerifier.parseKey(text) { keys[text] = key } }
        guard !keys.isEmpty else {
            return .failure(.init(.config, "publicKeys needs at least one valid ed25519 key"))
        }
        var built: Date?
        if let builtAt {
            guard let date = ISO8601.date(builtAt) else {
                return .failure(.init(.config, "builtAt is not a time"))
            }
            built = date
        }
        var config = LiveConfiguration(channel: channel, keys: keys, builtAt: built, onError: onError)
        if let baseURL { config.baseURL = baseURL }
        return .success(config)
    }

    func report(_ error: DialectoLiveError) { onError?(error) }
}
