import XCTest
@testable import Lemon

final class WorktreeRunnerTests: XCTestCase {

    // MARK: - devPort

    func testDevPortBasicIssue() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "HRP-42"), 3042)
    }

    func testDevPortZeroSuffix() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "LEM-0"), 3000)
    }

    func testDevPortSingleDigit() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "ABC-7"), 3007)
    }

    func testDevPortLargeNumberWraps() {
        // 3000 + (1500 % 1000) = 3500
        XCTAssertEqual(WorktreeRunner.devPort(for: "HRP-1500"), 3500)
    }

    func testDevPortStaysBelow4000() {
        for n in [999, 1000, 1001, 9999] {
            let port = WorktreeRunner.devPort(for: "HRP-\(n)")
            XCTAssertGreaterThanOrEqual(port, 3000)
            XCTAssertLessThan(port, 4000, "Port out of range for HRP-\(n)")
        }
    }

    func testDevPortMalformedIdentifierReturns3000() {
        // Identifier with no numeric suffix → treated as 0
        XCTAssertEqual(WorktreeRunner.devPort(for: "HRP-"), 3000)
        XCTAssertEqual(WorktreeRunner.devPort(for: "nonum"), 3000)
    }

    // MARK: - tmuxSessionName

    func testTmuxSessionNameLowercases() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.tmuxSessionName("HRP-42"),  "lemon-hrp-42")
        XCTAssertEqual(runner.tmuxSessionName("LEM-100"), "lemon-lem-100")
    }

    // MARK: - logPath

    func testLogPathFormat() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.logPath("HRP-42"), "/tmp/lemon-log-hrp-42.txt")
    }

    // MARK: - shouldInvokeGemma (silence detector)

    func testNoGemmaWhenSessionFresh() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-30),  // 30s ago — not silent
            lastGemmaAt: nil,
            now: now
        )
        XCTAssertFalse(result)
    }

    func testGemmaFiresAfter2MinSilence() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-121),  // 121s ago
            lastGemmaAt: nil,
            now: now
        )
        XCTAssertTrue(result)
    }

    func testGemmaDoesNotFireDuringCooldown() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-180),
            lastGemmaAt: now.addingTimeInterval(-60),  // last Gemma only 60s ago — still in cooldown
            now: now
        )
        XCTAssertFalse(result)
    }

    func testGemmaFiresAfterCooldownExpires() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-300),
            lastGemmaAt: now.addingTimeInterval(-181),  // 181s ago — cooldown expired
            now: now
        )
        XCTAssertTrue(result)
    }

    func testGemmaExactlyAtSilenceThresholdDoesNotFire() {
        let now = Date()
        // exactly 120s — must be *strictly* greater than 120
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-120),
            lastGemmaAt: nil,
            now: now
        )
        XCTAssertFalse(result)
    }

    func testCustomThresholds() {
        let now = Date()
        // Custom threshold of 30s, cooldown of 60s
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-31),
            lastGemmaAt: nil,
            now: now,
            silenceThreshold: 30,
            cooldown: 60
        )
        XCTAssertTrue(result)
    }
}
