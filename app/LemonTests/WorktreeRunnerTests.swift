import XCTest
@testable import Lemon

final class WorktreeRunnerTests: XCTestCase {

    // MARK: - devPort

    func testDevPortBasicIssue() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "DEMO-42"), 3042)
    }

    func testDevPortZeroSuffix() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "LEM-0"), 3000)
    }

    func testDevPortSingleDigit() {
        XCTAssertEqual(WorktreeRunner.devPort(for: "ABC-7"), 3007)
    }

    func testDevPortLargeNumberWraps() {
        // 3000 + (1500 % 1000) = 3500
        XCTAssertEqual(WorktreeRunner.devPort(for: "DEMO-1500"), 3500)
    }

    func testDevPortStaysBelow4000() {
        for n in [999, 1000, 1001, 9999] {
            let port = WorktreeRunner.devPort(for: "DEMO-\(n)")
            XCTAssertGreaterThanOrEqual(port, 3000)
            XCTAssertLessThan(port, 4000, "Port out of range for DEMO-\(n)")
        }
    }

    func testDevPortMalformedIdentifierReturns3000() {
        // Identifier with no numeric suffix → treated as 0
        XCTAssertEqual(WorktreeRunner.devPort(for: "DEMO-"), 3000)
        XCTAssertEqual(WorktreeRunner.devPort(for: "nonum"), 3000)
    }

    // MARK: - tmuxSessionName

    func testTmuxSessionNameLowercases() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.tmuxSessionName("DEMO-42"),  "lemon-demo-42")
        XCTAssertEqual(runner.tmuxSessionName("LEM-100"), "lemon-lem-100")
    }

    // MARK: - logPath

    func testLogPathFormat() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.logPath("DEMO-42"), "/tmp/lemon-log-demo-42.txt")
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

    // MARK: - isSafeSendKeys allowlist

    func testIsSafeSendKeysAcceptsConfirmations() {
        for safe in ["y", "Y", "n", "N", "yes", "Yes", "YES", "no", "No", "NO"] {
            XCTAssertTrue(WorktreeRunner.isSafeSendKeys(safe), "\(safe) should be allowed")
        }
    }

    func testIsSafeSendKeysAcceptsNumericMenu() {
        for digit in 1...9 {
            XCTAssertTrue(WorktreeRunner.isSafeSendKeys("\(digit)"))
        }
    }

    func testIsSafeSendKeysRejectsArbitraryText() {
        for unsafe in ["rm -rf /", "git push --force", "delete", "yes please", "yY", "12", "y\nrm -rf /", "; ls", "$(whoami)"] {
            XCTAssertFalse(WorktreeRunner.isSafeSendKeys(unsafe), "\(unsafe) must be rejected")
        }
    }
}
