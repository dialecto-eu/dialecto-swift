#if DEBUG
    import Foundation
    import Testing

    @testable import DialectoLive
    @testable import DialectoLiveEditing

    struct ReverseLookupTests {
        private func record(_ log: LookupLog, _ key: String, _ text: String, source: LookupSource = .bundle) {
            log.record(
                LookupRecord(catalog: "localizable", key: key, locale: "de", format: text, text: text, source: source))
        }

        private func log() -> LookupLog {
            let log = LookupLog()
            record(log, "export.button", "Szenen exportieren")
            record(log, "greeting.name", "Hallo, %@! Alles bereit.")
            record(log, "library.summary", "%2$lld Szenen in %1$@")
            record(log, "any.value", "%@")
            record(log, "save", "Speichern")
            record(log, "save.changes", "Änderungen speichern")
            return log
        }

        @Test func anExactTextFindsItsKey() {
            #expect(log().reverse("Szenen exportieren").map(\.key) == ["export.button"])
            // Wrapped or padded text still matches.
            #expect(log().reverse("  Szenen\nexportieren ").map(\.key) == ["export.button"])
        }

        @Test func anInterpolatedTextFindsItsFormat() {
            #expect(log().reverse("Hallo, Mario! Alles bereit.").map(\.key) == ["greeting.name"])
            #expect(log().reverse("12 Szenen in Studio").map(\.key) == ["library.summary"])
        }

        @Test func aFormatThatIsAllWildcardNeverMatchesEverything() {
            #expect(log().reverse("Something unrelated").isEmpty)
        }

        @Test func aMergedLabelFindsEveryStringInsideIt() {
            // An accessibility label that joins two strings.
            let found = log().reverse("Szenen exportieren, Speichern").map(\.key).sorted()
            #expect(found == ["export.button", "save"])
        }

        @Test func exactBeatsPatternBeatsSubstring() {
            let log = log()
            // "Speichern" is both an exact entry and inside "Änderungen speichern" case-insensitively? No: exact wins alone.
            #expect(log.reverse("Speichern").map(\.key) == ["save"])
        }

        @Test func theLogKeepsOneEntryPerKeyAndTheNewestFirst() {
            let log = log()
            record(log, "export.button", "Jetzt exportieren", source: .draft)
            let entries = log.entries()
            #expect(entries.first?.key == "export.button")
            #expect(entries.first?.text == "Jetzt exportieren")
            #expect(entries.first?.count == 2)
            #expect(entries.filter { $0.key == "export.button" }.count == 1)
            // The old text no longer matches; the shown one does.
            #expect(log.reverse("Szenen exportieren").isEmpty)
            #expect(log.reverse("Jetzt exportieren").map(\.key) == ["export.button"])
        }
    }

    struct DraftLayerTests {
        @Test func rowsReadForTheAppsLanguageWithItsRegion() {
            let rows = [
                DraftRow(catalog: "localizable", key: "a", locale: "de", text: "Allgemein"),
                DraftRow(catalog: "localizable", key: "a", locale: "fr", text: "Général"),
            ]
            let layer = DraftLayer(language: { "de-AT" })
            layer.replace(rows: rows)
            #expect(layer.match(key: "a", table: nil, anyTable: false)?.text == "Allgemein")
            #expect(layer.match(key: "a", table: nil, anyTable: false)?.locale == "de")
        }

        @Test func aNewFeedReplacesTheWholeLayer() {
            let layer = DraftLayer(language: { "de" })
            layer.replace(rows: [DraftRow(catalog: "localizable", key: "a", locale: "de", text: "Eins")])
            layer.replace(rows: [DraftRow(catalog: "localizable", key: "b", locale: "de", text: "Zwei")])
            #expect(layer.match(key: "a", table: nil, anyTable: false) == nil)
            #expect(layer.match(key: "b", table: nil, anyTable: false)?.text == "Zwei")
        }

        @Test func skippedRowsAndRefusalsAreListedAsNotShown() {
            let layer = DraftLayer(language: { "de" })
            layer.replace(rows: [DraftRow(catalog: "localizable", key: "n", locale: "de", skipped: "plural")])
            layer.refuse(
                LookupRecord(catalog: "localizable", key: "p", locale: "de", format: "%lld", text: "%lld", source: .draft))
            #expect(layer.notShown.map(\.reason) == ["plural", "placeholders"])
            #expect(notShownReason("placeholders").contains("placeholders"))
        }

        @Test func aFeedRowDecodesWithATextOrASkipReason() throws {
            let data = Data(
                #"[{"catalog":"c","key":"k","locale":"de","text":"T"},{"catalog":"c","key":"s","locale":"de","skipped":"empty"}]"#
                    .utf8)
            let rows = try JSONDecoder().decode([DraftRow].self, from: data)
            #expect(rows.map(\.text) == ["T", nil])
            #expect(rows.map(\.skipped) == [nil, "empty"])
        }
    }
#endif
