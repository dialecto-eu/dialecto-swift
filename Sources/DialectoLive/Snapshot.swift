import Foundation
import os

/// The live text the app answers from: an immutable copy, swapped whole when a release lands, so a
/// lookup from any thread sees one release and never a half-applied one.
package struct LiveSnapshot: Sendable {
    /// catalog name -> locale -> key -> text
    package var catalogs: [String: [String: [String: String]]] = [:]
    /// The catalog locales to read, best first (`zh-Hans`, then `zh`).
    package var chain: [String] = []

    static let empty = LiveSnapshot()

    package init(catalogs: [String: [String: [String: String]]] = [:], chain: [String] = []) {
        self.catalogs = catalogs
        self.chain = chain
    }

    /// The live text for `key`. A table matches a catalog by its slug, or by a trailing `-slug` (a
    /// catalog in a folder is named by its path). `table` nil is `Localizable`; with `anyTable`, a
    /// nil table also falls back to the other catalogs.
    func value(key: String, table: String?, anyTable: Bool = false) -> String? {
        lookup(key: key, table: table, anyTable: anyTable)?.text
    }

    /// Like `value`, with the catalog and language the text came from.
    package func lookup(key: String, table: String?, anyTable: Bool = false) -> LookupMatch? {
        guard !catalogs.isEmpty, !chain.isEmpty else { return nil }
        let wanted = Self.slug(table.flatMap { $0.isEmpty ? nil : $0 } ?? "Localizable")
        let names = catalogs.keys.sorted()
        let matching = names.filter { $0 == wanted || $0.hasSuffix("-" + wanted) }
        let order = anyTable && (table ?? "").isEmpty ? matching + names.filter { !matching.contains($0) } : matching

        for locale in chain {
            for name in order {
                if let text = catalogs[name]?[locale]?[key] { return LookupMatch(catalog: name, locale: locale, text: text) }
            }
        }
        return nil
    }

    /// A table or file name as the release writes its catalog name: lowercase `[a-z0-9._-]`,
    /// never starting with a dot or a dash (the same rule the Dialecto server applies).
    static func slug(_ name: String) -> String {
        var slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "^[.-]+", with: "", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["", ".", ".."].contains(slug) ? "catalog" : slug
    }
}

/// The one snapshot in use. Reads come from any thread (the Bundle hook), so it sits behind a lock.
enum LiveState {
    static let snapshot = OSAllocatedUnfairLock(initialState: LiveSnapshot.empty)

    static func current() -> LiveSnapshot { snapshot.withLock { $0 } }
    static func replace(_ next: LiveSnapshot) { snapshot.withLock { $0 = next } }
}
