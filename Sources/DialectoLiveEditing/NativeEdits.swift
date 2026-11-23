#if DEBUG
    import Foundation

    /// What `GET /api/live/native/entries?key=` answers: every language's text of one key, per catalog.
    struct Entries: Sendable, Equatable, Decodable {
        var key: String
        var sourceLocale: String
        var locales: [String]
        var previewURL: URL?
        var catalogs: [EntryCatalog]

        enum CodingKeys: String, CodingKey {
            case key, locales, catalogs
            case sourceLocale = "source_locale"
            case previewURL = "preview_url"
        }

        /// The catalog block a lookup in `catalog` reads: the same name, or the release's path name of it.
        func catalog(matching catalog: String?) -> EntryCatalog? {
            guard let catalog else { return catalogs.first }
            return catalogs.first { sameCatalog($0.catalog, catalog) } ?? catalogs.first
        }
    }

    struct EntryCatalog: Sendable, Equatable, Decodable {
        var catalog: String
        var languages: [EntryLanguage]

        func language(_ locale: String) -> EntryLanguage? { languages.first { $0.locale == locale } }
    }

    struct EntryLanguage: Sendable, Equatable, Decodable {
        var locale: String
        /// The repository's text; empty when the language has none.
        var text: String
        var outdated: Bool
        var editable: Bool
        /// The person's own pending draft, when it differs from the repository's text.
        var draft: EntryDraft?
        /// Why it can't be saved here: `plural`, `variation`, `not_translatable`, `no_permission`.
        var reason: String?

        /// The text the person sees, and what a save `replaces`: their draft, else the repository's.
        var current: String { draft?.text ?? text }
    }

    struct EntryDraft: Sendable, Equatable, Decodable {
        var text: String
        var state: String?
    }

    /// One save of `POST /api/live/native/edits`.
    struct EditRequest: Sendable, Equatable {
        var catalog: String
        var key: String
        var locale: String
        var text: String
        /// The text the person saw before typing.
        var replaces: String
    }

    /// A 422 of a save: the check that refused it, with the placeholders when they were the reason.
    struct SaveRefusal: Sendable, Equatable {
        var error: String
        var reason: String?
        var missing: [String] = []
        var extra: [String] = []
    }

    enum SaveOutcome: Sendable, Equatable {
        /// `draft` is nil when the text went back to the repository's.
        case saved(draft: DraftRow?, state: String?, hash: String?)
        /// 403: a token from before edit scopes. Sign in again.
        case needsEditScope
        /// 403: no edit access to that language.
        case forbidden
        case notFound
        /// 409: the text is no longer the one the person saw.
        case conflict(current: String)
        /// 409: someone else has an unmerged change on the key.
        case pendingByOther
        case refused(SaveRefusal)
        case rateLimited(retryAfter: TimeInterval)
        /// 401: the session is over.
        case ended(String)
        /// Dialecto could not be reached; nothing was saved.
        case offline
    }

    enum EntriesOutcome: Sendable, Equatable {
        case found(Entries)
        case notFound
        case forbidden
        case unsupportedFormat
        case rateLimited(retryAfter: TimeInterval)
        case ended(String)
        case offline
    }
#endif
