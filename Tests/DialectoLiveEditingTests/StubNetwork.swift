#if DEBUG
    import Foundation
    import os

    @testable import DialectoLiveEditing

    struct StubReply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""

        static func json(_ status: Int = 200, _ body: String, headers: [String: String] = [:]) -> StubReply {
            StubReply(status: status, headers: headers, body: body)
        }
    }

    /// Answers a test's own host from a script: each `METHOD /path` takes its replies in order, and the
    /// last one repeats. Nothing reaches the network.
    final class StubNetwork: URLProtocol {
        struct Script: Sendable {
            var replies: [String: [StubReply]] = [:]
            var requests: [String] = []
            var authorization: [String] = []
        }

        static let scripts = OSAllocatedUnfairLock<[String: Script]>(initialState: [:])

        override class func canInit(with request: URLRequest) -> Bool {
            guard let host = request.url?.host else { return false }
            return scripts.withLock { $0[host] != nil }
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let host = url.host else { return }
            let plain = "\(request.httpMethod ?? "GET") \(url.path)"
            let full = url.query.map { "\(plain)?\($0)" } ?? plain
            let header = request.value(forHTTPHeaderField: "authorization")
            let reply: StubReply? = Self.scripts.withLock { all in
                guard var script = all[host] else { return nil }
                script.requests.append(full)
                if let header { script.authorization.append(header) }
                // A script line for the exact query wins over one for the bare path.
                let key = script.replies[full] != nil ? full : plain
                guard var queue = script.replies[key], let first = queue.first else {
                    all[host] = script
                    return nil
                }
                if queue.count > 1 { queue.removeFirst() }
                script.replies[key] = queue
                all[host] = script
                return first
            }
            guard let reply else {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// One test's server: a unique host, a script and a client that only reaches the stub.
    final class StubServer: Sendable {
        let host = "h\(UUID().uuidString.prefix(8).lowercased()).test"

        init(_ replies: [String: [StubReply]]) {
            let host = host
            StubNetwork.scripts.withLock { $0[host] = StubNetwork.Script(replies: replies) }
        }

        deinit {
            let host = host
            StubNetwork.scripts.withLock { $0[host] = nil }
        }

        var url: URL { URL(string: "https://\(host)")! }

        var client: NativeClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubNetwork.self]
            return NativeClient(server: url, session: URLSession(configuration: configuration))
        }

        var requests: [String] { StubNetwork.scripts.withLock { $0[host]?.requests ?? [] } }
        var authorization: [String] { StubNetwork.scripts.withLock { $0[host]?.authorization ?? [] } }
    }
#endif
