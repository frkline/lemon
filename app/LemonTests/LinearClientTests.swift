@testable import Lemon
import XCTest

final class LinearClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func client() -> LinearClient {
        LinearClient(session: session)
    }

    /// Minimal valid node JSON shared across tests
    private func node(
        id: String = "abc",
        identifier: String = "DEMO-42",
        title: String = "Fix it",
        description: String? = "Details",
        labels: [String] = [],
        teamId: String = "team1",
    ) -> String {
        let labelNodes = labels.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        let desc = description.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","identifier":"\(identifier)","title":"\(title)",\
        "description":\(desc),"labels":{"nodes":[\(labelNodes)]},\
        "team":{"id":"\(teamId)"},"state":{"type":"started"}}
        """
    }

    private func wrapped(_ nodes: String) -> String {
        "{\"data\":{\"issues\":{\"nodes\":[\(nodes)]}}}"
    }

    func testParsesValidIssue() async throws {
        StubURLProtocol.respond(json: wrapped(node()))
        let issues = try await client().fetchLemonQueue(apiKey: "k", userId: "u")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].id, "abc")
        XCTAssertEqual(issues[0].identifier, "DEMO-42")
        XCTAssertEqual(issues[0].description, "Details")
        XCTAssertEqual(issues[0].teamId, "team1")
    }

    func testFiltersIssuesWithActiveLemonLabels() async throws {
        // Issues already carrying an active Lemon label should be excluded
        let inProgress = node(id: "ip", labels: [LinearClient.labelInProgress])
        let waiting = node(id: "wt", labels: [LinearClient.labelWaiting])
        let complete = node(id: "cp", labels: [LinearClient.labelComplete])
        let fresh = node(id: "fr", labels: [LinearClient.labelTrigger])
        StubURLProtocol.respond(json: wrapped("\(inProgress),\(waiting),\(complete),\(fresh)"))
        let issues = try await client().fetchLemonQueue(apiKey: "k", userId: "u")
        XCTAssertEqual(issues.map(\.id), ["fr"])
    }

    func testThrowsOnNon200() async throws {
        StubURLProtocol.respond(json: "{}", statusCode: 401)
        do {
            _ = try await client().fetchLemonQueue(apiKey: "bad", userId: "u")
            XCTFail("Expected throw")
        } catch {
            XCTAssertTrue(error is LinearClient.LinearError)
        }
    }

    func testSkipsNodesWithMissingRequiredFields() async throws {
        // Node missing teamId should be dropped
        StubURLProtocol.respond(json: "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"nope\"}]}}}")
        let issues = try await client().fetchLemonQueue(apiKey: "k", userId: "u")
        XCTAssertTrue(issues.isEmpty)
    }

    func testMixedValidAndInvalidNodes() async throws {
        let good = node(id: "good")
        let bad = "{\"id\":\"bad\"}" // missing identifier, title, team
        StubURLProtocol.respond(json: wrapped("\(good),\(bad)"))
        let issues = try await client().fetchLemonQueue(apiKey: "k", userId: "u")
        XCTAssertEqual(issues.map(\.id), ["good"])
    }

    // Marker parsing tests live in LemonMarkerExtractorTests.
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var _data = Data()
    private nonisolated(unsafe) static var _statusCode = 200
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?

    static func respond(json: String, statusCode: Int = 200) {
        _data = Data(json.utf8)
        _statusCode = statusCode
        // Does not clear onRequest — callers can set the hook before or after this call
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // URLProtocol moves httpBody into httpBodyStream — read both so callers see the body.
        if let hook = Self.onRequest {
            var req = request
            if let stream = request.httpBodyStream {
                var bodyData = Data()
                stream.open()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n > 0 { bodyData.append(buf, count: n) }
                }
                buf.deallocate()
                stream.close()
                req.httpBody = bodyData
            }
            hook(req)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self._statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self._data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
