#if DEBUG
    import Foundation
    import Testing

    @testable import DialectoLive
    @testable import DialectoLiveEditing

    /// The link a click on text opens, and the check of the key behind it.
    @MainActor
    @Suite(.serialized)
    struct EditorLinkTests {
        private let server = URL(string: "https://app.test")!

        @Test func theLinkNamesTheProjectAndTheExactKey() throws {
            let url = try #require(EditingRuntime.editorURL(server: server, projectID: "8", key: "Hello, %@ & you"))
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == "/repos/8/catalog")
            #expect(components.queryItems == [URLQueryItem(name: "key", value: "Hello, %@ & you")])
            #expect(components.percentEncodedQuery == "key=Hello,%20%25@%20%26%20you")
        }

        @Test func aLinkWithoutAKeyIsTheCatalog() throws {
            let url = try #require(EditingRuntime.editorURL(server: server, projectID: "8", key: ""))
            #expect(url.absoluteString == "https://app.test/repos/8/catalog")
        }

        @Test func withoutTheProjectThereIsNoLink() {
            #expect(EditingRuntime.editorURL(server: server, projectID: nil, key: "greeting") == nil)
        }

        private func signedIn(_ stub: StubServer, projectID: String?) -> DraftSession {
            let store = TokenStore(backend: MemoryBackend())
            store.save(StoredSession(token: "held", expiresAt: Date().addingTimeInterval(3600), projectID: projectID), project: "acme/app")
            let session = DraftSession(
                project: "acme/app", client: stub.client, store: store, layer: DraftLayer(language: { "de" }),
                sleep: { _ in await Task.yield() }, openURL: { _ in })
            session.resume()
            return session
        }

        @Test func aKeyTheCatalogLacksIsMissing() async {
            let stub = StubServer([
                "GET /api/live/native/entry?key=gone": [.json(404, #"{"found":false,"project_id":"8"}"#)],
                "GET /api/live/native/entry?key=here": [.json(200, #"{"found":true,"project_id":"8"}"#)],
                "GET /api/live/native/drafts": [.json(304, "")],
            ])
            let session = signedIn(stub, projectID: "8")
            #expect(await session.check(key: "gone") == .missing)
            #expect(await session.check(key: "here") == .found)
            #expect(stub.authorization.contains("Bearer held"))
        }

        @Test func aSessionHeldWithoutTheProjectLearnsItFromTheAnswer() async {
            let stub = StubServer([
                "GET /api/live/native/entry?key=here": [.json(200, #"{"found":true,"project_id":"8"}"#)],
                "GET /api/live/native/drafts": [.json(304, "")],
            ])
            let session = signedIn(stub, projectID: nil)
            #expect(session.projectID == nil)
            #expect(await session.check(key: "here") == .found)
            #expect(session.projectID == "8")
        }

        @Test func signedOutOrUnreachableIsUnknown() async {
            let stub = StubServer([:])
            let session = DraftSession(
                project: "acme/app", client: stub.client, store: TokenStore(backend: MemoryBackend()),
                layer: DraftLayer(language: { "de" }), openURL: { _ in })
            #expect(await session.check(key: "x") == .unknown)
        }

        @Test func theTokenAnswerNamesTheProject() async throws {
            let stub = StubServer([
                "POST /api/live/native/token": [.json(200, #"{"access_token":"t","token_type":"Bearer","expires_in":28800,"project_id":"8"}"#)]
            ])
            #expect(try await stub.client.pollToken(deviceCode: "d") == .token("t", expiresIn: 28800, projectID: "8"))
        }
    }
#endif
