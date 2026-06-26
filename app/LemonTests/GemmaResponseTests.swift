@testable import Lemon
import XCTest

final class GemmaResponseTests: XCTestCase {
    // MARK: - GemmaResponse decoding

    func testDecodesResponseWithNoAction() throws {
        let json = """
        {"state":"running","summary":"Making progress on CardView tokens","action":null}
        """
        let r = try decode(json)
        XCTAssertEqual(r.state, "running")
        XCTAssertEqual(r.summary, "Making progress on CardView tokens")
        XCTAssertNil(r.action)
    }

    func testDecodesResponseWithSendKeysAction() throws {
        let json = """
        {"state":"blocked_prompt","summary":"MCP server selection prompt",
         "action":{"type":"send_keys","keys":"\\r"}}
        """
        let r = try decode(json)
        XCTAssertEqual(r.state, "blocked_prompt")
        XCTAssertEqual(r.action?.type, "send_keys")
        XCTAssertEqual(r.action?.keys, "\r")
        XCTAssertNil(r.action?.message)
    }

    func testDecodesResponseWithNotifyUserAction() throws {
        let json = """
        {"state":"waiting","summary":"Needs human decision",
         "action":{"type":"notify_user","message":"Which auth strategy should I use?"}}
        """
        let r = try decode(json)
        XCTAssertEqual(r.action?.type, "notify_user")
        XCTAssertEqual(r.action?.message, "Which auth strategy should I use?")
        XCTAssertNil(r.action?.keys)
    }

    func testDecodesUnknownActionType() throws {
        let json = """
        {"state":"complete","summary":"All done",
         "action":{"type":"future_action_type","keys":null,"message":null}}
        """
        let r = try decode(json)
        XCTAssertEqual(r.action?.type, "future_action_type")
    }

    func testDecodesResponseMissingActionField() throws {
        // "action" key absent entirely — GemmaAction is optional so this must succeed
        let json = """
        {"state":"running","summary":"Still going"}
        """
        let r = try decode(json)
        XCTAssertNil(r.action)
    }

    func testThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try decode("not json at all"))
    }

    func testThrowsWhenRequiredFieldMissing() {
        // "state" is required
        XCTAssertThrowsError(try decode("""
        {"summary":"oops","action":null}
        """))
    }

    // MARK: - Two-layer decoding (OpenAI wrapper → inner JSON string)

    // LocalLLM.classify() decodes an outer ChatResponse, then decodes the
    // inner content string as GemmaResponse. Test that inner decoding round-trip works.

    func testInnerJSONStringDecodesCorrectly() throws {
        let innerJson = #"{"state":"stuck","summary":"Looks stuck","action":null}"#
        let data = Data(innerJson.utf8)
        let r = try JSONDecoder().decode(GemmaResponse.self, from: data)
        XCTAssertEqual(r.state, "stuck")
    }

    func testInnerJSONWithEscapedQuotes() throws {
        let innerJson = """
        {"state":"waiting","summary":"Needs \\"approval\\" for destructive change","action":null}
        """
        let r = try decode(innerJson)
        XCTAssertTrue(r.summary.contains("approval"))
    }

    // MARK: - GemmaResponse.parse robustness

    func testParseStripsMarkdownFenceWithJsonTag() throws {
        let raw = """
        ```json
        {"state":"running","summary":"All good","action":null}
        ```
        """
        let r = try GemmaResponse.parse(raw)
        XCTAssertEqual(r.state, "running")
        XCTAssertNil(r.action)
    }

    func testParseStripsPlainMarkdownFence() throws {
        let raw = """
        ```
        {"state":"complete","summary":"PR opened","action":null}
        ```
        """
        let r = try GemmaResponse.parse(raw)
        XCTAssertEqual(r.state, "complete")
    }

    func testParseExtractsFirstJsonObjectFromProse() throws {
        let raw = """
        Here is my analysis of the session:

        {"state":"blocked_prompt","summary":"MCP trust prompt","action":{"type":"send_keys","keys":"y"}}

        Let me know if you need more.
        """
        let r = try GemmaResponse.parse(raw)
        XCTAssertEqual(r.state, "blocked_prompt")
        XCTAssertEqual(r.action?.keys, "y")
    }

    func testParseHandlesPureJsonNoFenceNoProse() throws {
        let raw = #"{"state":"waiting","summary":"Needs review","action":null}"#
        let r = try GemmaResponse.parse(raw)
        XCTAssertEqual(r.state, "waiting")
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try GemmaResponse.parse("   \n  ")) { err in
            XCTAssertEqual(err as? GemmaResponse.ParseError, .empty)
        }
    }

    func testParseNoJSONThrows() {
        XCTAssertThrowsError(try GemmaResponse.parse("just some prose, no json here")) { err in
            XCTAssertEqual(err as? GemmaResponse.ParseError, .noJSON)
        }
    }

    func testParseMissingRequiredFieldThrowsDecodeFailed() {
        // "state" missing — decode should fail and surface as .decodeFailed
        XCTAssertThrowsError(try GemmaResponse.parse(#"{"summary":"oops"}"#)) { err in
            switch err as? GemmaResponse.ParseError {
            case .some(.decodeFailed): break
            default: XCTFail("Expected .decodeFailed, got \(err)")
            }
        }
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> GemmaResponse {
        try JSONDecoder().decode(GemmaResponse.self, from: Data(json.utf8))
    }
}
