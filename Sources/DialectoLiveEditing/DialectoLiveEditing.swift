#if DEBUG
    import DialectoLive
    import Foundation

    /// Live editing for a debug build: sign in to Dialecto once, then the text you type in its editor shows
    /// in the running app, and a click on text opens the editor on its key.
    ///
    /// Every source of this target is inside `#if DEBUG`, and the app calls it inside `#if DEBUG` too, so a
    /// release build carries none of it:
    ///
    /// ```swift
    /// #if DEBUG
    ///     DialectoLiveEditing.start(project: "owner/name")
    /// #endif
    /// ```
    public enum DialectoLiveEditing {
        /// Where the drafts token is kept between launches.
        public enum TokenStorage: Sendable {
            /// The Keychain (the default), with the token held in memory for the run if it fails. Use it in a
            /// signed app; an unsigned binary gets a Keychain prompt after every rebuild.
            case keychain
            /// Memory only: sign in again at every launch.
            case memory
            /// A JSON file, for a headless run.
            case file(URL)
        }

        public static let defaultServer = URL(string: "https://app.dialecto.eu")!

        /// Starts the debug session. Nothing runs before this. On a Mac it adds a Dialecto menu; on iOS a
        /// small button over the key window. A token held from an earlier run is used at once; there is
        /// no sign-in prompt until the person picks one (and never in an Xcode preview).
        ///
        /// - Parameters:
        ///   - project: the GitHub repository Dialecto follows, `owner/name`.
        ///   - server: Dialecto's address; the default is `app.dialecto.eu`.
        @MainActor
        ///   - language: the language to show drafts in, for an app with its own language setting; leave it
        ///     out to follow the main bundle's, as `DialectoLive.start` does.
        ///   - tokenStorage: where the token is kept; the Keychain by default.
        public static func start(
            project: String, server: URL = defaultServer, language: String? = nil,
            tokenStorage: TokenStorage = .keychain
        ) {
            EditingRuntime.start(project: project, server: server, language: language, tokenStorage: tokenStorage)
        }

        /// Where links open: Dialecto's page for the sign-in code, and the editor on a key. Leave it nil to
        /// open the system's browser; set it to open somewhere else (a test, a headless run).
        @MainActor public static var openURL: (@MainActor (URL) -> Void)?

        /// One line on where the session is: "signed out", "waiting for code ABCD-2345", "signed in, 3 drafts".
        @MainActor public static var status: String { EditingRuntime.current?.session.statusLine ?? "not started" }

        /// Starts the sign-in: shows the code and opens Dialecto's page for it.
        @MainActor public static func signIn() { EditingRuntime.current?.session.signIn() }

        @MainActor public static func signOut() { EditingRuntime.current?.session.signOut() }

        /// Opens the keys panel.
        @MainActor public static func showKeys() { EditingRuntime.current?.showPanel() }

        /// Whether the next click (Mac) or tap (iOS) picks text for the editor.
        @MainActor
        public static var isEditingText: Bool {
            get { EditingRuntime.current?.editState.isOn ?? false }
            set { EditingRuntime.current?.editState.isOn = newValue }
        }

        /// Writes the keys window's pixels to a PNG (Mac), for a check that needs no screen recording.
        /// Returns false when the window is not up or the platform has no window.
        @MainActor
        @discardableResult
        public static func writePanelImage(to url: URL) -> Bool {
            EditingRuntime.current?.snapshotPanel(to: url) ?? false
        }

        /// The keys panel's filter, for a demo that drives the panel headless.
        @_spi(Demo) @MainActor
        public static var panelFilter: String {
            get { EditingRuntime.current?.model.filter ?? "" }
            set { EditingRuntime.current?.model.filter = newValue }
        }

        /// Picks the text at a point in screen coordinates as a click in Edit text mode would. Mac:
        /// Cocoa coordinates, origin bottom left.
        @MainActor
        public static func pickText(atScreenPoint x: Double, _ y: Double) {
            EditingRuntime.current?.pickText(atScreenPoint: x, y)
        }
    }
#endif
