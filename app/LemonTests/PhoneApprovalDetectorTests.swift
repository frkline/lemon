@testable import Lemon
import XCTest

/// #64: the pane-log signals that let Lemon notice a plan was approved on the
/// PHONE (claude's native ExitPlanMode picker over remote-control) — which
/// bypasses resolveGate and the gate sentinel — and tell whether the build
/// then stalled in default (prompt-on-edit) mode.
final class PhoneApprovalDetectorTests: XCTestCase {
    // MARK: planExecutionStarted (Signal 1 — plan mode exited)

    func testEditBulletMeansBuildBegan() {
        XCTAssertTrue(WorktreeRunner.planExecutionStarted(in: ["⏺ Update(Models.swift)"]))
        XCTAssertTrue(WorktreeRunner.planExecutionStarted(in: ["● Bash(swift build)"]))
        XCTAssertTrue(WorktreeRunner.planExecutionStarted(in: ["● Write(README.md)"]))
    }

    func testReadOnlyToolsDoNotCountAsBuildStart() {
        // Read/Glob/Grep are allowed in plan mode — they must NOT trip Signal 1.
        XCTAssertFalse(WorktreeRunner.planExecutionStarted(in: ["⏺ Read(Models.swift)"]))
        XCTAssertFalse(WorktreeRunner.planExecutionStarted(in: ["● Grep(pattern)"]))
    }

    func testPlanProseDoesNotCountWithoutBullet() {
        // A plan that mentions editing files in prose has no tool bullet.
        XCTAssertFalse(WorktreeRunner.planExecutionStarted(in: ["I will Edit(the file) after approval"]))
    }

    // MARK: permissionPromptVisible (Signal 2 — stalled in default mode)

    func testPerToolPromptIsDetected() {
        let lines = ["Do you want to make this edit?", "❯ 1. Yes", "  2. Yes, and don't ask again this session", "  3. No"]
        XCTAssertTrue(WorktreeRunner.permissionPromptVisible(in: lines))
    }

    func testExitPlanPickerIsNotAPermissionPrompt() {
        // The ExitPlanMode picker offers auto/manual but never "don't ask again".
        let lines = ["Would you like to proceed?", "❯ 1. Yes, and auto-accept edits", "  2. Yes, and manually approve edits", "  3. No, keep planning"]
        XCTAssertFalse(WorktreeRunner.permissionPromptVisible(in: lines))
    }
}
