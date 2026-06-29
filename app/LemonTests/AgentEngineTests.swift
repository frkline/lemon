import XCTest
@testable import Lemon

final class AgentEngineTests: XCTestCase {
    func testOpenCodeModelConfigRequiresAllThreeSlots() {
        XCTAssertFalse(OpenCodeModelConfig(plan: "", code: "", review: "").hasAllConfigured)
        XCTAssertFalse(OpenCodeModelConfig(plan: "anthropic/claude-opus-4", code: "", review: "anthropic/claude-sonnet-4").hasAllConfigured)
        XCTAssertTrue(OpenCodeModelConfig(plan: "anthropic/claude-opus-4", code: "openai/gpt-4.1-mini", review: "anthropic/claude-sonnet-4").hasAllConfigured)
    }

    func testAgentEngineFactoryReturnsRequestedKind() {
        XCTAssertEqual(AgentEngineFactory.make(kind: .claudeCode).kind, .claudeCode)
        XCTAssertEqual(AgentEngineFactory.make(kind: .openCode).kind, .openCode)
    }
}
