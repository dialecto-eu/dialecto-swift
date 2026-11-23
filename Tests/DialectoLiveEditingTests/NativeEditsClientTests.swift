#if DEBUG
    import Foundation
    import Testing

    @testable import DialectoLiveEditing

    /// Each answer of `GET /entries` and `POST /edits`, decoded, and what the sign-in asks for.
    struct NativeEditsClientTests {
        static let entriesBody = """
            {"key":"export.button","source_locale":"en","locales":["en","de","fr"],
             "preview_url":"https://app.test/repos/8/pull-request",
             "catalogs":[{"catalog":"app-localizable","languages":[
               {"locale":"en","text":"Export","outdated":false,"editable":true,"draft":null},
               {"locale":"de","text":"Exportieren","outdated":true,"editable":true,"draft":{"text":"Jetzt exportieren","state":"pending"}},
               {"locale":"fr","text":"","outdated":false,"editable":false,"draft":null,"reason":"no_permission"}]}]}
            """

        private let edit = EditRequest(
            catalog: "app-localizable", key: "export.button", locale: "en", text: "Export all", replaces: "Export")

        private func save(_ reply: StubReply) async throws -> SaveOutcome {
            let stub = StubServer(["POST /api/live/native/edits": [reply]])
            return try await stub.client.save(token: "t", edit)
        }

        @Test func signInAsksForTheEditScope() async throws {
            let stub = StubServer([
                "POST /api/live/native/device": [
                    .json(200, #"{"device_code":"d","user_code":"ABCD-2345","verification_uri":"https://app.test/live/native/acme/app","expires_in":600,"interval":5}"#)
                ]
            ])
            _ = try await stub.client.startDevice(repo: "acme/app")
            #expect(stub.bodies("POST /api/live/native/device") == [["repo": "acme/app", "scope": "edit"]])
        }

        @Test func theTokenAnswerCarriesThePreviewPage() async throws {
            let stub = StubServer([
                "POST /api/live/native/token": [
                    .json(200, #"{"access_token":"t","expires_in":28800,"project_id":"8","scope":"edit","preview_url":"https://app.test/repos/8/pull-request"}"#)
                ]
            ])
            #expect(
                try await stub.client.pollToken(deviceCode: "d")
                    == .token(
                        "t", expiresIn: 28800, projectID: "8", previewURL: URL(string: "https://app.test/repos/8/pull-request")))
        }

        @Test func entriesDecodeEveryLanguageWithItsDraftAndReason() async throws {
            let stub = StubServer(["GET /api/live/native/entries?key=export.button": [.json(200, Self.entriesBody)]])
            guard case .found(let entries) = try await stub.client.entries(token: "t", key: "export.button") else {
                Issue.record("not found")
                return
            }
            #expect(entries.sourceLocale == "en")
            #expect(entries.previewURL?.absoluteString == "https://app.test/repos/8/pull-request")
            let block = try #require(entries.catalog(matching: "localizable"))
            #expect(block.catalog == "app-localizable")
            #expect(block.language("de")?.current == "Jetzt exportieren")
            #expect(block.language("de")?.outdated == true)
            #expect(block.language("fr")?.editable == false)
            #expect(block.language("fr")?.reason == "no_permission")
            #expect(stub.authorization == ["Bearer t"])
        }

        @Test func entriesRefusalsDecode() async throws {
            let stub = StubServer([
                "GET /api/live/native/entries?key=gone": [.json(404, #"{"error":"not_found","reason":"No such key in this project"}"#)],
                "GET /api/live/native/entries?key=busy": [.json(429, #"{"error":"rate_limited"}"#, headers: ["retry-after": "60"])],
                "GET /api/live/native/entries?key=lost": [.json(401, #"{"error":"access_denied"}"#)],
            ])
            #expect(try await stub.client.entries(token: "t", key: "gone") == .notFound)
            #expect(try await stub.client.entries(token: "t", key: "busy") == .rateLimited(retryAfter: 60))
            #expect(try await stub.client.entries(token: "t", key: "lost") == .ended("access_denied"))
        }

        @Test func aSaveSendsTheTextAndWhatItReplaces() async throws {
            let stub = StubServer([
                "POST /api/live/native/edits": [
                    .json(200, #"{"draft":{"catalog":"app-localizable","key":"export.button","locale":"en","text":"Export all"},"state":"pending","hash":"h9"}"#)
                ]
            ])
            let outcome = try await stub.client.save(token: "t", edit)
            #expect(
                outcome
                    == .saved(
                        draft: DraftRow(catalog: "app-localizable", key: "export.button", locale: "en", text: "Export all"),
                        state: "pending", hash: "h9"))
            #expect(
                stub.bodies("POST /api/live/native/edits") == [
                    [
                        "catalog": "app-localizable", "key": "export.button", "locale": "en", "text": "Export all",
                        "replaces": "Export",
                    ]
                ])
        }

        @Test func aSaveBackToTheRepositorysTextHasNoDraft() async throws {
            #expect(try await save(.json(200, #"{"draft":null,"state":null,"hash":"h2"}"#)) == .saved(draft: nil, state: nil, hash: "h2"))
        }

        @Test func eachRefusalOfASaveDecodes() async throws {
            #expect(try await save(.json(403, #"{"error":"needs_edit_scope"}"#)) == .needsEditScope)
            #expect(try await save(.json(403, #"{"error":"forbidden","reason":"No edit access to that language"}"#)) == .forbidden)
            #expect(try await save(.json(404, #"{"error":"not_found"}"#)) == .notFound)
            #expect(try await save(.json(409, #"{"error":"conflict","current":{"text":"Export now"}}"#)) == .conflict(current: "Export now"))
            #expect(try await save(.json(409, #"{"error":"pending_by_other"}"#)) == .pendingByOther)
            #expect(
                try await save(.json(422, #"{"error":"placeholders","missing":["%@"],"extra":["%lld"]}"#))
                    == .refused(SaveRefusal(error: "placeholders", missing: ["%@"], extra: ["%lld"])))
            #expect(
                try await save(.json(422, #"{"error":"not_editable","reason":"plural"}"#))
                    == .refused(SaveRefusal(error: "not_editable", reason: "plural")))
            #expect(try await save(.json(422, #"{"error":"too_long"}"#)) == .refused(SaveRefusal(error: "too_long")))
            #expect(
                try await save(.json(429, #"{"error":"rate_limited"}"#, headers: ["retry-after": "60"]))
                    == .rateLimited(retryAfter: 60))
            #expect(try await save(.json(401, #"{"error":"invalid_token"}"#)) == .ended("invalid_token"))
        }

        @Test func aMalformedConflictThrows() async {
            await #expect(throws: NativeError.malformed) { try await save(.json(409, #"{"error":"conflict"}"#)) }
        }

        @Test func placeholderRefusalsNameTheMissingAndExtraOnes() {
            #expect(
                EditorWords.refusal(SaveRefusal(error: "placeholders", missing: ["%@"], extra: ["%lld", "%d"]))
                    == "Add %@ back. Remove %lld and %d.")
            #expect(EditorWords.refusal(SaveRefusal(error: "not_editable", reason: "plural")) == "Plural text is edited in Dialecto.")
        }
    }
#endif
