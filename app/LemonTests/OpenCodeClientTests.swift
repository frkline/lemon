@testable import Lemon
import XCTest

final class OpenCodeClientTests: XCTestCase {
    func testBaseURLUsesHostAndPort() {
        let client = OpenCodeClient(host: "127.0.0.1", port: 4096)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:4096")
    }

    func testBaseURLSupportsCustomHostPort() {
        let client = OpenCodeClient(host: "localhost", port: 5001)
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:5001")
    }

    func testClassifyLivenessTerminalByStatusString() {
        let payload: [String: Any] = ["status": "completed"]
        XCTAssertEqual(OpenCodeClient.classifyLiveness(payload: payload), .terminal)
    }

    func testClassifyLivenessTerminalByBoolean() {
        let payload: [String: Any] = ["session": ["done": true]]
        XCTAssertEqual(OpenCodeClient.classifyLiveness(payload: payload), .terminal)
    }

    func testClassifyLivenessActiveByStatusString() {
        let payload: [String: Any] = ["state": "running"]
        XCTAssertEqual(OpenCodeClient.classifyLiveness(payload: payload), .active)
    }

    func testClassifyLivenessUnknownForEmptyPayload() {
        XCTAssertEqual(OpenCodeClient.classifyLiveness(payload: [:]), .unknown)
    }

    func testExtractModelIDsFromV1ModelsPayload() throws {
        let json = """
        {
          "data": [
            { "id": "openai/gpt-5.3-codex" },
            { "id": "anthropic/claude-sonnet-4" }
          ]
        }
        """
        let ids = try OpenCodeClient.extractModelIDs(from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(ids, ["openai/gpt-5.3-codex", "anthropic/claude-sonnet-4"])
    }

    func testExtractModelIDsSkipsMimeTypes() throws {
        let json = """
        {
          "contentType": "application/json",
          "models": [
            { "name": "openai/gpt-4.1-mini" },
            { "name": "text/plain" }
          ]
        }
        """
        let ids = try OpenCodeClient.extractModelIDs(from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(ids, ["openai/gpt-4.1-mini"])
    }
}
