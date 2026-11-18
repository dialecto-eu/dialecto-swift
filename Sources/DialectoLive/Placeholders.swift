import Foundation

/// Apple's printf tokens in a catalog value, ported one for one from the Dialecto server's
/// placeholder check, so the app's guard agrees with the server's check.
///
/// A token is the argument it takes: `N$type`, where `N` is the written position or, for a specifier
/// without one, its place among the string's arguments. `%@ %lld` and `%2$lld %1$@` therefore take the
/// same two arguments. `%%` takes none; `%#@name@` is a substitution.
enum PrintfPlaceholders {
    // Groups: 1 substitution name, 2 position, 3 width, 4 precision, 5 length, 6 conversion, 7 an
    // unparsed sequence: any other `%` with everything up to the next space or `%` (`%*1$d`, `%y`, a
    // lone `%`). It is a token spelled exactly as written, so a live value with one is accepted only
    // against text that has the same sequence byte for byte; otherwise it is refused, never compared.
    private static let specifier = try! NSRegularExpression(
        pattern:
            #"%(?:#@([A-Za-z0-9_]+)@|(?:(\d+)\$)?[-+ #0']*(\*|\d+)?(?:\.(\*|\d+))?(hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp%]))|(%[^\s%]*)"#,
        options: [.dotMatchesLineSeparators]
    )

    /// The arguments `text` takes, in order of first appearance, without repeats.
    static func arguments(in text: String) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        var next = 1
        for match in specifier.matches(in: text, range: whole) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Range(range, in: text).map { String(text[$0]) }
            }
            if let name = group(1) {
                found.append("#@\(name)@")
                continue
            }
            if let bad = group(7) {
                found.append("?\(bad)")
                continue
            }
            let conversion = group(6) ?? ""
            if conversion == "%" { continue }
            // Each `*` (width or precision) takes an argument of its own, before the value's.
            for star in [group(3), group(4)] where star == "*" {
                found.append("\(next)$*")
                next += 1
            }
            let length = group(5) ?? ""
            if let position = group(2), let number = Int(position) {
                found.append("\(number)$\(length)\(conversion)")
            } else {
                found.append("\(next)$\(length)\(conversion)")
                next += 1
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// True when both strings take the same arguments, in any order.
    static func same(_ left: String, _ right: String) -> Bool {
        Set(arguments(in: left)) == Set(arguments(in: right))
    }
}
