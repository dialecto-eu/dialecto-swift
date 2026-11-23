#if DEBUG
    import Foundation
    import Security
    import os

    /// What a signed-in session keeps between launches.
    struct StoredSession: Codable, Sendable, Equatable {
        var token: String
        var expiresAt: Date
        var projectID: String?
        /// Dialecto's pull request page for the project, where Preview pull request goes.
        var previewURL: URL? = nil
    }

    /// Somewhere that holds one secret per project.
    protocol SecretBackend: Sendable {
        func read(account: String) throws -> Data?
        func write(_ data: Data, account: String) throws
        func delete(account: String) throws
    }

    struct KeychainFailure: Error, Equatable { var status: OSStatus }

    /// The four Keychain calls the backend makes, so a test can stand in for the system.
    protocol KeychainAPI: Sendable {
        func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus
        func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
        func add(_ attributes: CFDictionary) -> OSStatus
        func delete(_ query: CFDictionary) -> OSStatus
    }

    /// The system's Keychain. Only a real signed app should reach this: an unsigned binary gets a Keychain
    /// prompt on every rebuild, so demos and tests choose another backend.
    struct SystemKeychain: KeychainAPI {
        func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
            SecItemCopyMatching(query, &result)
        }
        func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
        func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
        func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
    }

    /// Holds nothing: the store's own memory keeps the token for the run.
    struct MemoryOnlyBackend: SecretBackend {
        func read(account: String) throws -> Data? { nil }
        func write(_ data: Data, account: String) throws {}
        func delete(account: String) throws {}
    }

    /// A JSON file of secrets, for a demo or a headless run that must not touch the Keychain.
    struct FileBackend: SecretBackend {
        var url: URL

        struct Refused: Error, Equatable { var reason: String }

        /// The file must be absent, or a regular file of this user's, never a link.
        private func check() throws -> Bool {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw Refused(reason: "cannot inspect the token file")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw Refused(reason: "the token file is not a regular file") }
            guard info.st_uid == getuid() else { throw Refused(reason: "the token file belongs to another user") }
            return true
        }

        private func load() throws -> [String: Data] {
            guard try check() else { return [:] }
            return (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
        }

        func read(account: String) throws -> Data? { try load()[account] }

        func write(_ data: Data, account: String) throws {
            var all = try load()
            all[account] = data
            try save(all)
        }

        func delete(account: String) throws {
            var all = try load()
            all[account] = nil
            try save(all)
        }

        /// A temporary file opened owner-only (0600) in the same folder, then renamed over the target, so the
        /// token is never readable by anyone else, not even for a moment.
        private func save(_ all: [String: Data]) throws {
            _ = try check()
            let body = try JSONEncoder().encode(all)
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw Refused(reason: "cannot create the token file") }
            var complete = false
            defer {
                close(descriptor)
                if !complete { unlink(temp.path) }
            }
            let written = body.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, body.count) }
            guard written == body.count, fsync(descriptor) == 0 else { throw Refused(reason: "cannot write the token file") }
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: temp.path)
            #endif
            guard rename(temp.path, url.path) == 0 else { throw Refused(reason: "cannot replace the token file") }
            complete = true
        }
    }

    /// The Keychain, a generic password per project.
    struct KeychainBackend: SecretBackend {
        static let service = "eu.dialecto.live-editing"
        var api: any KeychainAPI = SystemKeychain()

        private func query(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
            ]
        }

        func read(account: String) throws -> Data? {
            var found = query(account)
            found[kSecReturnData as String] = true
            found[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = api.copyMatching(found as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
            return result as? Data
        }

        func write(_ data: Data, account: String) throws {
            let update = api.update(
                query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw KeychainFailure(status: update) }
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = api.add(add as CFDictionary)
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        }

        func delete(account: String) throws {
            let status = api.delete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        }
    }

    /// The drafts token's home: the Keychain when it works. On any Keychain error the token is held in
    /// memory for the run, and the person signs in again at the next launch.
    final class TokenStore: Sendable {
        private let backend: any SecretBackend
        private let memory = OSAllocatedUnfairLock<[String: StoredSession]>(initialState: [:])
        private let now: @Sendable () -> Date

        init(backend: any SecretBackend = KeychainBackend(), now: @escaping @Sendable () -> Date = { Date() }) {
            self.backend = backend
            self.now = now
        }

        /// The session held for `project`, unless it has run out.
        func load(project: String) -> StoredSession? {
            let account = project.lowercased()
            let held =
                memory.withLock { $0[account] }
                ?? ((try? backend.read(account: account)).flatMap { $0 }.flatMap {
                    try? JSONDecoder().decode(StoredSession.self, from: $0)
                })
            guard let held, held.expiresAt > now() else {
                if held != nil { forget(project: project) }
                return nil
            }
            return held
        }

        /// Keeps `session`; returns true when it reached the Keychain, false when only memory holds it.
        @discardableResult
        func save(_ session: StoredSession, project: String) -> Bool {
            let account = project.lowercased()
            memory.withLock { $0[account] = session }
            do {
                try backend.write(try JSONEncoder().encode(session), account: account)
                return true
            } catch {
                return false
            }
        }

        func forget(project: String) {
            let account = project.lowercased()
            memory.withLock { $0[account] = nil }
            try? backend.delete(account: account)
        }
    }
#endif
