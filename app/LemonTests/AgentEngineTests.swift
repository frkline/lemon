@testable import Lemon
import XCTest

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

    func testOpenCodeModelConfigExtractsRequiredProviders() {
        let models = OpenCodeModelConfig(
            plan: "anthropic/claude-opus-4",
            code: " openai/gpt-4.1-mini ",
            review: "anthropic/claude-sonnet-4",
        )
        XCTAssertEqual(models.requiredProviders, ["anthropic", "openai"])
        XCTAssertTrue(models.malformedConfiguredModels.isEmpty)
    }

    func testOpenCodeModelConfigTracksMalformedModelIDs() {
        let models = OpenCodeModelConfig(
            plan: "claude-opus-4",
            code: "openai/gpt-4.1-mini",
            review: "",
        )
        XCTAssertEqual(models.malformedConfiguredModels, ["claude-opus-4"])
    }

    func testOpenCodeAuthInspectorDetectsMissingProviderCredential() throws {
        let json = """
        {
          "providers": {
            "openai": { "api_key": "sk-test" }
          }
        }
        """
        let result = try OpenCodeAuthInspector.validateProviderCredentials(
            requiredProviders: ["openai", "anthropic"],
            authData: XCTUnwrap(json.data(using: .utf8)),
        )
        XCTAssertEqual(result, .missing(["anthropic"]))
    }

    func testOpenCodeAuthInspectorPassesWhenAllProviderCredentialsExist() throws {
        let json = """
        {
          "providers": {
            "openai": { "api_key": "sk-test" },
            "anthropic": { "apiKey": "ak-test" }
          }
        }
        """
        let result = try OpenCodeAuthInspector.validateProviderCredentials(
            requiredProviders: ["openai", "anthropic"],
            authData: XCTUnwrap(json.data(using: .utf8)),
        )
        XCTAssertEqual(result, .allPresent)
    }
}
