#if DEBUG
    import Foundation
    import Testing

    @testable import DialectoLive
    @testable import DialectoLiveEditing

    @MainActor
    struct PanelModelTests {
        private func record(_ log: LookupLog, _ catalog: String, _ key: String, _ locale: String, _ text: String) {
            log.record(LookupRecord(catalog: catalog, key: key, locale: locale, format: text, text: text, source: .bundle))
        }

        /// A bundle lookup knows only its table (`localizable`); the release names a catalog in a folder by its
        /// path (`e2eapp-localizable`). Both are one catalog, so the key gets one row.
        @Test func aKeyLookedUpUnderTwoNamesOfOneCatalogHasOneRow() {
            let log = LookupLog()
            record(log, "localizable", "export.button", "en", "Export")
            record(log, "e2eapp-localizable", "export.button", "de", "Jetzt exportieren")
            let model = PanelModel(log: log, layer: DraftLayer(language: { "de" }))
            model.refresh()
            #expect(model.rows.map(\.key) == ["export.button"])
            #expect(model.rows.first?.text == "Jetzt exportieren")
            #expect(model.rows.first?.catalog == "e2eapp-localizable")
            #expect(model.severalCatalogs == false)
        }

        @Test func twoCatalogsKeepTheirOwnRows() {
            let log = LookupLog()
            record(log, "localizable", "title", "en", "Title")
            record(log, "settings", "title", "en", "Settings")
            let model = PanelModel(log: log, layer: DraftLayer(language: { "en" }))
            model.refresh()
            #expect(model.rows.count == 2)
            #expect(model.severalCatalogs)
        }

        /// A draft the server skipped joins its key's row when it is in the app's language, whatever language
        /// the shown text came from.
        @Test func aSkippedDraftJoinsItsKeysRow() {
            let log = LookupLog()
            record(log, "localizable", "greeting.name", "en", "Hello, %@!")
            let layer = DraftLayer(language: { "de" })
            layer.replace(rows: [DraftRow(catalog: "e2eapp-localizable", key: "greeting.name", locale: "de", skipped: "placeholders")])
            let model = PanelModel(log: log, layer: layer)
            model.refresh()
            #expect(model.rows.count == 1)
            #expect(model.rows.first?.notShown == notShownReason("placeholders"))
        }

        @Test func aSkippedDraftInAnotherLanguageHasItsOwnRow() {
            let log = LookupLog()
            record(log, "localizable", "greeting.name", "en", "Hello, %@!")
            let layer = DraftLayer(language: { "en" })
            layer.replace(rows: [DraftRow(catalog: "localizable", key: "greeting.name", locale: "fr", skipped: "plural")])
            let model = PanelModel(log: log, layer: layer)
            model.refresh()
            #expect(model.rows.count == 2)
            #expect(model.rows.first?.notShown == notShownReason("plural"))
            #expect(model.rows.last?.notShown == nil)
        }

        @Test func aClickOnTextThatIsNotDialectosLeavesOnlyANote() {
            let model = PanelModel(log: LookupLog(), layer: DraftLayer(language: { "en" }))
            model.noKey(for: "Build 42")
            #expect(model.noKeyText == "Build 42")
            model.noKey(for: String(repeating: "x", count: 60))
            #expect(model.noKeyText?.count == 40)
        }
    }
#endif
