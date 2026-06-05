import XCTest
@testable import Lemon

final class LocalLLMTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func llm() -> LocalLLM {
        LocalLLM.makeForTesting(port: 8488, session: session)
    }

    private func stubResponse(state: String, summary: String, action: String = "null") {
        let inner = #"{"state":"\#(state)","summary":"\#(summary)","action":\#(action)}"#
        let outer = """
        {"choices":[{"message":{"content":\(jsonString(inner))}}]}
        """
        StubURLProtocol.respond(json: outer)
    }

    private func jsonString(_ s: String) -> String {
        // Escape the inner JSON string for embedding in the outer JSON
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func issue() -> IssueRef {
        IssueRef(id: "t1", identifier: "TEST-1", title: "Test issue",
                 description: "Do something", labelNames: [],
                 scope: .linearTeam(id: "team1"))
    }

    // MARK: - classify()

    func testClassifyDecodesRunningState() async throws {
        stubResponse(state: "running", summary: "Making progress")
        let result = try await llm().classify(issue: issue(), logLines: ["doing stuff"])
        XCTAssertEqual(result.state,   "running")
        XCTAssertEqual(result.summary, "Making progress")
        XCTAssertNil(result.action)
    }

    func testClassifyDecodesSendKeysAction() async throws {
        let action = #"{"type":"send_keys","keys":"\r"}"#
        stubResponse(state: "blocked_prompt", summary: "MCP prompt", action: action)
        let result = try await llm().classify(issue: issue(), logLines: [])
        XCTAssertEqual(result.action?.type, "send_keys")
        XCTAssertEqual(result.action?.keys, "\r")
    }

    func testClassifyDecodesNotifyAction() async throws {
        let action = #"{"type":"notify_user","message":"Need your input"}"#
        stubResponse(state: "waiting", summary: "Blocked on auth", action: action)
        let result = try await llm().classify(issue: issue(), logLines: [])
        XCTAssertEqual(result.action?.type,    "notify_user")
        XCTAssertEqual(result.action?.message, "Need your input")
    }

    func testClassifyThrowsOnNon200() async {
        StubURLProtocol.respond(json: "{}", statusCode: 500)
        do {
            _ = try await llm().classify(issue: issue(), logLines: [])
            // URLSession throws on non-2xx, so we expect an error
            // (actually URLSession.data does NOT throw on non-2xx — it returns the body)
            // The inner decode will fail since "{}" isn't a valid ChatResponse
            XCTFail("Should have thrown")
        } catch {
            // Good — either a network error or a decode error
        }
    }

    func testClassifyThrowsWhenNoChoices() async {
        StubURLProtocol.respond(json: """
        {"choices":[]}
        """)
        do {
            _ = try await llm().classify(issue: issue(), logLines: [])
            XCTFail("Should have thrown — no choices")
        } catch let e as LocalLLMError {
            XCTAssertEqual(e, .invalidResponse)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testClassifyThrowsWhenInnerJSONIsInvalid() async {
        let outer = #"{"choices":[{"message":{"content":"not valid json"}}]}"#
        StubURLProtocol.respond(json: outer)
        do {
            _ = try await llm().classify(issue: issue(), logLines: [])
            XCTFail("Should have thrown — inner JSON invalid")
        } catch {
            // Any DecodingError is acceptable
        }
    }

    func testClassifySendsIssueContextInRequest() async throws {
        stubResponse(state: "running", summary: "ok")
        RequestBodyCapture.last = nil
        StubURLProtocol.onRequest = { req in
            RequestBodyCapture.last = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        }
        _ = try? await llm().classify(issue: issue(), logLines: ["line one"])
        let body = RequestBodyCapture.last ?? ""
        XCTAssertTrue(body.contains("TEST-1"), "Request body should include issue identifier")
        XCTAssertTrue(body.contains("line one"), "Request body should include log lines")
        StubURLProtocol.onRequest = nil
    }

    func testIsReadyReturnsTrueForTestInstance() {
        XCTAssertTrue(llm().isReady())
    }
}

// Capture the last request body for inspection
enum RequestBodyCapture {
    nonisolated(unsafe) static var last: String?
}
