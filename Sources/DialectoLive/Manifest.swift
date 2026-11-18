import Foundation

/// The signed payload of a manifest, decoded from the verified bytes.
struct ReleasePayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let catalog: String
        let locale: String
        let format: String
        let url: String
        let sha256: String
        let bytes: Int
    }

    let channel: String
    let sequence: Int
    let release: String
    let committedAt: String
    /// Entries this client can use; a malformed one is skipped, not fatal.
    let entries: [Entry]

    private enum CodingKeys: String, CodingKey {
        case channel, sequence, release, files
        case committedAt = "committed_at"
    }

    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try container.decode(String.self, forKey: .channel)
        sequence = try container.decode(Int.self, forKey: .sequence)
        release = try container.decode(String.self, forKey: .release)
        committedAt = try container.decode(String.self, forKey: .committedAt)
        entries = try container.decode([Lossy].self, forKey: .files).compactMap(\.entry).filter(\.isUsable)
    }

    /// The time the release's commit was made, or nil when `committed_at` is not a time.
    var committedDate: Date? { ISO8601.date(committedAt) }
}

extension ReleasePayload.Entry {
    static let maxBytes = 8_000_000

    /// Only String Catalog payloads, with a safe catalog name, a locale tag and a sha256.
    var isUsable: Bool {
        format == "xcstrings" && matches(catalog, #"^[A-Za-z0-9_-][A-Za-z0-9._-]*$"#)
            && matches(locale, #"^[A-Za-z0-9][A-Za-z0-9_@.-]{0,34}$"#) && matches(sha256, #"^[0-9a-f]{64}$"#)
            && bytes >= 0 && bytes <= Self.maxBytes
    }

    /// The key a downloaded payload is kept under.
    var fileKey: String { "\(catalog)\u{0}\(locale)" }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ISO8601 {
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
