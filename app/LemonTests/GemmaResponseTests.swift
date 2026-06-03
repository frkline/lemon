import XCTest
@testable import Lemon

final class GemmaResponseTests: XCTestCase {

    // MARK: - GemmaResponse decoding

    func testDecodesResponseWithNoAction() throws {
        let json = """
        {"state":"running","summary":"Making progress on CardView tokens","action":null}
        """
        let r = try decode(json)
        XCTAssertEqual(r.state,   "running")
        XCTAssertEqual(r.summary, "Making progress on CardView tokens")
        XCTAssertNil(r.action)
    }

    func testDecodesResponseWithSendKeysAction() throws {
        let json = """
        {"state":"blocked_prompt","summary":"MCP server selection prompt",
         "action":{"type":"send_keys","keys":"\\r"}}
        """
        let r = try decode(json)
        XCTAssertEqual(r.state,          "blocked_prompt")
        XCTAssertEqual(r.action?.type,   "send_keys")
        XCTAssertEqual(r.action?.keys,   "\r")
        XCTAssertNil(r.action?.message)
    }

    func testDecodesResponseWithNotifyUserAction() throws {
        let json = """
        {"state":"waiting","summary":"Needs human decision",
         "action":{"type":"notify_user","message":"Which auth strategy should I use?"}}
        """
        let r = try decode(json)
        XCTAssertEqual(r.action?.type,    "notify_user")
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

    // MARK: - Helpers

    private func decode(_ json: String) throws -> GemmaResponse {
        try JSONDecoder().decode(GemmaResponse.self, from: Data(json.utf8))
    }
}
