@testable import Lemon
import XCTest

/// Pins re-trigger DETECTION through the sandbox tracker: a completed issue with
/// a human reply after the Lemon Report marker must surface as re-triggerable.
/// This isolates issue #9 — if detection works here, a sandbox re-trigger miss
/// is in the Orchestrator/worktree handling, not the marker logic.
final class MockIssueClientTests: XCTestCase {
    private let auth = SandboxFixtures.auth
    private let num = 99
    private var path: String {
        "\(SandboxFixtures.issuesDir)/\(num).json"
    }

    private func writeFixture(comments: [(String, String, Double)], labels: [String]) throws {
        try? FileManager.default.createDirectory(atPath: SandboxFixtures.issuesDir, withIntermediateDirectories: true)
        let cs = comments.map { ["id": $0.0, "body": $0.1, "createdAt": $0.2] as [String: Any] }
        let fixture: [String: Any] = [
            "number": num, "title": "Greeting helper", "description": "Add hello().",
            "labelNames": labels, "comments": cs, "commentSeq": comments.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        try data.write(to: URL(fileURLWithPath: path))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    /// A real Lemon Report body (same marker block buildLemonComment emits).
    private func reportBody() -> String {
        """
        ## 🍋 Lemon Report — sandbox/demo#\(num)

        **Branch:** `lemon/sandbox-demo-\(num)`

        ---
        *Reply to revise.*

        <!-- lemon
        branch: lemon/sandbox-demo-\(num)
        pr:\u{20}
        repo: /tmp/lemon-sandbox/workspace
        source: github
        -->
        """
    }

    func testReTriggerDetectedWhenReplyFollowsMarker() async throws {
        try writeFixture(
            comments: [("c1", reportBody(), 1000), ("h1", "Please also greet by time of day.", 2000)],
            labels: ["🍋 Complete"],
        )
        let client = MockIssueClient()

        // 1. The completed issue is in the complete queue.
        let complete = try await client.fetchCompleteQueue(config: sandboxConfig(), auth: auth)
        let ref = try XCTUnwrap(complete.first { $0.identifier == "sandbox/demo#\(num)" })

        // 2. The Lemon Report marker parses (even with an empty pr:).
        let marker = try await client.findLemonMarker(ref: ref, auth: auth)
        XCTAssertNotNil(marker, "Lemon Report marker should parse even without a PR")
        XCTAssertEqual(marker?.commentId, "c1")

        // 3. The human reply after the marker is detected → re-triggerable.
        let hasReply = try await client.hasNewComment(ref: ref, afterCommentId: "c1", auth: auth)
        XCTAssertTrue(hasReply, "reply after the marker should be seen as new")
    }

    func testNoReTriggerWhenMarkerIsLatest() async throws {
        // After the #9 fix, a fresh report is the newest comment → nothing after it.
        try writeFixture(
            comments: [("c1", reportBody(), 1000), ("h1", "revise", 2000), ("c2", reportBody(), 3000)],
            labels: ["🍋 Complete"],
        )
        let client = MockIssueClient()
        let complete = try await client.fetchCompleteQueue(config: sandboxConfig(), auth: auth)
        // Select #99 explicitly — loadAll() reads every fixture in the shared
        // sandbox dir, so .first could be an unrelated leftover issue.
        let ref = try XCTUnwrap(complete.first { $0.identifier == "sandbox/demo#\(num)" })
        let marker = try await client.findLemonMarker(ref: ref, auth: auth)
        XCTAssertEqual(marker?.commentId, "c2", "findLatest should advance to the newest report")
        let hasReply = try await client.hasNewComment(ref: ref, afterCommentId: "c2", auth: auth)
        XCTAssertFalse(hasReply, "nothing after the advanced marker → no spurious re-trigger")
    }

    private func sandboxConfig() -> SourceConfig {
        SourceConfig(source: .github, displayName: "Sandbox", linearTeamKeys: nil, githubRepos: [SandboxFixtures.surfaceId])
    }
}
