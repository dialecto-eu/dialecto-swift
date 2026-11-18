#if DEBUG
    import Foundation
    import Testing
    import os

    @testable import DialectoLive
    @testable import DialectoLiveEditing

    /// In-memory secret storage.
    final class MemoryBackend: SecretBackend {
        let items = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        func read(account: String) throws -> Data? { items.withLock { $0[account] } }
        func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
        func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
    }

    /// A Keychain that refuses everything, as one does in a sandbox without the entitlement.
    struct BrokenBackend: SecretBackend {
        func read(account: String) throws -> Data? { throw KeychainFailure(status: -34018) }
        func write(_ data: Data, account: String) throws { throw KeychainFailure(status: -34018) }
        func delete(account: String) throws { throw KeychainFailure(status: -34018) }
    }

    private let grant = """
        {"device_code":"dev-secret","user_code":"ABCD-2345","verification_uri":"https://app.test/live/native/acme/app?project=42","expires_in":600,"interval":5}
        """

    private func feed(_ hash: String, _ rows: String) -> StubReply {
        .json(200, "{\"hash\":\"\(hash)\",\"drafts\":[\(rows)]}")
    }

    private let rowA = #"{"catalog":"localizable","key":"export.button","locale":"de","text":"Szenen exportieren"}"#
    private let rowA2 = #"{"catalog":"localizable","key":"export.button","locale":"de","text":"Jetzt exportieren"}"#
    private let rowSkipped = #"{"catalog":"localizable","key":"scenes.count","locale":"de","skipped":"plural"}"#

    @MainActor
    @Suite(.serialized)
    struct DraftSessionTests {
        private final class Calls: Sendable {
            let sleeps = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
            let opened = OSAllocatedUnfairLock<[URL]>(initialState: [])
            /// The draft shown for `export.button` at each sleep.
            let probe = OSAllocatedUnfairLock<[String?]>(initialState: [])
        }

        private func makeSession(
            _ server: StubServer, store: TokenStore = TokenStore(backend: MemoryBackend()), calls: Calls = Calls()
        ) -> (DraftSession, DraftLayer, Calls) {
            let layer = DraftLayer(language: { "de" })
            let session = DraftSession(
                project: "acme/app", client: server.client, store: store, layer: layer,
                sleep: { seconds in
                    calls.sleeps.withLock { $0.append(seconds) }
                    calls.probe.withLock {
                        $0.append(layer.match(key: "export.button", table: nil, anyTable: false)?.text)
                    }
                    await Task.yield()
                },
                openURL: { url in calls.opened.withLock { $0.append(url) } })
            return (session, layer, calls)
        }

        @Test func signsInThenFollowsTheFeedUntilTheSessionEnds() async throws {
            let server = StubServer([
                "POST /api/live/native/device": [.json(200, grant)],
                "POST /api/live/native/token": [
                    .json(400, #"{"error":"authorization_pending"}"#),
                    .json(400, #"{"error":"slow_down"}"#),
                    .json(200, #"{"access_token":"drafts-token","token_type":"Bearer","expires_in":28800}"#),
                ],
                "GET /api/live/native/drafts": [feed("h1", rowA + "," + rowSkipped)],
                "GET /api/live/native/drafts?hash=h1": [
                    .json(304, ""),
                    feed("h2", rowA2),
                ],
                "GET /api/live/native/drafts?hash=h2": [.json(401, #"{"error":"invalid_token"}"#)],
            ])
            let backend = MemoryBackend()
            let (session, layer, calls) = makeSession(server, store: TokenStore(backend: backend))

            session.signIn()
            await session.finish()

            // The device code asked, the browser opened on the verification link, the poll followed the interval
            // and slowed by five seconds when told to.
            #expect(calls.opened.withLock { $0 } == [URL(string: "https://app.test/live/native/acme/app?project=42")!])
            #expect(calls.sleeps.withLock { Array($0.prefix(3)) } == [5, 5, 10])
            #expect(
                server.requests == [
                    "POST /api/live/native/device",
                    "POST /api/live/native/token", "POST /api/live/native/token", "POST /api/live/native/token",
                    "GET /api/live/native/drafts",
                    "GET /api/live/native/drafts?hash=h1", "GET /api/live/native/drafts?hash=h1",
                    "GET /api/live/native/drafts?hash=h2",
                ])
            #expect(Set(server.authorization) == ["Bearer drafts-token"])

            // The first answer filled the draft layer before the 304 made the loop wait.
            #expect(calls.probe.withLock { $0.prefix(4).map { $0 } } == [nil, nil, nil, "Szenen exportieren"])

            // The 401 ended it: the token is dropped and the drafts are gone.
            #expect(session.state == .signedOut)
            #expect(session.note == "Session ended")
            #expect(layer.match(key: "export.button", table: nil, anyTable: false) == nil)
            #expect(backend.items.withLock { $0.isEmpty })
        }

        @Test func lostAccessEndsTheSessionWithItsReason() async throws {
            let server = StubServer([
                "POST /api/live/native/device": [.json(200, grant)],
                "POST /api/live/native/token": [.json(200, #"{"access_token":"t","token_type":"Bearer","expires_in":28800}"#)],
                "GET /api/live/native/drafts": [feed("h1", rowA + "," + rowSkipped)],
                // A long poll that never changes would loop; end it after the first answer is applied.
                "GET /api/live/native/drafts?hash=h1": [.json(401, #"{"error":"access_denied"}"#)],
            ])
            let (session, layer, _) = makeSession(server)
            session.signIn()
            await session.finish()

            #expect(session.state == .signedOut)
            #expect(session.note == "Access ended")
            #expect(layer.draftCount == 0)
        }

        @Test func aFeedAnswerFillsTheLayerAndNotesWhatCouldNotBeShown() async throws {
            let server = StubServer([
                "GET /api/live/native/drafts": [feed("h1", rowA + "," + rowSkipped)],
                "GET /api/live/native/drafts?hash=h1": [.json(401, #"{"error":"invalid_token"}"#)],
            ])
            let layer = DraftLayer(language: { "de" })
            let answer = try await server.client.feed(token: "t", hash: nil)
            guard case .drafts(let hash, let rows) = answer else { Issue.record("expected drafts"); return }
            layer.replace(rows: rows)

            #expect(hash == "h1")
            #expect(layer.match(key: "export.button", table: nil, anyTable: false)?.text == "Szenen exportieren")
            #expect(layer.draftCount == 1)
            #expect(layer.notShown == [.init(catalog: "localizable", key: "scenes.count", locale: "de", reason: "plural")])
        }

        @Test func tokenPollErrorsEndTheSignIn() async throws {
            for (error, note) in [("expired_token", "Code expired"), ("access_denied", "Sign-in denied")] {
                let server = StubServer([
                    "POST /api/live/native/device": [.json(200, grant)],
                    "POST /api/live/native/token": [.json(400, "{\"error\":\"\(error)\"}")],
                ])
                let (session, _, _) = makeSession(server)
                session.signIn()
                await session.finish()
                #expect(session.state == .failed(note))
            }
        }

        @Test func aHeldTokenResumesWithoutAnotherSignIn() async throws {
            let server = StubServer([
                "GET /api/live/native/drafts": [feed("h1", rowA)],
                "GET /api/live/native/drafts?hash=h1": [.json(401, #"{"error":"invalid_token"}"#)],
            ])
            let backend = MemoryBackend()
            let store = TokenStore(backend: backend)
            store.save(
                StoredSession(token: "held", expiresAt: Date().addingTimeInterval(3600), projectID: "42"), project: "acme/app")
            let (session, _, _) = makeSession(server, store: store)
            session.resume()
            #expect(session.projectID == "42")
            await session.finish()
            #expect(server.authorization.first == "Bearer held")
            #expect(!server.requests.contains { $0.contains("/device") })
        }

        @Test func serverErrorsBackOffAndRetryWhileDraftsStay() async throws {
            let server = StubServer([
                "POST /api/live/native/device": [.json(200, grant)],
                "POST /api/live/native/token": [.json(200, #"{"access_token":"t","token_type":"Bearer","expires_in":28800}"#)],
                "GET /api/live/native/drafts": [.json(500, ""), .json(500, ""), feed("h1", rowA)],
                "GET /api/live/native/drafts?hash=h1": [.json(429, "{}", headers: ["retry-after": "30"]), .json(401, "{}")],
            ])
            let (session, _, calls) = makeSession(server)
            session.signIn()
            await session.finish()

            // 5 s for the poll, then 2 s and 4 s of backoff, then the 429's 30 s.
            #expect(calls.sleeps.withLock { $0 } == [5, 2, 4, 30])
        }

        @Test func aProjectThatIsNotAStringCatalogStopsTheFeedButKeepsTheToken() async throws {
            let server = StubServer([
                "POST /api/live/native/device": [.json(200, grant)],
                "POST /api/live/native/token": [.json(200, #"{"access_token":"t","token_type":"Bearer","expires_in":28800}"#)],
                "GET /api/live/native/drafts": [.json(422, #"{"error":"unsupported_format"}"#)],
            ])
            let backend = MemoryBackend()
            let (session, _, _) = makeSession(server, store: TokenStore(backend: backend))
            session.signIn()
            await session.finish()
            if case .failed = session.state {} else { Issue.record("expected failed, got \(session.state)") }
            #expect(!backend.items.withLock { $0.isEmpty })
        }
    }

    /// Stands in for the system Keychain: no test calls `SecItem*`.
    final class FakeKeychain: KeychainAPI {
        let items = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        let services = OSAllocatedUnfairLock<[String]>(initialState: [])

        private func account(_ query: CFDictionary) -> String {
            ((query as NSDictionary) as? [String: Any])?[kSecAttrAccount as String] as? String ?? ""
        }

        func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
            let service = ((query as NSDictionary) as? [String: Any])?[kSecAttrService as String] as? String ?? ""
            services.withLock { $0.append(service) }
            let key = account(query)
            guard let data = items.withLock({ $0[key] }) else { return errSecItemNotFound }
            result = data as CFData
            return errSecSuccess
        }

        func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
            let key = account(query)
            guard items.withLock({ $0[key] }) != nil,
                let data = ((attributes as NSDictionary) as? [String: Any])?[kSecValueData as String] as? Data
            else { return errSecItemNotFound }
            items.withLock { $0[key] = data }
            return errSecSuccess
        }

        func add(_ attributes: CFDictionary) -> OSStatus {
            let dict = (attributes as NSDictionary) as? [String: Any] ?? [:]
            guard let data = dict[kSecValueData as String] as? Data else { return errSecParam }
            let key = dict[kSecAttrAccount as String] as? String ?? ""
            items.withLock { $0[key] = data }
            return errSecSuccess
        }

        func delete(_ query: CFDictionary) -> OSStatus {
            let key = account(query)
            items.withLock { $0[key] = nil }
            return errSecSuccess
        }
    }

    struct KeychainBackendTests {
        @Test func theKeychainBackendWritesReadsAndDeletesByServiceAndAccount() throws {
            let fake = FakeKeychain()
            let backend = KeychainBackend(api: fake)
            #expect(try backend.read(account: "acme/app") == nil)
            try backend.write(Data("one".utf8), account: "acme/app")
            try backend.write(Data("two".utf8), account: "acme/app")
            #expect(try backend.read(account: "acme/app") == Data("two".utf8))
            #expect(fake.services.withLock { Set($0) } == ["eu.dialecto.live-editing"])
            try backend.delete(account: "acme/app")
            #expect(try backend.read(account: "acme/app") == nil)
        }

        @Test func aFileBackendKeepsTokensWithoutTheKeychain() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let backend = FileBackend(url: url)
            try backend.write(Data("x".utf8), account: "a")
            #expect(try FileBackend(url: url).read(account: "a") == Data("x".utf8))
            try backend.delete(account: "a")
            #expect(try backend.read(account: "a") == nil)
        }
    }

    struct FileBackendTests {
        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }

        @Test func theTokenFileIsOwnerOnlyAndStaysSoWhenReplaced() throws {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("tokens.json")
            let backend = FileBackend(url: file)
            try backend.write(Data("one".utf8), account: "a")
            #expect(try mode(file) == 0o600)
            try backend.write(Data("two".utf8), account: "a")
            #expect(try mode(file) == 0o600)
            try backend.delete(account: "a")
            #expect(try mode(file) == 0o600)
            // No temporary file is left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tokens.json"])
        }

        @Test func aLinkInPlaceOfTheFileIsRefused() throws {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let target = dir.appendingPathComponent("elsewhere.json")
            try Data("{}".utf8).write(to: target)
            let link = dir.appendingPathComponent("tokens.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let backend = FileBackend(url: link)
            #expect(throws: FileBackend.Refused.self) { try backend.read(account: "a") }
            #expect(throws: FileBackend.Refused.self) { try backend.write(Data("x".utf8), account: "a") }
            #expect(try Data(contentsOf: target) == Data("{}".utf8))
        }
    }

    struct TokenStoreTests {
        private let session = StoredSession(token: "secret", expiresAt: Date().addingTimeInterval(3600), projectID: "7")

        @Test func aWorkingKeychainHoldsTheTokenAcrossStores() {
            let backend = MemoryBackend()
            #expect(TokenStore(backend: backend).save(session, project: "Acme/App"))
            // A new store (a new launch) finds it, whatever the project's case.
            #expect(TokenStore(backend: backend).load(project: "acme/app") == session)
        }

        @Test func whenTheKeychainFailsTheTokenLivesInMemoryForTheRun() {
            let store = TokenStore(backend: BrokenBackend())
            #expect(store.save(session, project: "acme/app") == false)
            #expect(store.load(project: "acme/app") == session)

            // The next launch has nothing, and the person signs in again.
            #expect(TokenStore(backend: BrokenBackend()).load(project: "acme/app") == nil)

            store.forget(project: "acme/app")
            #expect(store.load(project: "acme/app") == nil)
        }

        @Test func anExpiredTokenIsDropped() {
            let backend = MemoryBackend()
            let early = TokenStore(backend: backend, now: { Date() })
            early.save(session, project: "acme/app")
            let later = TokenStore(backend: backend, now: { Date().addingTimeInterval(7200) })
            #expect(later.load(project: "acme/app") == nil)
            #expect(backend.items.withLock { $0.isEmpty })
        }
    }
#endif
