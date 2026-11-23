#if DEBUG
    import Foundation
    import Testing

    @testable import DialectoLive
    @testable import DialectoLiveEditing

    /// The floating editor's draft state: the fields it opens with, the local draft each keystroke writes,
    /// and what each answer of a save does to the panel.
    @MainActor
    @Suite(.serialized)
    struct EditorModelTests {
        private static let key = "export.button"
        private static let entriesRoute = "GET /api/live/native/entries?key=export.button"
        private static let editsRoute = "POST /api/live/native/edits"

        private static func saved(_ locale: String, _ text: String) -> StubReply {
            .json(
                200,
                #"{"draft":{"catalog":"app-localizable","key":"export.button","locale":"\#(locale)","text":"\#(text)"},"state":"pending","hash":"h1"}"#
            )
        }

        private struct Setup {
            var stub: StubServer
            var session: DraftSession
            var layer: DraftLayer
            var model: EditorModel
            var closed: () -> Bool
        }

        /// A signed-in session whose feed has nothing new, and an editor on `export.button` with its entries
        /// already read. The app shows `language`.
        private func open(
            language: String = "de", edits: [StubReply] = [],
            entries: StubReply = .json(200, NativeEditsClientTests.entriesBody)
        ) async -> Setup {
            let stub = StubServer([
                "GET /api/live/native/drafts": [.json(304, "")],
                Self.entriesRoute: [entries],
                Self.editsRoute: edits,
            ])
            let store = TokenStore(backend: MemoryBackend())
            store.save(StoredSession(token: "held", expiresAt: Date().addingTimeInterval(3600), projectID: "8"), project: "acme/app")
            let layer = DraftLayer(language: { language })
            let session = DraftSession(
                project: "acme/app", client: stub.client, store: store, layer: layer,
                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, openURL: { _ in })
            session.resume()
            _ = await session.fetchEntries(Self.key)
            let model = EditorModel(
                choices: [.init(key: Self.key, catalog: "localizable", text: "Exportieren")], shownText: "Exportieren",
                isTooltip: false, session: session, layer: layer)
            final class Flag: @unchecked Sendable { var on = false }
            let flag = Flag()
            model.onClose = { flag.on = true }
            model.start()
            return Setup(stub: stub, session: session, layer: layer, model: model, closed: { flag.on })
        }

        private func shown(_ setup: Setup) -> String? {
            setup.layer.match(key: Self.key, table: nil, anyTable: false)?.text
        }

        @Test func opensAtOnceFromTheCacheWithTheSourceAndTheShownLanguage() async {
            let setup = await open()
            #expect(setup.model.phase == .editing)
            #expect(setup.model.primary.map(\.locale) == ["en", "de"])
            #expect(setup.model.others.map(\.locale) == ["fr"])
            // Their own draft is what they see, and what a save replaces.
            #expect(setup.model.primary[1].original == "Jetzt exportieren")
            #expect(setup.model.others[0].editable == false)
            setup.session.signOut()
        }

        @Test func eachKeystrokeRedrawsTheAppThroughALocalDraft() async {
            let setup = await open()
            let before = LiveStore.shared.revision
            setup.model.type("Alles exportieren", in: "de")
            #expect(shown(setup) == "Alles exportieren")
            #expect(LiveStore.shared.revision > before)
            #expect(setup.model.liveText == "Alles exportieren")
            // Typing it back to what Dialecto holds drops the local draft.
            setup.model.type("Jetzt exportieren", in: "de")
            #expect(setup.layer.hasLocal(.init(catalog: "app-localizable", key: Self.key, locale: "de")) == false)
            #expect(setup.session.draftCount == 0)
            setup.session.signOut()
        }

        @Test func typingTheSourceOutdatesTheOtherLanguages() async {
            let setup = await open(language: "en")
            #expect(setup.model.primary.map(\.locale) == ["en"])
            #expect(!setup.model.outdatesOthers)
            setup.model.type("Export all", in: "en")
            #expect(setup.model.outdatesOthers)
            setup.session.signOut()
        }

        @Test func aSaveStagesTheDraftAndCloses() async {
            let setup = await open(edits: [Self.saved("de", "Alles exportieren")])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.closed())
            #expect(setup.session.draftCount == 1)
            #expect(shown(setup) == "Alles exportieren")
            #expect(setup.layer.hasLocal(.init(catalog: "app-localizable", key: Self.key, locale: "de")) == false)
            #expect(setup.stub.bodies(Self.editsRoute).first?["replaces"] == "Jetzt exportieren")
            // The cache holds the new draft: the next open starts from it.
            #expect(setup.session.cachedEntries(Self.key)?.catalogs[0].language("de")?.current == "Alles exportieren")
            setup.session.signOut()
        }

        @Test func cancelWithUnsavedTextAsksThenDiscardDropsIt() async {
            let setup = await open()
            setup.model.type("Alles exportieren", in: "de")
            setup.model.requestClose()
            #expect(setup.model.confirmingDiscard)
            #expect(!setup.closed())
            setup.model.escape()
            #expect(!setup.model.confirmingDiscard)
            setup.model.requestClose()
            setup.model.discard()
            #expect(setup.closed())
            #expect(shown(setup) == nil)
            setup.session.signOut()
        }

        @Test func aConflictOffersTheirTextAndKeepMineSavesOverIt() async {
            let setup = await open(edits: [
                .json(409, #"{"error":"conflict","current":{"text":"Exportieren jetzt"}}"#), Self.saved("de", "Alles exportieren"),
            ])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(!setup.closed())
            #expect(setup.model.fields[1].conflict == "Exportieren jetzt")
            #expect(shown(setup) == "Alles exportieren")
            await setup.model.keepMine("de")
            #expect(setup.closed())
            #expect(setup.stub.bodies(Self.editsRoute).map { $0["replaces"] } == ["Jetzt exportieren", "Exportieren jetzt"])
            setup.session.signOut()
        }

        @Test func useTheirsTakesDialectosText() async {
            let setup = await open(edits: [.json(409, #"{"error":"conflict","current":{"text":"Exportieren jetzt"}}"#)])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            setup.model.useTheirs("de")
            #expect(setup.model.fields[1].text == "Exportieren jetzt")
            #expect(!setup.model.isDirty)
            #expect(setup.model.fields[1].conflict == nil)
            setup.session.signOut()
        }

        @Test func someoneElsesDraftMakesThePanelReadOnly() async {
            let setup = await open(edits: [.json(409, #"{"error":"pending_by_other"}"#)])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.readOnly)
            #expect(setup.model.banner == .pendingByOther)
            setup.model.type("Noch etwas", in: "de")
            #expect(setup.model.fields[1].text == "Alles exportieren")
            setup.session.signOut()
        }

        @Test func aPlaceholderRefusalShowsUnderTheFieldAndKeepsTheText() async {
            let setup = await open(edits: [.json(422, #"{"error":"placeholders","missing":["%@"],"extra":[]}"#)])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.fields[1].error == "Add %@ back.")
            #expect(setup.model.fields[1].text == "Alles exportieren")
            #expect(!setup.closed())
            setup.session.signOut()
        }

        @Test func anOlderTokenAsksToSignInAgain() async {
            let setup = await open(edits: [.json(403, #"{"error":"needs_edit_scope"}"#)])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.banner == .needsEditScope)
            setup.session.signOut()
        }

        @Test func rateLimitedAsksToWait() async {
            let setup = await open(edits: [.json(429, #"{"error":"rate_limited"}"#, headers: ["retry-after": "60"])])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.banner == .rateLimited)
            setup.session.signOut()
        }

        @Test func offlineKeepsTheTextAndRetrySaves() async {
            let setup = await open(edits: [.offline, Self.saved("de", "Alles exportieren")])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.banner == .offline)
            #expect(setup.model.fields[1].text == "Alles exportieren")
            #expect(shown(setup) == "Alles exportieren")
            await setup.model.retrySave()
            #expect(setup.closed())
            #expect(setup.session.draftCount == 1)
            setup.session.signOut()
        }

        @Test func anEndedSessionSignsOut() async {
            let setup = await open(edits: [.json(401, #"{"error":"access_denied"}"#)])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            #expect(setup.model.phase == .signedOut)
            #expect(!setup.session.isSignedIn)
        }

        @Test func oneTextWithTwoKeysAsksWhichFirst() async {
            let setup = await open()
            let model = EditorModel(
                choices: [
                    .init(key: "scene.startatlogin.toggle", catalog: "localizable", text: "Start at login"),
                    .init(key: Self.key, catalog: "localizable", text: "Start at login"),
                ], shownText: "Start at login", isTooltip: false, session: setup.session, layer: setup.layer)
            model.start()
            guard case .choosing(let choices) = model.phase else {
                Issue.record("expected a choice")
                return
            }
            #expect(choices.map(\.key) == ["scene.startatlogin.toggle", Self.key])
            await model.choose(choices[1])
            #expect(model.phase == .editing)
            #expect(model.key == Self.key)
            setup.session.signOut()
        }

        private static let sevenLanguages = """
            {"key":"export.button","source_locale":"en","locales":["en","de","fr","es","it","pt","ja"],
             "catalogs":[{"catalog":"app-localizable","languages":[
               {"locale":"en","text":"Export","outdated":false,"editable":true,"draft":null},
               {"locale":"de","text":"Exportieren","outdated":false,"editable":false,"draft":null,"reason":"no_permission"},
               {"locale":"fr","text":"Exporter","outdated":false,"editable":false,"draft":null,"reason":"no_permission"},
               {"locale":"es","text":"Exportar","outdated":false,"editable":false,"draft":null,"reason":"no_permission"},
               {"locale":"it","text":"Esporta","outdated":false,"editable":false,"draft":null,"reason":"no_permission"},
               {"locale":"pt","text":"Exportar","outdated":false,"editable":false,"draft":null,"reason":"no_permission"},
               {"locale":"ja","text":"","outdated":false,"editable":false,"draft":null,"reason":"no_permission"}]}]}
            """

        @Test func anAnswerWithSixOtherLanguagesFoldsThemUnderOtherLanguages() async {
            let setup = await open(language: "en", entries: .json(200, Self.sevenLanguages))
            #expect(setup.model.phase == .editing)
            #expect(setup.model.primary.map(\.locale) == ["en"])
            #expect(setup.model.others.map(\.locale) == ["de", "fr", "es", "it", "pt", "ja"])
            #expect(!setup.model.hasNoOtherLanguages)
            setup.session.signOut()
        }

        @Test func aProjectWithOnlyItsSourceLanguageSaysSo() async {
            let body = """
                {"key":"export.button","source_locale":"en","locales":["en"],
                 "catalogs":[{"catalog":"app-localizable","languages":[
                   {"locale":"en","text":"Export","outdated":false,"editable":true,"draft":null}]}]}
                """
            let setup = await open(language: "en", entries: .json(200, body))
            #expect(setup.model.others.isEmpty)
            #expect(setup.model.hasNoOtherLanguages)
            setup.session.signOut()
        }

        @Test func aFailedEntriesCallShowsItsReason() async {
            for (reply, reason) in [
                (StubReply.json(500, "{}"), "Dialecto answered 500"),
                (.json(200, "[]"), "Dialecto's answer was not readable"),
                (.json(200, #"{"key":"export.button","source_locale":"en","locales":[],"catalogs":[]}"#), EditorWords.noCatalog),
            ] {
                let setup = await open(language: "en", entries: reply)
                await setup.model.load()
                #expect(setup.model.phase == .failed(reason))
                setup.session.signOut()
            }
        }

        @Test func signedOutTheEditorAsksToSignIn() {
            let session = DraftSession(
                project: "acme/app", client: StubServer([:]).client, store: TokenStore(backend: MemoryBackend()),
                layer: DraftLayer(language: { "en" }), openURL: { _ in })
            let model = EditorModel(
                choices: [.init(key: Self.key, catalog: "localizable", text: "Export")], shownText: "Export",
                isTooltip: false, session: session, layer: DraftLayer(language: { "en" }))
            model.start()
            #expect(model.phase == .signedOut)
        }

        @Test func thePullRequestStepListsEachDraftBeforeAndAfter() async {
            let setup = await open(edits: [Self.saved("de", "Alles exportieren")])
            setup.model.type("Alles exportieren", in: "de")
            await setup.model.save()
            let step = PullRequestModel()
            await step.load(session: setup.session, layer: setup.layer)
            #expect(
                step.groups == [
                    .init(
                        catalog: "app-localizable", locale: "de",
                        changes: [.init(key: Self.key, before: "Exportieren", after: "Alles exportieren")])
                ])
            #expect(step.draftCount == 1)
            #expect(step.fileCount == 1)
            setup.session.signOut()
        }
    }
#endif
