import Foundation

/// base64url without padding, as the manifest and its signatures are written.
enum Base64URL {
    /// The decoded bytes, or nil for anything outside the base64url alphabet (padding included).
    /// Foundation's decoder wants the standard alphabet and padding, so both are put back first.
    static func decode(_ text: String) -> Data? {
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                continue
            default:
                return nil
            }
        }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let missing = (4 - standard.count % 4) % 4
        if missing == 3 { return nil }
        standard += String(repeating: "=", count: missing)
        return Data(base64Encoded: standard)
    }
}
