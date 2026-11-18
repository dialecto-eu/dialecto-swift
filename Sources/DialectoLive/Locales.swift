import Foundation

/// Matches the app's language to the catalog's locale names. The catalog writes `zh-Hans` and `pt-BR`;
/// the system says `zh-Hans-DE` and `pt_BR`.
package enum LocaleMatching {
    /// The catalog's locales to read for `language`, best first: the full tag, then each shorter one
    /// (`zh-Hans-DE`, `zh-Hans`, `zh`), spelled as the catalog spells them. Empty when none is there.
    package static func chain(for language: String, available: [String]) -> [String] {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return [] }
        let byLowercase = Dictionary(available.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var chain: [String] = []
        for length in stride(from: parts.count, through: 1, by: -1) {
            let tag = parts.prefix(length).joined(separator: "-").lowercased()
            if let name = byLowercase[tag], !chain.contains(name) { chain.append(name) }
        }
        return chain
    }

    /// The language the app shows now: the first the main bundle resolved, else the first preferred one.
    package static func currentLanguage() -> String? {
        Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first
    }
}
