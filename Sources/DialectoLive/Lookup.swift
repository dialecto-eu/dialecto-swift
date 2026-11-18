import Foundation
import os

/// Where a shown string came from.
package enum LookupSource: String, Sendable {
    case draft, live, bundle
}

/// A string a draft or a release answers with, and the catalog and language it was read from.
package struct LookupMatch: Sendable, Equatable {
    package var catalog: String
    package var locale: String
    package var text: String

    package init(catalog: String, locale: String, text: String) {
        self.catalog = catalog
        self.locale = locale
        self.text = text
    }
}

/// One lookup as the debug session logs it.
package struct LookupRecord: Sendable, Equatable {
    package var catalog: String
    package var key: String
    package var locale: String
    /// The text the lookup returned, which is the format string when the caller formats it afterwards.
    package var format: String
    package var text: String
    package var source: LookupSource

    package init(catalog: String, key: String, locale: String, format: String, text: String, source: LookupSource) {
        self.catalog = catalog
        self.key = key
        self.locale = locale
        self.format = format
        self.text = text
        self.source = source
    }
}

/// The one hook a debug session fills: a draft layer above the release and a log of every lookup. It is
/// nil unless the separate debug-only product sets it, so in a release build nothing changes.
package struct LookupHook: Sendable {
    /// The draft text for a key, or nil.
    package var draft: @Sendable (_ key: String, _ table: String?, _ anyTable: Bool) -> LookupMatch?
    /// A draft the placeholder guard refused (`source` is `.draft`).
    package var refused: @Sendable (LookupRecord) -> Void
    /// A string a lookup returned.
    package var record: @Sendable (LookupRecord) -> Void

    package init(
        draft: @escaping @Sendable (String, String?, Bool) -> LookupMatch?,
        refused: @escaping @Sendable (LookupRecord) -> Void,
        record: @escaping @Sendable (LookupRecord) -> Void
    ) {
        self.draft = draft
        self.refused = refused
        self.record = record
    }
}

package enum LookupHooks {
    private static let slot = OSAllocatedUnfairLock<LookupHook?>(initialState: nil)

    package static var current: LookupHook? {
        get { slot.withLock { $0 } }
        set { slot.withLock { $0 = newValue } }
    }
}

/// The one function every lookup path calls: draft, then the live release, then (nil) the bundle.
enum Lookup {
    /// The text to show, or nil to let the bundle answer. `reference` is the text the app itself has for
    /// the key (read at most once); a draft or release text whose printf tokens differ from it is refused.
    static func resolve(
        key: String, table: String?, anyTable: Bool, reference: () -> String?
    ) -> String? {
        let hook = LookupHooks.current
        var read = false
        var bundled: String?
        func appText() -> String? {
            if !read {
                bundled = reference()
                read = true
            }
            return bundled
        }

        if let hook, let draft = hook.draft(key, table, anyTable) {
            let record = LookupRecord(
                catalog: draft.catalog, key: key, locale: draft.locale, format: draft.text, text: draft.text,
                source: .draft)
            if accepts(draft.text, reference: appText()) {
                hook.record(record)
                return draft.text
            }
            hook.refused(record)
        }
        if let live = LiveState.current().lookup(key: key, table: table, anyTable: anyTable),
            accepts(live.text, reference: appText())
        {
            if let hook {
                hook.record(
                    LookupRecord(
                        catalog: live.catalog, key: key, locale: live.locale, format: live.text, text: live.text,
                        source: .live))
            }
            return live.text
        }
        return nil
    }

    /// Logs what the bundle (or the caller's default) answered, when a debug session is listening.
    static func noteBundle(key: String, table: String?, text: String) {
        guard let hook = LookupHooks.current else { return }
        hook.record(
            LookupRecord(
                catalog: LiveSnapshot.slug(table.flatMap { $0.isEmpty ? nil : $0 } ?? "Localizable"), key: key,
                locale: LocaleMatching.currentLanguage() ?? "", format: text, text: text, source: .bundle))
    }

    /// A text whose printf tokens differ from the app's own is dropped. With nothing to compare against,
    /// only text that takes no arguments is safe to show.
    static func accepts(_ text: String, reference: String?) -> Bool {
        guard let reference else { return PrintfPlaceholders.arguments(in: text).isEmpty }
        return PrintfPlaceholders.same(reference, text)
    }
}
