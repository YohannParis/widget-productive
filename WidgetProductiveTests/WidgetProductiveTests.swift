import Testing
import Foundation
import os
@testable import WidgetProductive

@Test func scaffoldBuilds() {
    #expect(Bool(true))
}

// MARK: - Secrets / .env parser

@Test func dotenvParserBasic() throws {
    // Write a synthetic .env to a temp file and parse it.
    let raw = """
    PRODUCTIVE_AUTH_TOKEN=tok123
    PRODUCTIVE_ORG_ID=  org456
    PRODUCTIVE_EMAIL="alice@example.com"
    # comment line
    PRODUCTIVE_PERSON_ID='789'
    EMPTY_VALUE=
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_\(UUID().uuidString).env")
    try raw.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let parsed = try Secrets.Testable.parseDotenv(at: url.path)
    #expect(parsed["PRODUCTIVE_AUTH_TOKEN"] == "tok123")
    #expect(parsed["PRODUCTIVE_ORG_ID"] == "org456")
    #expect(parsed["PRODUCTIVE_EMAIL"] == "alice@example.com")
    #expect(parsed["PRODUCTIVE_PERSON_ID"] == "789")
    #expect(parsed["EMPTY_VALUE"] == "")
    #expect(parsed["# comment line"] == nil)
}

// MARK: - AnyCodable

@Test func anyCodableRoundtrip() throws {
    let json = """
    {"str":"hello","num":42,"flag":true,"nested":{"x":1.5},"arr":[1,2]}
    """
    let decoded = try JSONDecoder().decode([String: AnyCodable].self,
                                          from: Data(json.utf8))
    #expect(decoded["str"]?.string == "hello")
    #expect(decoded["num"]?.int == 42)
    #expect(decoded["flag"]?.bool == true)
}

// MARK: - JSONAPIEnvelope decoding

@Test func jsonAPIEnvelopeSingleResource() throws {
    let json = """
    {
      "data": {
        "id": "1",
        "type": "people",
        "attributes": { "name": "Alice", "email": "alice@example.com" },
        "relationships": {
          "company": { "data": { "id": "99", "type": "companies" } }
        }
      },
      "included": []
    }
    """
    let envelope = try JSONDecoder().decode(
        JSONAPIEnvelope<RawResource>.self,
        from: Data(json.utf8)
    )
    #expect(envelope.data.id == "1")
    #expect(envelope.data.type == "people")
    #expect(envelope.data.attributes?["name"]?.string == "Alice")
    let rel = envelope.data.relationships?["company"]
    if case .one(let id) = rel?.data {
        #expect(id.id == "99")
        #expect(id.type == "companies")
    } else {
        Issue.record("Expected single relationship linkage")
    }
}

@Test func jsonAPIEnvelopeArray() throws {
    let json = """
    {
      "data": [
        { "id": "1", "type": "time_entries", "attributes": { "minutes": 480 } },
        { "id": "2", "type": "time_entries", "attributes": { "minutes": 240 } }
      ]
    }
    """
    let envelope = try JSONDecoder().decode(
        JSONAPIEnvelope<[RawResource]>.self,
        from: Data(json.utf8)
    )
    #expect(envelope.data.count == 2)
    #expect(envelope.data[0].attributes?["minutes"]?.int == 480)
}

// MARK: - APIClient 429 backoff (stub session)

@Test func apiClient429Backoff() async throws {
    let counter = OSAllocatedUnfairLock(initialState: 0)
    let session = StubURLSession { _ in
        let n = counter.withLock { state -> Int in state += 1; return state }
        if n < 3 {
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.productive.io/api/v2/people")!,
                statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "0"]  // 0s so test runs fast
            )!
            return (Data(), resp)
        }
        let body = #"{"data":[]}"#
        let resp = HTTPURLResponse(
            url: URL(string: "https://api.productive.io/api/v2/people")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), resp)
    }

    let client = APIClient(
        session: session.urlSession,
        getAuthToken: { "tok" },
        getOrgID: { "org" }
    )
    let data = try await client.getRaw(path: "/people")
    let finalCount = counter.withLock { $0 }
    #expect(finalCount == 3)
    #expect(!data.isEmpty)
}
