#if DEBUG
    import DialectoLive
    import Foundation
    import Observation

    /// The floating editor's state: the key a click picked, every language's text, what the person typed and
    /// what Dialecto said about the save. Typing writes a local draft, so the app redraws with each keystroke.
    @MainActor
    @Observable
    final class EditorModel {
        enum Phase: Equatable {
            /// One text, several keys: the person picks one first.
            case choosing([KeyChoice])
            case loading
            case editing
            case signedOut
            /// The catalog has no such key.
            case missing
            /// The entries could not be read; `retry` tries again.
            case failed(String)
        }

        struct KeyChoice: Equatable, Identifiable {
            var key: String
            var catalog: String
            var text: String
            var id: String { "\(catalog)\u{0}\(key)" }
        }

        /// A line over the buttons, for the whole panel.
        enum Banner: Equatable {
            case needsEditScope
            case pendingByOther
            case rateLimited
            case offline
        }

        struct Field: Equatable, Identifiable {
            var locale: String
            var isSource: Bool
            /// The repository's text.
            var repoText: String
            /// What a save replaces: the person's draft when there is one, else the repository's text.
            var original: String
            var text: String
            var editable: Bool
            var reason: String?
            var outdated: Bool
            var hasDraft: Bool
            /// Dialecto's refusal of the last save, in words.
            var error: String?
            /// 409: the text Dialecto holds now, for Use theirs and Keep mine.
            var conflict: String?

            var id: String { locale }
            var isDirty: Bool { text != original }
        }

        private(set) var phase: Phase
        private(set) var key: String
        private(set) var catalog: String?
        let isTooltip: Bool
        /// The text the click landed on, for the signed-out panel.
        let shownText: String
        /// The language the app shows.
        let shownLocale: String?
        private(set) var sourceLocale: String?
        private(set) var fields: [Field] = []
        /// Other languages a person opened for editing, beside the source and the shown one.
        private(set) var promoted: Set<String> = []
        var othersOpen = false
        private(set) var banner: Banner?
        private(set) var saving = false
        /// Someone else's draft is on the key: nothing here can be saved.
        private(set) var readOnly = false
        /// Esc or Cancel with unsaved text: the panel asks before it drops it.
        private(set) var confirmingDiscard = false

        @ObservationIgnored private let session: DraftSession
        @ObservationIgnored private let layer: DraftLayer
        @ObservationIgnored private var afterDiscard: (() -> Void)?
        /// Called when the panel should close: after a save, a cancel, or a discard.
        @ObservationIgnored var onClose: (() -> Void)?
        /// Called after each keystroke the app redraws for, so the platform can follow the text's frame.
        @ObservationIgnored var onTyped: (() -> Void)?

        init(
            choices: [KeyChoice], shownText: String, isTooltip: Bool, session: DraftSession, layer: DraftLayer
        ) {
            self.session = session
            self.layer = layer
            self.shownText = shownText
            self.isTooltip = isTooltip
            shownLocale = layer.currentLanguage
            let keys = Set(choices.map(\.key))
            key = choices.first?.key ?? ""
            catalog = choices.first?.catalog
            phase = keys.count > 1 ? .choosing(Self.unique(choices)) : .loading
        }

        private static func unique(_ choices: [KeyChoice]) -> [KeyChoice] {
            var seen = Set<String>()
            return choices.filter { seen.insert($0.key).inserted }
        }

        // MARK: Loading

        /// What the panel can show before any request: the cached entries, or the sign-in. Called before
        /// the panel is drawn, so it opens at its final size.
        func start() {
            if case .choosing = phase { return }
            if !session.isSignedIn {
                phase = .signedOut
            } else if let cached = session.cachedEntries(key) {
                apply(cached)
                phase = .editing
            }
        }

        /// Opens the editor on its key: at once from the cached entries, else after the request.
        func load() async {
            if case .choosing = phase { return }
            guard session.isSignedIn else {
                phase = .signedOut
                return
            }
            if let cached = session.cachedEntries(key) {
                apply(cached)
                phase = .editing
                // The cache may be a little old: read it again, keeping whatever was typed.
                if case .found(let fresh) = await session.fetchEntries(key), fresh != cached, !readOnly { apply(fresh) }
                return
            }
            phase = .loading
            switch await session.fetchEntries(key) {
            case .found(let entries):
                apply(entries)
                phase = .editing
            case .notFound: phase = .missing
            case .ended: phase = .signedOut
            case .offline: phase = .failed(EditorWords.unreachable)
            case .rateLimited: phase = .failed(EditorWords.waitToRead)
            case .forbidden: phase = .failed(EditorWords.noAccess)
            case .unsupportedFormat: phase = .failed(DraftSession.Failure.notACatalog)
            }
        }

        func retry() async {
            phase = .loading
            await load()
        }

        /// A key from the choice of keys.
        func choose(_ choice: KeyChoice) async {
            key = choice.key
            catalog = choice.catalog
            phase = .loading
            start()
            await load()
        }

        /// Fills the fields from an entries answer. A field already typed in keeps its text.
        private func apply(_ entries: Entries) {
            guard let block = entries.catalog(matching: catalog) else { return }
            catalog = block.catalog
            sourceLocale = entries.sourceLocale
            let order = entries.locales.isEmpty ? block.languages.map(\.locale) : entries.locales
            let typed = Dictionary(uniqueKeysWithValues: fields.filter(\.isDirty).map { ($0.locale, $0.text) })
            var next: [Field] = []
            let ordered = order.sorted { a, b in rank(a, entries.sourceLocale) < rank(b, entries.sourceLocale) }
            for locale in ordered {
                guard let language = block.language(locale) else { continue }
                let original = language.current
                next.append(
                    Field(
                        locale: locale, isSource: locale == entries.sourceLocale, repoText: language.text,
                        original: original, text: typed[locale] ?? original, editable: language.editable,
                        reason: language.reason, outdated: language.outdated, hasDraft: language.draft != nil))
            }
            fields = next
        }

        /// The source first, then the language the app shows, then the rest in the project's order.
        private func rank(_ locale: String, _ source: String) -> Int {
            if locale == source { return 0 }
            if isShown(locale) { return 1 }
            return 2
        }

        private func isShown(_ locale: String) -> Bool {
            guard let shownLocale else { return false }
            return LocaleMatching.chain(for: shownLocale, available: [locale]).contains(locale)
        }

        // MARK: What the panel lists

        /// The fields open for typing: the source, the language the app shows, and any the person opened.
        var primary: [Field] { fields.filter { $0.isSource || isShown($0.locale) || promoted.contains($0.locale) } }

        /// The languages folded under Other languages.
        var others: [Field] { fields.filter { !($0.isSource || isShown($0.locale) || promoted.contains($0.locale)) } }

        var isDirty: Bool { fields.contains { $0.isDirty } }

        /// Saving the source makes the other languages outdated, as an edit in Dialecto's editor does.
        var outdatesOthers: Bool { fields.contains { $0.isSource && $0.isDirty } && !others.isEmpty }

        /// The text the app shows for the key while editing: the shown language's, else the source's.
        var liveText: String {
            (fields.first { isShown($0.locale) } ?? fields.first { $0.isSource })?.text ?? shownText
        }

        func open(_ locale: String) { promoted.insert(locale) }

        // MARK: Typing

        func type(_ text: String, in locale: String) {
            guard let at = fields.firstIndex(where: { $0.locale == locale }), fields[at].editable, !readOnly else { return }
            fields[at].text = text
            fields[at].error = nil
            if confirmingDiscard { confirmingDiscard = false }
            guard let catalog else { return }
            let cell = DraftLayer.Cell(catalog: catalog, key: key, locale: locale)
            // Back to what Dialecto holds: the saved draft or the release answers again.
            layer.setLocal(fields[at].isDirty ? text : nil, for: cell)
            LiveStore.shared.bump()
            onTyped?()
        }

        // MARK: Saving

        /// Saves each changed language, in order, and closes when all are saved. The first refusal stops the
        /// run and says why, with the typed text kept.
        func save() async {
            guard phase == .editing, !saving, !readOnly, let catalog else { return }
            let changed = fields.filter { $0.isDirty && $0.editable }
            guard !changed.isEmpty else {
                close()
                return
            }
            saving = true
            banner = nil
            defer { saving = false }
            for field in changed {
                let request = EditRequest(
                    catalog: catalog, key: key, locale: field.locale, text: field.text, replaces: field.original)
                let outcome = await session.save(request)
                guard let at = fields.firstIndex(where: { $0.locale == field.locale }) else { return }
                switch outcome {
                case .saved(let draft, _, _):
                    fields[at].original = field.text
                    fields[at].hasDraft = draft != nil
                    fields[at].error = nil
                    fields[at].conflict = nil
                    layer.setLocal(nil, for: DraftLayer.Cell(catalog: catalog, key: key, locale: field.locale))
                    LiveStore.shared.bump()
                case .conflict(let current):
                    fields[at].conflict = current
                    return
                case .pendingByOther:
                    readOnly = true
                    banner = .pendingByOther
                    return
                case .refused(let refusal):
                    fields[at].error = EditorWords.refusal(refusal)
                    return
                case .forbidden:
                    fields[at].error = EditorWords.noAccess
                    return
                case .notFound:
                    phase = .missing
                    return
                case .needsEditScope:
                    banner = .needsEditScope
                    return
                case .rateLimited:
                    banner = .rateLimited
                    return
                case .offline:
                    banner = .offline
                    return
                case .ended:
                    phase = .signedOut
                    return
                }
            }
            if !isDirty { close() }
        }

        /// 409: take Dialecto's text, dropping what was typed.
        func useTheirs(_ locale: String) {
            guard let at = fields.firstIndex(where: { $0.locale == locale }), let current = fields[at].conflict else { return }
            fields[at].original = current
            fields[at].conflict = nil
            type(current, in: locale)
        }

        /// 409: keep the typed text over Dialecto's, and save it again.
        func keepMine(_ locale: String) async {
            guard let at = fields.firstIndex(where: { $0.locale == locale }), let current = fields[at].conflict else { return }
            fields[at].original = current
            fields[at].conflict = nil
            await save()
        }

        // MARK: Closing

        /// Esc: drops a question first, then asks before unsaved text goes, then closes.
        func escape() {
            if confirmingDiscard {
                keepEditing()
            } else {
                requestClose()
            }
        }

        /// Cancel, the close button, a click elsewhere: asks first when there is unsaved text.
        func requestClose(then next: (() -> Void)? = nil) {
            if isDirty && !readOnly {
                afterDiscard = next
                confirmingDiscard = true
            } else {
                close()
                next?()
            }
        }

        func keepEditing() {
            confirmingDiscard = false
            afterDiscard = nil
        }

        /// Drops what was typed: the app redraws with Dialecto's text again.
        func discard() {
            let next = afterDiscard
            afterDiscard = nil
            confirmingDiscard = false
            close()
            next?()
        }

        /// Closes the panel. Typed text that was not saved goes with it.
        func close() {
            if let catalog {
                for field in fields where layer.hasLocal(DraftLayer.Cell(catalog: catalog, key: key, locale: field.locale)) {
                    layer.setLocal(nil, for: DraftLayer.Cell(catalog: catalog, key: key, locale: field.locale))
                }
                LiveStore.shared.bump()
            }
            onClose?()
        }

        /// A banner's action: sign in again, or try the save again.
        func signInAgain() {
            banner = nil
            phase = .signedOut
            session.signInAgain()
        }

        func retrySave() async {
            banner = nil
            await save()
        }
    }

    /// The editor's words for what Dialecto answered.
    enum EditorWords {
        static let unreachable = "Dialecto unreachable"
        static let waitToRead = "Wait a moment, then try again"
        static let noAccess = "No edit access to this language"

        /// A 422, under the field. Placeholders name the ones missing or extra.
        static func refusal(_ refusal: SaveRefusal) -> String {
            switch refusal.error {
            case "placeholders":
                var parts: [String] = []
                if !refusal.missing.isEmpty { parts.append("Add \(list(refusal.missing)) back.") }
                if !refusal.extra.isEmpty { parts.append("Remove \(list(refusal.extra)).") }
                return parts.isEmpty ? "The placeholders differ from the source." : parts.joined(separator: " ")
            case "not_editable", "plural_forms":
                return refusal.reason == "plural" || refusal.error == "plural_forms"
                    ? "Plural text is edited in Dialecto." : "This text is locked in Dialecto."
            case "read_only": return "The project is read-only."
            case "unknown_locale": return "The project has no such language."
            case "too_long": return "The text is too long."
            default: return "Dialecto refused this text."
            }
        }

        private static func list(_ items: [String]) -> String {
            switch items.count {
            case 0: ""
            case 1: items[0]
            default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
            }
        }

        /// A language's name in English, as Dialecto's editor names it.
        static func name(_ locale: String) -> String {
            Locale(identifier: "en").localizedString(forIdentifier: locale) ?? locale
        }
    }
#endif
