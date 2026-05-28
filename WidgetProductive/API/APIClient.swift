import Foundation

// MARK: - JSON:API generic envelope

struct JSONAPIEnvelope<D: Decodable>: Decodable {
    let data: D
    let included: [RawResource]?
    let meta: [String: AnyCodable]?
}

/// A single JSON:API resource before it's decoded into a domain type.
struct RawResource: Decodable {
    let id: String
    let type: String
    let attributes: [String: AnyCodable]?
    let relationships: [String: RelationshipEntry]?
}

struct RelationshipEntry: Decodable {
    let data: RelationshipLinkage?
}

enum RelationshipLinkage: Decodable {
    case one(ResourceIdentifier)
    case many([ResourceIdentifier])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let single = try? container.decode(ResourceIdentifier.self) {
            self = .one(single)
        } else {
            self = .many(try container.decode([ResourceIdentifier].self))
        }
    }
}

struct ResourceIdentifier: Decodable {
    let id: String
    let type: String
}

/// Erased Codable wrapper for arbitrary JSON values in attributes/meta.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: some Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { value = v; return }
        if let v = try? c.decode(Int.self)    { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v; return }
        if c.decodeNil() { value = NSNull(); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:                 try c.encode(v)
        case let v as Int:                  try c.encode(v)
        case let v as Double:               try c.encode(v)
        case let v as String:               try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]:         try c.encode(v)
        default:                            try c.encodeNil()
        }
    }

    // Convenience accessors
    var string: String?  { value as? String }
    var int: Int?        { value as? Int }
    var double: Double?  { value as? Double }
    var bool: Bool?      { value as? Bool }
    var isNull: Bool     { value is NSNull }
}

// MARK: - Errors

enum APIError: Error, LocalizedError {
    case http(statusCode: Int, body: String)
    case unauthorized
    case rateLimitExhausted
    case decodingError(Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .http(let c, let b):   "HTTP \(c): \(b)"
        case .unauthorized:         "HTTP 401 — check your auth token"
        case .rateLimitExhausted:   "Still rate-limited after retries"
        case .decodingError(let e): "Decode error: \(e)"
        case .invalidURL:           "Invalid URL"
        }
    }
}

// MARK: - APIClient

actor APIClient {

    // MARK: Configuration

    static let baseURL = URL(string: "https://api.productive.io/api/v2")!

    private let session: URLSession
    private let getAuthToken: @Sendable () throws -> String
    private let getOrgID:     @Sendable () throws -> String

    // Serial write queue: tasks run one at a time to respect Productive's rate limit.
    private var writeQueue: [CheckedContinuation<Void, Never>] = []
    private var writeBusy = false

    // MARK: Init

    init(
        session: URLSession = .shared,
        getAuthToken: @escaping @Sendable () throws -> String = { try Secrets.authToken() },
        getOrgID:     @escaping @Sendable () throws -> String = { try Secrets.orgID() }
    ) {
        self.session = session
        self.getAuthToken = getAuthToken
        self.getOrgID = getOrgID
    }

    // MARK: GET (reads go straight through — no queue)

    func get<D: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        as type: D.Type = D.self
    ) async throws -> JSONAPIEnvelope<D> {
        let req = try makeRequest(method: "GET", path: path, query: query)
        let data = try await fetch(req, retries: 3)
        return try decode(data, as: JSONAPIEnvelope<D>.self)
    }

    /// Raw GET — returns Data without decoding (used by probes).
    func getRaw(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let req = try makeRequest(method: "GET", path: path, query: query)
        return try await fetch(req, retries: 3)
    }

    // MARK: Writes (POST / PATCH / DELETE) — sequential, 429-aware

    func post<Body: Encodable, D: Decodable>(
        path: String,
        body: Body,
        as type: D.Type = D.self
    ) async throws -> JSONAPIEnvelope<D> {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let req = try makeRequest(method: "POST", path: path, body: body)
        let data = try await fetch(req, retries: 5)
        return try decode(data, as: JSONAPIEnvelope<D>.self)
    }

    func patch<Body: Encodable, D: Decodable>(
        path: String,
        body: Body,
        as type: D.Type = D.self
    ) async throws -> JSONAPIEnvelope<D> {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let req = try makeRequest(method: "PATCH", path: path, body: body)
        let data = try await fetch(req, retries: 5)
        return try decode(data, as: JSONAPIEnvelope<D>.self)
    }

    func delete(path: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let req = try makeRequest(method: "DELETE", path: path)
        _ = try await fetch(req, retries: 5)
    }

    // MARK: Private — request builder

    private func makeRequest<Body: Encodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Body
    ) throws -> URLRequest {
        var req = try baseRequest(method: method, path: path, query: query)
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        try baseRequest(method: method, path: path, query: query)
    }

    private func baseRequest(
        method: String,
        path: String,
        query: [URLQueryItem]
    ) throws -> URLRequest {
        guard var comps = URLComponents(
            url: Self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(try getAuthToken(), forHTTPHeaderField: "X-Auth-Token")
        req.setValue(try getOrgID(), forHTTPHeaderField: "X-Organization-Id")
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: Private — fetch with 429 backoff

    private func fetch(_ req: URLRequest, retries: Int) async throws -> Data {
        var attempt = 0
        var delay: TimeInterval = 1.0
        while true {
            let (data, response) = try await session.data(for: req)
            let http = response as! HTTPURLResponse
            switch http.statusCode {
            case 200...299:
                return data
            case 401:
                throw APIError.unauthorized
            case 429:
                attempt += 1
                if attempt >= retries { throw APIError.rateLimitExhausted }
                // Honor Retry-After header when present.
                if let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Double(retryAfter) {
                    delay = seconds
                }
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            default:
                let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
                throw APIError.http(statusCode: http.statusCode, body: body)
            }
        }
    }

    // MARK: Private — decode

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: Private — sequential write lock (actor-isolated mutex)

    private func acquireWriteLock() async {
        guard writeBusy else { writeBusy = true; return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.append(cont)
        }
        // Resumed by releaseWriteLock; writeBusy is still true — we now own the lock.
    }

    private func releaseWriteLock() {
        if let next = writeQueue.first {
            writeQueue.removeFirst()
            next.resume()
            // writeBusy stays true — ownership transferred to the resumed task.
        } else {
            writeBusy = false
        }
    }
}
