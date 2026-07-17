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

    func testCuratedCodingModelIDsFiltersNonCodingModels() {
        let items = [
            OpenCodeModelCatalogItem(displayID: "openai/text-embedding-3-small", providerID: "openai", modelID: "text-embedding-3-small", name: nil, family: nil, status: "active", isTextInput: true, isTextOutput: false, supportsTools: false),
            OpenCodeModelCatalogItem(displayID: "openai/gpt-image-1", providerID: "openai", modelID: "gpt-image-1", name: nil, family: nil, status: "active", isTextInput: true, isTextOutput: false, supportsTools: false),
            OpenCodeModelCatalogItem(displayID: "openai/gpt-5.3-codex", providerID: "openai", modelID: "gpt-5.3-codex", name: nil, family: nil, status: "active", isTextInput: true, isTextOutput: true, supportsTools: true),
            OpenCodeModelCatalogItem(displayID: "openai/gpt-4.1", providerID: "openai", modelID: "gpt-4.1", name: nil, family: nil, status: "active", isTextInput: true, isTextOutput: true, supportsTools: true),
        ]
        XCTAssertEqual(OpenCodeClient.curatedCodingModelIDs(items), [
            "openai/gpt-5.3-codex",
            "openai/gpt-4.1",
        ])
    }
}
