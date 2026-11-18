#if DEBUG
    import DialectoLive
    import Foundation
    import os

    /// The drafts the signed-in person has staged, as the lookup hook answers from them. Replaced whole
    /// on each feed answer.
    final class DraftLayer: Sendable {
        struct State: Sendable {
            var rows: [DraftRow] = []
            var snapshot = LiveSnapshot()
            /// Rows the server could not show, and drafts the app's placeholder guard refused.
            var notShown: [NotShown] = []
        }

        struct NotShown: Sendable, Equatable {
            var catalog: String
            var key: String
            var locale: String
            var reason: String
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let language: @Sendable () -> String?
        private let refusals = OSAllocatedUnfairLock<[NotShown]>(initialState: [])

        init(language: @escaping @Sendable () -> String? = { LocaleMatching.currentLanguage() }) {
            self.language = language
        }

        /// Replaces the draft layer with the feed's rows.
        func replace(rows: [DraftRow]) {
            let snapshot = Self.snapshot(of: rows, language: language())
            let skipped = rows.compactMap { row in
                row.skipped.map { NotShown(catalog: row.catalog, key: row.key, locale: row.locale, reason: $0) }
            }
            state.withLock {
                $0.rows = rows
                $0.snapshot = snapshot
                $0.notShown = skipped
            }
            refusals.withLock { $0 = [] }
        }

        func clear() {
            state.withLock { $0 = State() }
            refusals.withLock { $0 = [] }
        }

        /// The language changed: read the rows again for it.
        func relanguage() {
            let rows = state.withLock { $0.rows }
            let snapshot = Self.snapshot(of: rows, language: language())
            state.withLock { $0.snapshot = snapshot }
        }

        /// Every draft with a reason it is not on screen: the server's skips and the guard's refusals.
        var notShown: [NotShown] { state.withLock { $0.notShown } + refusals.withLock { $0 } }

        var draftCount: Int { state.withLock { $0.rows.filter { $0.text != nil }.count } }

        /// The language drafts are read for now.
        var currentLanguage: String? { language() }

        func match(key: String, table: String?, anyTable: Bool) -> LookupMatch? {
            state.withLock { $0.snapshot }.lookup(key: key, table: table, anyTable: anyTable)
        }

        func refuse(_ record: LookupRecord) {
            let item = NotShown(catalog: record.catalog, key: record.key, locale: record.locale, reason: "placeholders")
            refusals.withLock { if !$0.contains(item) { $0.append(item) } }
        }

        static func snapshot(of rows: [DraftRow], language: String?) -> LiveSnapshot {
            let shown = rows.filter { $0.text != nil }
            let locales = Array(Set(shown.map(\.locale)))
            let chain = language.map { LocaleMatching.chain(for: $0, available: locales) } ?? []
            var snapshot = LiveSnapshot(chain: chain)
            for row in shown where chain.contains(row.locale) {
                if let text = row.text { snapshot.catalogs[row.catalog, default: [:]][row.locale, default: [:]][row.key] = text }
            }
            return snapshot
        }
    }
#endif
