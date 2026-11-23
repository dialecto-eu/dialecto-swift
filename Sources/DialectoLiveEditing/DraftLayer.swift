#if DEBUG
    import DialectoLive
    import Foundation
    import os

    /// The drafts the signed-in person has staged, as the lookup hook answers from them. Replaced whole
    /// on each feed answer.
    final class DraftLayer: Sendable {
        struct State: Sendable {
            var rows: [DraftRow] = []
            /// Text being typed in the editor, not saved yet: it answers before the saved drafts, so the app
            /// redraws with each keystroke.
            var local: [Cell: String] = [:]
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

        /// One language of one key in one catalog.
        struct Cell: Hashable, Sendable {
            var catalog: String
            var key: String
            var locale: String
        }

        /// Replaces the draft layer with the feed's rows.
        func replace(rows: [DraftRow]) {
            let skipped = rows.compactMap { row in
                row.skipped.map { NotShown(catalog: row.catalog, key: row.key, locale: row.locale, reason: $0) }
            }
            let language = language()
            state.withLock {
                $0.rows = rows
                $0.snapshot = Self.snapshot(of: Self.merged($0.rows, $0.local), language: language)
                $0.notShown = skipped
            }
            refusals.withLock { $0 = [] }
        }

        /// One saved draft, from a save's answer, ahead of the feed's next answer. `text` nil removes the
        /// cell's draft: the text went back to the repository's.
        func upsert(_ cell: Cell, text: String?) {
            let language = language()
            state.withLock {
                $0.rows.removeAll { $0.catalog == cell.catalog && $0.key == cell.key && $0.locale == cell.locale }
                if let text { $0.rows.append(DraftRow(catalog: cell.catalog, key: cell.key, locale: cell.locale, text: text)) }
                $0.snapshot = Self.snapshot(of: Self.merged($0.rows, $0.local), language: language)
            }
        }

        /// The text typed for a cell, shown before it is saved; nil drops it.
        func setLocal(_ text: String?, for cell: Cell) {
            let language = language()
            state.withLock {
                $0.local[cell] = text
                $0.snapshot = Self.snapshot(of: Self.merged($0.rows, $0.local), language: language)
            }
            // A refusal of the typed text is the editor's to show, not the panel's.
            refusals.withLock { $0.removeAll { $0.key == cell.key } }
        }

        func hasLocal(_ cell: Cell) -> Bool { state.withLock { $0.local[cell] != nil } }

        func clear() {
            state.withLock { $0 = State() }
            refusals.withLock { $0 = [] }
        }

        /// The language changed: read the rows again for it.
        func relanguage() {
            let language = language()
            state.withLock { $0.snapshot = Self.snapshot(of: Self.merged($0.rows, $0.local), language: language) }
        }

        /// The saved drafts with text, in feed order.
        var drafts: [DraftRow] { state.withLock { $0.rows.filter { $0.text != nil } } }

        private static func merged(_ rows: [DraftRow], _ local: [Cell: String]) -> [DraftRow] {
            guard !local.isEmpty else { return rows }
            let kept = rows.filter { local[Cell(catalog: $0.catalog, key: $0.key, locale: $0.locale)] == nil }
            return kept
                + local.map { DraftRow(catalog: $0.key.catalog, key: $0.key.key, locale: $0.key.locale, text: $0.value) }
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
