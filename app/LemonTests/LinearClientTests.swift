import XCTest
@testable import Lemon

final class LinearClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func client() -> LinearClient { LinearClient(session: session) }

    // Minimal valid node JSON shared across tests
    private func node(
        id: String = "abc",
        identifier: String = "HRP-42",
        title: String = "Fix it",
        description: String? = "Details",
        labels: [String] = [],
        teamId: String = "team1"
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
        XCTAssertEqual(issues[0].identifier, "HRP-42")
        XCTAssertEqual(issues[0].description, "Details")
        XCTAssertEqual(issues[0].teamId, "team1")
    }

    func testFiltersIssuesWithActiveLemonLabels() async throws {
        // Issues already carrying an active Lemon label should be excluded
        let inProgress = node(id: "ip",  labels: [LinearClient.labelInProgress])
        let waiting    = node(id: "wt",  labels: [LinearClient.labelWaiting])
        let complete   = node(id: "cp",  labels: [LinearClient.labelComplete])
        let fresh      = node(id: "fr",  labels: [LinearClient.labelTrigger])
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
        let bad  = "{\"id\":\"bad\"}"   // missing identifier, title, team
        StubURLProtocol.respond(json: wrapped("\(good),\(bad)"))
        let issues = try await client().fetchLemonQueue(apiKey: "k", userId: "u")
        XCTAssertEqual(issues.map(\.id), ["good"])
    }

    // MARK: - parseLemonMarker

    func testParseLemonMarkerFallsBackToHostCommentId() {
        // Lemon Report comments don't know their own ID at write time, so the
        // marker omits `comment:` and the parser falls back to the host comment.
        let body = """
        ## 🍋 Lemon Report — HRP-42

        **PR:** [#101](https://github.com/x/y/pull/101)

        <!-- lemon
        branch: lemon/HRP-42
        pr: 101
        repo: /tmp/repo
        -->
        """
        let marker = client().parseLemonMarker(from: body, commentId: "host-comment-real-id")
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.commentId, "host-comment-real-id",
                       "Must use the host comment id when `comment:` is absent — re-trigger detection depends on it.")
        XCTAssertEqual(marker?.branch, "lemon/HRP-42")
        XCTAssertEqual(marker?.prNumber, "101")
        XCTAssertEqual(marker?.repoPath, "/tmp/repo")
    }

    func testParseLemonMarkerExplicitCommentIdWins() {
        // If a future code path does fill in the real comment id, honor it.
        let body = """
        <!-- lemon
        branch: lemon/HRP-7
        pr: 22
        comment: explicit-id
        repo: /tmp/r
        -->
        """
        let marker = client().parseLemonMarker(from: body, commentId: "host-id")
        XCTAssertEqual(marker?.commentId, "explicit-id")
    }

    func testParseLemonMarkerRejectsPlaceholder() {
        // Documents the bug we just fixed: a literal "PENDING" placeholder
        // poisons the re-trigger detection. The Lemon Report builder must
        // not emit `comment: PENDING`.
        let body = """
        <!-- lemon
        branch: lemon/HRP-1
        pr: 99
        comment: PENDING
        repo: /tmp/r
        -->
        """
        let marker = client().parseLemonMarker(from: body, commentId: "real-id")
        XCTAssertEqual(marker?.commentId, "PENDING",
                       "Parser honors what's written. Builder must not write a placeholder; see WorktreeRunner.buildLemonComment.")
    }

    func testParseLemonMarkerMissingFieldsReturnsNil() {
        let body = """
        <!-- lemon
        branch: lemon/HRP-1
        -->
        """
        XCTAssertNil(client().parseLemonMarker(from: body, commentId: "x"),
                     "Required pr + repo fields must be present.")
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _data = Data()
    nonisolated(unsafe) private static var _statusCode = 200
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)? = nil

    static func respond(json: String, statusCode: Int = 200) {
        _data = Data(json.utf8)
        _statusCode = statusCode
        // Does not clear onRequest — callers can set the hook before or after this call
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self._data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
