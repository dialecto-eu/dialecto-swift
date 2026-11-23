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

        @Test func aLabelAndTheSegmentBesideItAreTwoKeysNotOne() {
            let log = LookupLog()
            record(log, "calm.note", "Intense effects are off in calm mode")
            record(log, "calm.segment.intense", "Intense")
            #expect(log.reverse("Intense effects are off in calm mode").map(\.key) == ["calm.note"])
            #expect(log.reverse("Intense").map(\.key) == ["calm.segment.intense"])
            // A container label that joins both is the only text that finds both.
            #expect(log.reverse("Intense, Intense effects are off in calm mode").map(\.key).sorted() == ["calm.note", "calm.segment.intense"])
        }

        @Test func aLabelWithAnIconAfterItIsOneKey() {
            let log = LookupLog()
            record(log, "calm.note", "Intense effects are off in calm mode")
            record(log, "calm.segment.intense", "Intense")
            // What SwiftUI reports for `Text(...) + Text(Image(systemName: "info.circle"))`, in its usual forms.
            for shown in [
                "Intense effects are off in calm mode \u{FFFC}",
                "Intense effects are off in calm mode \u{100184}",
                "Intense effects are off in calm mode Info",
                "Intense effects are off in calm mode, info.circle",
            ] {
                #expect(log.reverse(shown).map(\.key) == ["calm.note"], "\(shown)")
            }
        }

        @Test func aStringSeenOutsideTheLongerOneIsStillItsOwnKey() {
            let log = LookupLog()
            record(log, "calm.note", "Intense effects are off in calm mode")
            record(log, "calm.segment.intense", "Intense")
            record(log, "calm.segment.calm", "Calm")
            #expect(
                log.reverse("Intense Calm Intense effects are off in calm mode Info").map(\.key).sorted()
                    == ["calm.note", "calm.segment.calm", "calm.segment.intense"])
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
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        import AppKit

        struct MacHitRefineTests {
            private let note = MacHitTest.Hit(
                text: "Intense effects are off in calm mode", frame: NSRect(x: 0, y: 0, width: 200, height: 20))
            private let group = MacHitTest.Hit(
                text: "Intense, Intense effects are off in calm mode", frame: NSRect(x: 0, y: 0, width: 200, height: 60))

            @Test func aGroupLabelGivesWayToTheTextUnderThePointer() {
                let hit = MacHitTest.refined(group, by: note, at: NSPoint(x: 10, y: 10))
                #expect(hit?.text == "Intense effects are off in calm mode")
            }

            @Test func aReadWhoseFrameMissesThePointerGivesWayToo() {
                let segment = MacHitTest.Hit(text: "Intense", frame: NSRect(x: 0, y: 30, width: 200, height: 20))
                let hit = MacHitTest.refined(segment, by: note, at: NSPoint(x: 10, y: 10))
                #expect(hit?.text == "Intense effects are off in calm mode")
            }

            @Test func aReadThatIsAlreadyTheSmallestStays() {
                #expect(MacHitTest.refined(note, by: group, at: NSPoint(x: 10, y: 10))?.text == note.text)
            }
        }
    #endif
#endif
