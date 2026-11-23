#if DEBUG
    import DialectoLive
    import Foundation
    import os

    /// A string the app asked for since launch, once per catalog, key and language.
    struct LookupEntry: Sendable, Equatable, Identifiable {
        var catalog: String
        var key: String
        var locale: String
        var format: String
        var text: String
        var source: LookupSource
        /// Order of the latest lookup; the panel lists the highest first.
        var seen: Int
        var count: Int

        var id: String { "\(catalog)\u{0}\(key)\u{0}\(locale)" }
    }

    /// What the debug session saw the app look up. Written from any thread, by the lookup hook.
    final class LookupLog: Sendable {
        private struct State {
            var entries: [String: LookupEntry] = [:]
            var counter = 0
        }

        static let limit = 5000
        private let state = OSAllocatedUnfairLock(initialState: State())

        func record(_ record: LookupRecord) {
            state.withLock { state in
                state.counter += 1
                let probe = LookupEntry(
                    catalog: record.catalog, key: record.key, locale: record.locale, format: record.format,
                    text: record.text, source: record.source, seen: state.counter, count: 1)
                if var held = state.entries[probe.id] {
                    held.format = record.format
                    held.text = record.text
                    held.source = record.source
                    held.seen = state.counter
                    held.count += 1
                    state.entries[probe.id] = held
                } else {
                    if state.entries.count >= Self.limit, let oldest = state.entries.min(by: { $0.value.seen < $1.value.seen }) {
                        state.entries[oldest.key] = nil
                    }
                    state.entries[probe.id] = probe
                }
            }
        }

        /// Newest first.
        func entries() -> [LookupEntry] {
            state.withLock { Array($0.entries.values) }.sorted { $0.seen > $1.seen }
        }

        func removeAll() { state.withLock { $0 = State() } }

        /// The entries a piece of on-screen text could be (see `ReverseLookup`).
        func reverse(_ text: String) -> [LookupEntry] {
            ReverseLookup.find(text, in: entries())
        }
    }

    /// Text to key: an exact match first, then each format string turned into a pattern for
    /// interpolated text, then substring matches for a label that merges several strings.
    enum ReverseLookup {
        static func find(_ shown: String, in entries: [LookupEntry]) -> [LookupEntry] {
            let wanted = normalize(shown)
            guard !wanted.isEmpty else { return [] }

            let exact = entries.filter { normalize($0.text) == wanted }
            if !exact.isEmpty { return exact }

            let interpolated = entries.filter { entry in
                guard hasPlaceholders(entry.format), let pattern = pattern(for: entry.format) else { return false }
                return wanted.range(of: pattern, options: .regularExpression) != nil
            }
            if !interpolated.isEmpty { return interpolated }

            let contained = entries.filter { entry in
                let text = normalize(entry.text)
                return text.count >= 2 && wanted.contains(text)
            }
            return contained.filter { entry in standsAlone(normalize(entry.text), in: wanted, among: contained) }
        }

        /// A string found only inside a longer match is part of that string, not a second one: a label with an
        /// icon after it ("Intense effects are off in calm mode Info") is one key, though "Intense" is in it.
        /// A label that joins two strings ("Intense, Intense effects …") still finds both.
        private static func standsAlone(_ text: String, in wanted: String, among matches: [LookupEntry]) -> Bool {
            let longer = matches.map { normalize($0.text) }.filter { $0.count > text.count && $0.contains(text) }
            guard !longer.isEmpty else { return true }
            let covering = longer.flatMap { ranges(of: $0, in: wanted) }
            return ranges(of: text, in: wanted).contains { range in
                !covering.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
            }
        }

        private static func ranges(of text: String, in wanted: String) -> [Range<String.Index>] {
            var found: [Range<String.Index>] = []
            var start = wanted.startIndex
            while start < wanted.endIndex, let range = wanted.range(of: text, range: start..<wanted.endIndex) {
                found.append(range)
                start = wanted.index(after: range.lowerBound)
            }
            return found
        }

        /// Collapses whitespace so a wrapped or padded label still matches, and drops what an inline image or
        /// SF Symbol adds to a label's text (the attachment character and private-use symbol glyphs).
        static func normalize(_ text: String) -> String {
            let kept = String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    scalar != "\u{FFFC}" && scalar.properties.generalCategory != .privateUse
                })
            return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static let token = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ #0']*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp%])"#)

        static func hasPlaceholders(_ format: String) -> Bool {
            let whole = NSRange(format.startIndex..., in: format)
            return token.matches(in: format, range: whole).contains { match in
                Range(match.range(at: 1), in: format).map { format[$0] != "%" } ?? false
            }
        }

        /// `Hello, %@! 100%% ready.` becomes `^Hello, .+?! 100% ready\.$`, matched after whitespace is collapsed.
        static func pattern(for format: String) -> String? {
            let format = normalize(format)
            let whole = NSRange(format.startIndex..., in: format)
            var pattern = "^"
            var literal = 0
            var cursor = format.startIndex
            for match in token.matches(in: format, range: whole) {
                guard let range = Range(match.range, in: format), let conversion = Range(match.range(at: 1), in: format)
                else { continue }
                let before = String(format[cursor..<range.lowerBound])
                literal += before.trimmingCharacters(in: .whitespaces).count
                pattern += NSRegularExpression.escapedPattern(for: before)
                pattern += format[conversion] == "%" ? "%" : ".+?"
                cursor = range.upperBound
            }
            let rest = String(format[cursor...])
            literal += rest.trimmingCharacters(in: .whitespaces).count
            // A format that is almost all wildcard (`%@`) would match every string on screen.
            guard literal >= 3 else { return nil }
            pattern += NSRegularExpression.escapedPattern(for: rest) + "$"
            return pattern
        }
    }
#endif
