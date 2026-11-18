#if DEBUG
    import DialectoLive
    import Foundation

    /// The running debug session: the drafts, the log of lookups, the sign-in and the panel.
    @MainActor
    final class EditingRuntime {
        static var current: EditingRuntime?

        let server: URL
        let layer: DraftLayer
        let log = LookupLog()
        let session: DraftSession
        let model: PanelModel
        let editState = EditModeState()
        /// Mac window or iOS controller, set by the platform file.
        var platform: AnyObject?

        init(project: String, server: URL, client: NativeClient, store: TokenStore, layer: DraftLayer) {
            self.server = server
            self.layer = layer
            model = PanelModel(log: log, layer: layer)
            session = DraftSession(
                project: project, client: client, store: store, layer: layer,
                openURL: { Self.open($0) })
            let model = model
            session.onDraftsChanged = { model.changed() }
        }

        static func start(
            project: String, server: URL, language: String? = nil,
            tokenStorage: DialectoLiveEditing.TokenStorage = .keychain
        ) {
            guard current == nil else { return }
            let backend: any SecretBackend =
                switch tokenStorage {
                case .keychain: KeychainBackend()
                case .memory: MemoryOnlyBackend()
                case .file(let url): FileBackend(url: url)
                }
            let layer = language.map { fixed in DraftLayer(language: { fixed }) } ?? DraftLayer()
            let runtime = EditingRuntime(
                project: project, server: server,
                client: NativeClient(server: server, session: NativeClient.makeSession()),
                store: TokenStore(backend: backend), layer: layer)
            current = runtime
            runtime.install()
        }

        /// Puts the hook in place and brings up the platform's controls.
        func install() {
            let layer = layer
            let log = log
            let model = model
            DialectoLive.installBundleHook()
            LookupHooks.current = LookupHook(
                draft: { key, table, anyTable in layer.match(key: key, table: table, anyTable: anyTable) },
                refused: { record in
                    layer.refuse(record)
                    model.changed()
                },
                record: { record in
                    log.record(record)
                    model.changed()
                })
            session.canSignIn = !Self.inPreview
            editState.onChange = { [weak self] on in self?.editModeChanged(on) }
            installPlatform()
            // Never prompt in a preview; a token already held still works.
            session.resume()
        }

        static var inPreview: Bool { ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }

        // MARK: Picking text

        /// The editor on a key: the project's catalog filtered to it. Without the project's id (not signed
        /// in yet), the project list.
        func editorURL(key: String) -> URL {
            guard let id = session.projectID, var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
            else { return server.appendingPathComponent("repos") }
            components.path = "/repos/\(id)/catalog"
            components.queryItems = [URLQueryItem(name: "search", value: key)]
            return components.url ?? server
        }

        func openEditor(key: String) { Self.open(editorURL(key: key)) }

        /// The project's catalog in Dialecto.
        func openProject() {
            var url = editorURL(key: "")
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.queryItems = nil
                url = components.url ?? url
            }
            Self.open(url)
        }

        /// The keys a piece of on-screen text could be, for the hover outline.
        func keys(for text: String?) -> [LookupEntry] {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return log.reverse(text)
        }

        /// The system's browser, unless the app chose another way.
        static func open(_ url: URL) {
            if let handler = DialectoLiveEditing.openURL { handler(url) } else { openInBrowser(url) }
        }

        /// A click on `text`: one key opens the editor and ends Edit text; several open the panel on them.
        /// Text that is not Dialecto's leaves the mode on and only notes it in the panel.
        func pick(text: String?) {
            let found = keys(for: text)
            if found.isEmpty {
                model.noKey(for: text)
                return
            }
            editState.isOn = false
            model.clearNote()
            if Set(found.map(\.key)).count == 1, let only = found.first {
                openEditor(key: only.key)
            } else {
                model.show(matches: found, for: text ?? "")
                showPanel()
            }
        }
    }
#endif
