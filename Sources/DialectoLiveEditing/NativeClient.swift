#if DEBUG
    import Foundation

    /// What `POST /api/live/native/device` answers.
    struct DeviceGrant: Sendable, Equatable, Decodable {
        var deviceCode: String
        var userCode: String
        var verificationURI: URL
        var expiresIn: Int
        var interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }

        /// The project's id, which the verification link carries as `?project=` once the server knows the repo.
        var projectID: String? {
            URLComponents(url: verificationURI, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "project" }?.value
        }
    }

    /// One answer of the token poll.
    enum TokenPoll: Sendable, Equatable {
        case token(String, expiresIn: Int, projectID: String?, previewURL: URL? = nil)
        case pending
        case slowDown
        case expired
        case denied
    }

    /// What `GET /api/live/native/entry` answers.
    struct EntryLookup: Sendable, Equatable {
        var found: Bool
        var projectID: String?
    }

    /// One row of the drafts feed: a text to show, or the reason the server could not show it.
    struct DraftRow: Sendable, Equatable, Decodable {
        var catalog: String
        var key: String
        var locale: String
        var text: String?
        var skipped: String?
    }

    /// One answer of the drafts feed.
    enum FeedResult: Sendable, Equatable {
        case drafts(hash: String, rows: [DraftRow])
        case unchanged
        /// 401: the session is over (a bad token, or access lost). Drop the token.
        case ended(String)
        /// 422: the project's files are not a String Catalog, so there is no feed.
        case unsupportedFormat
        case rateLimited(retryAfter: TimeInterval)
    }

    enum NativeError: Error, Sendable, Equatable {
        case transport(String)
        case unexpected(status: Int)
        case malformed
    }

    /// The three calls of the native API, with nothing else in them.
    struct NativeClient: Sendable {
        var server: URL
        var session: URLSession

        /// A session whose requests may wait the server's 25 second long poll.
        static func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }

        /// `scope` is `edit` for a session that saves drafts from the app, `read` for one that only shows them.
        func startDevice(repo: String, scope: String = "edit") async throws -> DeviceGrant {
            let (status, data, _) = try await send(
                path: "api/live/native/device", method: "POST", json: ["repo": repo, "scope": scope])
            guard status == 200 else { throw NativeError.unexpected(status: status) }
            guard let grant = try? JSONDecoder().decode(DeviceGrant.self, from: data) else { throw NativeError.malformed }
            return grant
        }

        func pollToken(deviceCode: String) async throws -> TokenPoll {
            let (status, data, _) = try await send(
                path: "api/live/native/token", method: "POST", json: ["device_code": deviceCode])
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200 {
                guard let token = object?["access_token"] as? String else { throw NativeError.malformed }
                return .token(
                    token, expiresIn: object?["expires_in"] as? Int ?? 8 * 3600,
                    projectID: object?["project_id"] as? String,
                    previewURL: (object?["preview_url"] as? String).flatMap(URL.init(string:)))
            }
            guard status == 400 else { throw NativeError.unexpected(status: status) }
            switch object?["error"] as? String {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: throw NativeError.malformed
            }
        }

        /// Whether the project's catalog has `key`, and the project's id when the server says it.
        func entry(token: String, key: String) async throws -> EntryLookup {
            let (status, data, _) = try await send(
                path: "api/live/native/entry", method: "GET", query: [URLQueryItem(name: "key", value: key)],
                bearer: token)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch status {
            case 200: return EntryLookup(found: true, projectID: object?["project_id"] as? String)
            case 404: return EntryLookup(found: false, projectID: object?["project_id"] as? String)
            default: throw NativeError.unexpected(status: status)
            }
        }

        func feed(token: String, hash: String?) async throws -> FeedResult {
            var query: [URLQueryItem] = []
            if let hash { query.append(URLQueryItem(name: "hash", value: hash)) }
            let (status, data, headers) = try await send(
                path: "api/live/native/drafts", method: "GET", query: query, bearer: token)
            switch status {
            case 200:
                struct Body: Decodable {
                    var hash: String
                    var drafts: [DraftRow]
                }
                guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw NativeError.malformed }
                return .drafts(hash: body.hash, rows: body.drafts)
            case 304:
                return .unchanged
            case 401:
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return .ended(object?["error"] as? String ?? "invalid_token")
            case 422:
                return .unsupportedFormat
            case 429:
                return .rateLimited(retryAfter: headers["retry-after"].flatMap(TimeInterval.init) ?? 60)
            default:
                throw NativeError.unexpected(status: status)
            }
        }

        /// Every language's text of `key`, per catalog, with the person's own drafts.
        func entries(token: String, key: String) async throws -> EntriesOutcome {
            let (status, data, headers) = try await send(
                path: "api/live/native/entries", method: "GET", query: [URLQueryItem(name: "key", value: key)],
                bearer: token)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch status {
            case 200:
                guard let entries = try? JSONDecoder().decode(Entries.self, from: data) else { throw NativeError.malformed }
                return .found(entries)
            case 401: return .ended(object?["error"] as? String ?? "invalid_token")
            case 403: return .forbidden
            case 404: return .notFound
            case 422: return .unsupportedFormat
            case 429: return .rateLimited(retryAfter: headers["retry-after"].flatMap(TimeInterval.init) ?? 60)
            default: throw NativeError.unexpected(status: status)
            }
        }

        /// Saves one language's text as the person's draft.
        func save(token: String, _ edit: EditRequest) async throws -> SaveOutcome {
            let (status, data, headers) = try await send(
                path: "api/live/native/edits", method: "POST",
                json: [
                    "catalog": edit.catalog, "key": edit.key, "locale": edit.locale, "text": edit.text,
                    "replaces": edit.replaces,
                ],
                bearer: token)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? String
            switch status {
            case 200:
                struct Body: Decodable {
                    var draft: DraftRow?
                    var state: String?
                    var hash: String?
                }
                guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw NativeError.malformed }
                return .saved(draft: body.draft, state: body.state, hash: body.hash)
            case 401:
                return .ended(error ?? "invalid_token")
            case 403:
                return error == "needs_edit_scope" ? .needsEditScope : .forbidden
            case 404:
                return .notFound
            case 409:
                if error == "pending_by_other" { return .pendingByOther }
                let current = (object?["current"] as? [String: Any])?["text"] as? String
                guard error == "conflict", let current else { throw NativeError.malformed }
                return .conflict(current: current)
            case 422:
                return .refused(
                    SaveRefusal(
                        error: error ?? "not_saved", reason: object?["reason"] as? String,
                        missing: object?["missing"] as? [String] ?? [], extra: object?["extra"] as? [String] ?? []))
            case 429:
                return .rateLimited(retryAfter: headers["retry-after"].flatMap(TimeInterval.init) ?? 60)
            default:
                throw NativeError.unexpected(status: status)
            }
        }

        private func send(
            path: String, method: String, query: [URLQueryItem] = [], json: [String: String]? = nil, bearer: String? = nil
        ) async throws -> (Int, Data, [String: String]) {
            var components = URLComponents(
                url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw NativeError.malformed }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "accept")
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            }
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NativeError.malformed }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
                }
                return (http.statusCode, data, headers)
            } catch let error as NativeError {
                throw error
            } catch {
                throw NativeError.transport(error.localizedDescription)
            }
        }
    }
#endif
