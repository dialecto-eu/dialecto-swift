import CryptoKit
import Foundation
import os

@testable import DialectoLive

struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var failure: URLError.Code?
}

/// Answers `URLSession` requests for a test's own host, so no test reaches the internet.
final class StubNetwork: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let answer = handler(request)
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One test's channel: files served at `https://<host>/v1/production/`, a fresh cache folder, a session
/// that only reaches the stub, and a log of what was asked for.
final class Harness: Sendable {
    struct State: Sendable {
        var served: [String: Data] = [:]
        var etag: String?
        var offline = false
        var requests: [String] = []
    }

    let host = "h\(UUID().uuidString.prefix(8).lowercased()).test"
    let state = OSAllocatedUnfairLock(initialState: State())
    let errors = OSAllocatedUnfairLock(initialState: [DialectoLiveError]())
    let cacheRoot: URL
    let session: URLSession

    init(served: [String: Data] = [:], etag: String? = nil, cacheRoot: URL? = nil) {
        state.withLock {
            $0.served = served
            $0.etag = etag
        }
        self.cacheRoot =
            cacheRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("dialecto-live-test-\(UUID().uuidString)")

        let state = self.state
        let host = self.host
        StubNetwork.handlers.withLock {
            $0[host] = { request in
                let path = String(request.url!.path.dropFirst("/v1/production/".count))
                return state.withLock { s in
                    s.requests.append(path)
                    if s.offline { return StubResponse(failure: .notConnectedToInternet) }
                    guard let body = s.served[path] else { return StubResponse(status: 404) }
                    var headers: [String: String] = [:]
                    if path == "manifest.json", let etag = s.etag {
                        if request.value(forHTTPHeaderField: "If-None-Match") == etag { return StubResponse(status: 304) }
                        headers["ETag"] = etag
                    }
                    return StubResponse(headers: headers, body: body)
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubNetwork.self]
        session = URLSession(configuration: configuration)
    }

    func serve(_ served: [String: Data], etag: String? = nil) {
        state.withLock {
            $0.served = served
            $0.etag = etag
        }
    }

    func setOffline(_ offline: Bool) { state.withLock { $0.offline = offline } }
    var requests: [String] { state.withLock { $0.requests } }
    func clearRequests() { state.withLock { $0.requests = [] } }
    var reported: [DialectoLiveError.Code] { errors.withLock { $0.map(\.code) } }

    func configuration(
        publicKeys: [String], language: String? = "de-DE", builtAt: String? = nil
    ) -> LiveConfiguration {
        let errors = self.errors
        var configuration = try! LiveConfiguration.make(
            channel: "production", publicKeys: publicKeys, builtAt: builtAt,
            baseURL: URL(string: "https://\(host)/v1/")!, onError: { error in errors.withLock { $0.append(error) } }
        ).get()
        configuration.session = session
        configuration.cacheRoot = cacheRoot
        configuration.language = { language }
        return configuration
    }

    @MainActor
    func launch(
        publicKeys: [String], language: String? = "de-DE", builtAt: String? = nil, watching: Bool = false
    ) -> LiveRuntime {
        LiveRuntime.launch(configuration(publicKeys: publicKeys, language: language, builtAt: builtAt), watching: watching)
    }

    deinit {
        StubNetwork.handlers.withLock { _ = $0.removeValue(forKey: host) }
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}
