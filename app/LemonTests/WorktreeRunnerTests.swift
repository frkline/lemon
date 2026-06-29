@testable import Lemon
import XCTest

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

    func testTmuxSessionNameFromSlug() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.tmuxSessionName(slug: "demo-42"), "lemon-demo-42")
        XCTAssertEqual(runner.tmuxSessionName(slug: "lem-100"), "lemon-lem-100")
        XCTAssertEqual(runner.tmuxSessionName(slug: "acme-widgets-7"), "lemon-acme-widgets-7",
                       "GitHub slugs flatten slashes; tmux name must not contain '/'.")
    }

    // MARK: - logPath

    func testLogPathFormat() {
        let runner = WorktreeRunner()
        XCTAssertEqual(runner.logPath(slug: "demo-42"), "/tmp/lemon-log-demo-42.txt")
    }

    func testOpenCodeSessionPathFormat() {
        XCTAssertEqual(
            WorktreeRunner.openCodeSessionPath(slug: "demo-42"),
            "/tmp/lemon-opencode-session-demo-42"
        )
    }

    // MARK: - IssueRef.pathSlug end-to-end

    func testIssueRefPathSlugForLinear() {
        let ref = IssueRef(id: "n", identifier: "HRP-42", title: "x", description: nil,
                           labelNames: [], scope: .linearTeam(id: "team1"))
        XCTAssertEqual(ref.pathSlug, "hrp-42")
    }

    func testIssueRefPathSlugForGitHub() {
        let ref = IssueRef(id: "x", identifier: "acme/widgets#7", title: "x", description: nil,
                           labelNames: [], scope: .githubRepo(owner: "acme", repo: "widgets", number: 7))
        XCTAssertEqual(ref.pathSlug, "acme-widgets-7")
    }

    // MARK: - shouldInvokeGemma (silence detector)

    func testNoGemmaWhenSessionFresh() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-30), // 30s ago — not silent
            lastGemmaAt: nil,
            now: now,
        )
        XCTAssertFalse(result)
    }

    func testGemmaFiresAfter2MinSilence() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-121), // 121s ago
            lastGemmaAt: nil,
            now: now,
        )
        XCTAssertTrue(result)
    }

    func testGemmaDoesNotFireDuringCooldown() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-180),
            lastGemmaAt: now.addingTimeInterval(-60), // last Gemma only 60s ago — still in cooldown
            now: now,
        )
        XCTAssertFalse(result)
    }

    func testGemmaFiresAfterCooldownExpires() {
        let now = Date()
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-300),
            lastGemmaAt: now.addingTimeInterval(-181), // 181s ago — cooldown expired
            now: now,
        )
        XCTAssertTrue(result)
    }

    func testGemmaExactlyAtSilenceThresholdDoesNotFire() {
        let now = Date()
        // exactly 120s — must be *strictly* greater than 120
        let result = WorktreeRunner.shouldInvokeGemma(
            lastActivityAt: now.addingTimeInterval(-120),
            lastGemmaAt: nil,
            now: now,
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
            cooldown: 60,
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
        for digit in 1 ... 9 {
            XCTAssertTrue(WorktreeRunner.isSafeSendKeys("\(digit)"))
        }
    }

    func testIsSafeSendKeysAcceptsNavigationKeys() {
        // Needed for Claude Code's MCP picker (Enter confirms pre-checked list)
        // and similar interactive menus.
        for nav in ["Enter", "Return", "Escape", "Space", "Tab"] {
            XCTAssertTrue(WorktreeRunner.isSafeSendKeys(nav), "\(nav) must be allowed")
        }
    }

    func testIsSafeSendKeysRejectsArbitraryText() {
        for unsafe in ["rm -rf /", "git push --force", "delete", "yes please", "yY", "12", "y\nrm -rf /", "; ls", "$(whoami)"] {
            XCTAssertFalse(WorktreeRunner.isSafeSendKeys(unsafe), "\(unsafe) must be rejected")
        }
    }

    // MARK: - tailLines / stripANSI (#44 classify-input bounding)

    func testStripANSIRemovesCSIAndOSC() {
        let raw = "\u{1B}[0;31mred\u{1B}[0m \u{1B}]0;title\u{07}plain"
        XCTAssertEqual(WorktreeRunner.stripANSI(raw), "red plain")
    }

    func testTailLinesSplitsOnCarriageReturns() {
        // A TUI repaint stream: bare CRs, no LFs — must still yield many lines.
        let content = (1 ... 50).map { "frame\($0)" }.joined(separator: "\r")
        let lines = WorktreeRunner.tailLines(from: content, last: 10)
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.last, "frame50")
        XCTAssertEqual(lines.first, "frame41")
    }

    func testTailLinesBoundsCharsOnGiantAnsiBlob() {
        // The #44 wedge: a huge ANSI-laden blob with almost no newlines.
        let noise = String(repeating: "\u{1B}[2K\u{1B}[1G", count: 20000)
        let blob = noise + "actual output line\r" + noise + "final line"
        let lines = WorktreeRunner.tailLines(from: blob, last: 100, maxChars: 6000)
        let totalChars = lines.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(totalChars, 6000, "classify input must stay bounded")
        XCTAssertEqual(lines.last, "final line")
        XCTAssertFalse(lines.joined().contains("\u{1B}"), "ANSI must be stripped")
    }

    func testTailLinesEmptyContent() {
        XCTAssertTrue(WorktreeRunner.tailLines(from: "", last: 100).isEmpty)
    }

    // MARK: - kickoffPrompt (#85 echo issue title + summary first)

    func testKickoffPromptEchoesTitleAndSummaryFirst() {
        for planMode in [true, false] {
            let prompt = WorktreeRunner.kickoffPrompt(
                planMode: planMode,
                planPath: "/tmp/lemon-plan-demo-1.md",
                gatePath: "/tmp/lemon-gate-demo-1",
            )
            XCTAssertTrue(prompt.contains("print the issue title"),
                          "planMode=\(planMode): prompt must ask claude to echo the title")
            XCTAssertTrue(prompt.contains("summary"),
                          "planMode=\(planMode): prompt must ask claude to echo a summary")
            // The echo must come BEFORE the work (triage / the task) so a phone
            // watcher gets context first.
            let echoIdx = try? XCTUnwrap(prompt.range(of: "print the issue title")).lowerBound
            let workIdx = try? XCTUnwrap(prompt.range(of: planMode ? "triage" : "complete the task")).lowerBound
            if let echoIdx, let workIdx {
                XCTAssertLessThan(echoIdx, workIdx,
                                  "planMode=\(planMode): echo instruction must precede the work")
            }
        }
    }

    func testKickoffPromptEchoAddsNoApostrophes() {
        // The launcher single-quotes the prompt in bash. The echo instruction
        // the simple variant adds must not introduce apostrophes (the plan
        // variant already quotes the 🍋 Waiting label name — pre-existing, out
        // of scope here).
        let simple = WorktreeRunner.kickoffPrompt(
            planMode: false, planPath: "/tmp/lemon-plan-demo-1.md", gatePath: "/tmp/lemon-gate-demo-1",
        )
        XCTAssertFalse(simple.contains("'"), "simple prompt must not contain apostrophes")
    }

    func testKickoffPromptPlanModeKeepsGateFlow() {
        let prompt = WorktreeRunner.kickoffPrompt(
            planMode: true,
            planPath: "/tmp/lemon-plan-demo-1.md",
            gatePath: "/tmp/lemon-gate-demo-1",
        )
        XCTAssertTrue(prompt.contains("/tmp/lemon-plan-demo-1.md"))
        XCTAssertTrue(prompt.contains("/tmp/lemon-gate-demo-1"))
        XCTAssertTrue(prompt.contains("AskUserQuestion"))
    }

    // MARK: - parseSessionLimitReset (#39 quota detection)

    func testParseSessionLimitNilForNormalOutput() {
        XCTAssertNil(WorktreeRunner.parseSessionLimitReset(from: "$ ls\nfile.txt\nbuild succeeded"))
    }

    func testParseSessionLimitParsesPMResetSameDay() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 10, minute: 0)))
        let text = "You've hit your session limit · resets 3:20pm (America/Boise)"
        let reset = WorktreeRunner.parseSessionLimitReset(from: text, now: now, calendar: cal)
        XCTAssertNotNil(reset)
        let rc = try cal.dateComponents([.hour, .minute, .day], from: XCTUnwrap(reset))
        XCTAssertEqual(rc.hour, 15)
        XCTAssertEqual(rc.minute, 20)
        XCTAssertEqual(rc.day, 28)
    }

    func testParseSessionLimitRollsToTomorrowWhenPast() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 16, minute: 0)))
        let reset = try XCTUnwrap(WorktreeRunner.parseSessionLimitReset(from: "session limit · resets 3:20pm", now: now, calendar: cal))
        XCTAssertGreaterThan(reset, now)
        XCTAssertEqual(cal.dateComponents([.day], from: reset).day, 29)
    }

    func testParseSessionLimitFallbackWhenNoTime() {
        // Banner present but no parseable clock → fallback (non-nil, ~1h out).
        XCTAssertNotNil(WorktreeRunner.parseSessionLimitReset(from: "You've hit your session limit, try later"))
    }
}
