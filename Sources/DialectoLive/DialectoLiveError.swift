import Foundation

/// What `onError` receives. `code` says what went wrong. Nothing here is ever thrown into the app:
/// the strings it already shows stay as they are.
public struct DialectoLiveError: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case config
        case network
        case httpStatus = "http_status"
        case badJSON = "bad_json"
        case badManifest = "bad_manifest"
        case unknownKey = "unknown_key"
        case badSignature = "bad_signature"
        case badHash = "bad_hash"
        case badFile = "bad_file"
        case storage
    }

    public let code: Code
    public let message: String

    public var description: String { "DialectoLiveError(\(code.rawValue)): \(message)" }

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}
