import Foundation

/// Minimal URLSession stub for unit tests. Intercepts data(for:) calls.
final class StubURLSession: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let handler: Handler
    let urlSession: URLSession

    init(handler: @escaping Handler) {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        self.urlSession = URLSession(configuration: config)
        StubURLProtocol.handler = handler
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // Single-slot handler — tests run serially so this is safe.
    nonisolated(unsafe) static var handler: StubURLSession.Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let req = request
        Task {
            do {
                let (data, response) = try await handler(req)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
