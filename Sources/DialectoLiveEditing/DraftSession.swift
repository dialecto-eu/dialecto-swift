#if DEBUG
    import DialectoLive
    import Foundation
    import Observation

    /// The person's sign-in and the drafts feed behind it: a device code, a token poll, then a long poll
    /// of the drafts. What the panel shows about both lives here.
    @MainActor
    @Observable
    final class DraftSession {
        enum State: Equatable {
            case signedOut
            case requesting
            case waiting(userCode: String, link: URL)
            case signedIn
            case failed(String)
        }

        /// The words for a failed sign-in or an ended session, as the panel shows them.
        enum Failure {
            static let unreachable = "Dialecto unreachable"
            static let expired = "Code expired"
            static let denied = "Sign-in denied"
            static let notACatalog = "Not a String Catalog"
            static let accessEnded = "Access ended"
            static let sessionEnded = "Session ended"
        }

        private(set) var state: State = .signedOut
        /// Why the session is where it is, when the person should know (an ended session, a failure).
        private(set) var note: String?
        /// The feed could not be reached; drafts already received stay.
        private(set) var offline = false
        private(set) var draftCount = 0
        /// The project's id in Dialecto, learned at sign-in; the editor's links use it.
        private(set) var projectID: String?
        /// Dialecto's pull request page for the project, learned at sign-in or from an entries answer.
        private(set) var previewURL: URL?
        /// Entries answers by key, so the editor opens at once on a key seen before.
        @ObservationIgnored private var entriesCache: [String: Entries] = [:]
        @ObservationIgnored private var inFlight: [String: Task<EntriesOutcome, Never>] = [:]

        let project: String
        private let client: NativeClient
        private let store: TokenStore
        private let layer: DraftLayer
        private let sleep: @Sendable (TimeInterval) async -> Void
        private let openURL: @MainActor (URL) -> Void
        private let now: @Sendable () -> Date
        private var task: Task<Void, Never>?
        private var token: String?
        /// Called when the drafts or the session changed, so the panel rebuilds.
        var onDraftsChanged: (() -> Void)?

        init(
            project: String, client: NativeClient, store: TokenStore, layer: DraftLayer,
            sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
            openURL: @escaping @MainActor (URL) -> Void,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.project = project
            self.client = client
            self.store = store
            self.layer = layer
            self.sleep = sleep
            self.openURL = openURL
            self.now = now
        }

        var isSignedIn: Bool { state == .signedIn }

        var statusLine: String {
            switch state {
            case .signedOut: note.map { "signed out, \($0)" } ?? "signed out"
            case .requesting: "contacting Dialecto"
            case .waiting(let code, _): "waiting for code \(code)"
            case .signedIn: "signed in, \(draftCount) drafts" + (offline ? ", offline" : "")
            case .failed(let message): "failed, \(message)"
            }
        }

        /// Picks up a token held from an earlier launch, and starts the feed with it.
        func resume() {
            guard task == nil, let held = store.load(project: project) else { return }
            projectID = held.projectID
            previewURL = held.previewURL
            token = held.token
            state = .signedIn
            task = Task { await feedLoop(token: held.token) }
        }

        /// False in an Xcode preview, which never signs in (it uses a token already held, or bundled text).
        var canSignIn = true

        func signIn() {
            guard canSignIn else { return }
            switch state {
            case .requesting, .waiting, .signedIn: return
            case .signedOut, .failed: break
            }
            note = nil
            task = Task { await deviceFlow() }
        }

        /// A token from before edit scopes can't save: drop it and start a sign-in that asks for them.
        func signInAgain() {
            signOut()
            signIn()
        }

        func signOut() {
            task?.cancel()
            task = nil
            store.forget(project: project)
            token = nil
            dropCache()
            layer.clear()
            draftCount = 0
            offline = false
            state = .signedOut
            note = nil
            LiveStore.shared.bump()
            onDraftsChanged?()
        }

        /// What the project's catalog says about `key`; `.unknown` when signed out or Dialecto can't be
        /// reached. Learns the project's id on the way, for a session held from before it was kept.
        enum KeyCheck: Equatable { case found, missing, unknown }

        func check(key: String) async -> KeyCheck {
            guard isSignedIn, let token else { return .unknown }
            guard let answer = try? await client.entry(token: token, key: key) else { return .unknown }
            if projectID == nil, let learned = answer.projectID {
                projectID = learned
                store.save(
                    StoredSession(token: token, expiresAt: store.load(project: project)?.expiresAt ?? now().addingTimeInterval(3600), projectID: learned),
                    project: project)
            }
            return answer.found ? .found : .missing
        }

        /// Waits for the work in flight, for tests.
        func finish() async { await task?.value }

        // MARK: Entries and saves

        /// The last entries answer for `key`, if any.
        func cachedEntries(_ key: String) -> Entries? { entriesCache[key] }

        /// Fetches `key`'s entries in the background, so a click a moment later opens at once.
        func prefetch(_ key: String) {
            guard isSignedIn, entriesCache[key] == nil, inFlight[key] == nil else { return }
            Task { _ = await fetchEntries(key) }
        }

        /// Every language's text of `key`. One request per key at a time; the answer is cached.
        func fetchEntries(_ key: String) async -> EntriesOutcome {
            guard isSignedIn, let token else { return .ended("signed_out") }
            if let running = inFlight[key] { return await running.value }
            let client = client
            let running = Task { () -> EntriesOutcome in
                do { return try await client.entries(token: token, key: key) } catch NativeError.unexpected(let status) {
                    return .failed("Dialecto answered \(status)")
                } catch NativeError.malformed {
                    return .failed("Dialecto's answer was not readable")
                } catch { return .offline }
            }
            inFlight[key] = running
            let outcome = await running.value
            inFlight[key] = nil
            switch outcome {
            case .found(let entries):
                entriesCache[key] = entries
                if let url = entries.previewURL, url != previewURL { previewURL = url }
            case .notFound:
                entriesCache[key] = nil
            case .ended(let reason):
                if self.token == token { end(reason == "access_denied" ? Failure.accessEnded : Failure.sessionEnded) }
            default:
                break
            }
            return outcome
        }

        /// Saves one language's text as the person's draft. A saved draft goes into the layer at once,
        /// ahead of the feed, and into the cached entries, so the editor reopens on it.
        func save(_ edit: EditRequest) async -> SaveOutcome {
            guard isSignedIn, let token else { return .ended("signed_out") }
            let outcome: SaveOutcome
            do { outcome = try await client.save(token: token, edit) } catch { outcome = .offline }
            switch outcome {
            case .saved(let draft, let state, _):
                let cell = DraftLayer.Cell(catalog: draft?.catalog ?? edit.catalog, key: edit.key, locale: edit.locale)
                layer.upsert(cell, text: draft?.text)
                remember(edit, draft: draft.flatMap { row in row.text.map { EntryDraft(text: $0, state: state) } })
                draftCount = layer.draftCount
                LiveStore.shared.bump()
                onDraftsChanged?()
            case .conflict:
                // The cached text is stale: the next open reads it again.
                entriesCache[edit.key] = nil
            case .ended(let reason):
                if self.token == token { end(reason == "access_denied" ? Failure.accessEnded : Failure.sessionEnded) }
            default:
                break
            }
            return outcome
        }

        private func remember(_ edit: EditRequest, draft: EntryDraft?) {
            guard var entries = entriesCache[edit.key] else { return }
            for c in entries.catalogs.indices where sameCatalog(entries.catalogs[c].catalog, edit.catalog) {
                for l in entries.catalogs[c].languages.indices where entries.catalogs[c].languages[l].locale == edit.locale {
                    entries.catalogs[c].languages[l].draft = draft
                }
            }
            entriesCache[edit.key] = entries
        }

        private func dropCache() {
            entriesCache = [:]
            for running in inFlight.values { running.cancel() }
            inFlight = [:]
        }

        // MARK: Sign-in

        private func deviceFlow() async {
            state = .requesting
            let grant: DeviceGrant
            do {
                grant = try await client.startDevice(repo: project, scope: "edit")
            } catch {
                fail(Failure.unreachable)
                return
            }
            state = .waiting(userCode: grant.userCode, link: grant.verificationURI)
            openURL(grant.verificationURI)

            var interval = TimeInterval(max(grant.interval, 1))
            let deadline = now().addingTimeInterval(TimeInterval(grant.expiresIn))
            var failures = 0
            while !Task.isCancelled {
                await sleep(interval)
                if Task.isCancelled { return }
                if now() >= deadline {
                    fail(Failure.expired)
                    return
                }
                do {
                    switch try await client.pollToken(deviceCode: grant.deviceCode) {
                    case .token(let token, let expiresIn, let granted, let preview):
                        projectID = granted ?? grant.projectID
                        previewURL = preview
                        let held = StoredSession(
                            token: token, expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
                            projectID: projectID, previewURL: preview)
                        store.save(held, project: project)
                        self.token = token
                        state = .signedIn
                        await feedLoop(token: token)
                        return
                    case .pending:
                        failures = 0
                    case .slowDown:
                        interval += 5
                    case .expired:
                        fail(Failure.expired)
                        return
                    case .denied:
                        fail(Failure.denied)
                        return
                    }
                } catch {
                    failures += 1
                    if failures >= 20 {
                        fail(Failure.unreachable)
                        return
                    }
                }
            }
        }

        // MARK: Feed

        private func feedLoop(token: String) async {
            var hash: String?
            var failures = 0
            while !Task.isCancelled {
                do {
                    let answer = try await client.feed(token: token, hash: hash)
                    if Task.isCancelled { return }
                    failures = 0
                    offline = false
                    switch answer {
                    case .drafts(let newHash, let rows):
                        hash = newHash
                        layer.replace(rows: rows)
                        draftCount = layer.draftCount
                        LiveStore.shared.bump()
                        onDraftsChanged?()
                    case .unchanged:
                        await sleep(0.25)
                    case .ended(let reason):
                        end(reason == "access_denied" ? Failure.accessEnded : Failure.sessionEnded)
                        return
                    case .unsupportedFormat:
                        fail(Failure.notACatalog)
                        return
                    case .rateLimited(let retryAfter):
                        await sleep(max(retryAfter, 1))
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    offline = true
                    await sleep(min(pow(2, Double(failures)), 60))
                }
            }
        }

        private func end(_ message: String) {
            task?.cancel()
            store.forget(project: project)
            token = nil
            dropCache()
            layer.clear()
            draftCount = 0
            LiveStore.shared.bump()
            onDraftsChanged?()
            task = nil
            state = .signedOut
            note = message
        }

        private func fail(_ message: String) {
            task = nil
            state = .failed(message)
            note = message
        }
    }
#endif
