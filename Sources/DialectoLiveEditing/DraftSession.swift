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

        let project: String
        private let client: NativeClient
        private let store: TokenStore
        private let layer: DraftLayer
        private let sleep: @Sendable (TimeInterval) async -> Void
        private let openURL: @MainActor (URL) -> Void
        private let now: @Sendable () -> Date
        private var task: Task<Void, Never>?
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

        func signOut() {
            task?.cancel()
            task = nil
            store.forget(project: project)
            layer.clear()
            draftCount = 0
            offline = false
            state = .signedOut
            note = nil
            LiveStore.shared.bump()
            onDraftsChanged?()
        }

        /// Waits for the work in flight, for tests.
        func finish() async { await task?.value }

        // MARK: Sign-in

        private func deviceFlow() async {
            state = .requesting
            let grant: DeviceGrant
            do {
                grant = try await client.startDevice(repo: project)
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
                    case .token(let token, let expiresIn):
                        projectID = grant.projectID
                        let held = StoredSession(
                            token: token, expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
                            projectID: grant.projectID)
                        store.save(held, project: project)
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
            store.forget(project: project)
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
