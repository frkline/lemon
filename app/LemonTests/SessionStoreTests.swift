@testable import Lemon
import XCTest

final class SessionStoreTests: XCTestCase {
    private func issue(id: String = "i1") -> IssueRef {
        IssueRef(id: id, identifier: "DEMO-1", title: "Test", description: nil,
                 labelNames: [], scope: .linearTeam(id: "team1"))
    }

    func testAddAppendsToActive() {
        let store = SessionStore()
        store.add(Session(issue: issue()))
        XCTAssertEqual(store.active.count, 1)
        XCTAssertEqual(store.recent.count, 0)
    }

    func testFinishMovesSessionToRecent() {
        let store = SessionStore()
        let s = Session(issue: issue())
        store.add(s)
        store.finish(s)
        XCTAssertEqual(store.active.count, 0)
        XCTAssertEqual(store.recent.count, 1)
        XCTAssertNotNil(s.endedAt)
    }

    func testRecentIsNewestFirst() {
        let store = SessionStore()
        let a = Session(issue: issue(id: "a"))
        let b = Session(issue: issue(id: "b"))
        store.add(a); store.finish(a)
        store.add(b); store.finish(b)
        XCTAssertEqual(store.recent.first?.issue.id, "b")
    }

    func testRecentCappedAt20() {
        let store = SessionStore()
        for i in 0 ..< 25 {
            let s = Session(issue: issue(id: "i\(i)"))
            store.add(s); store.finish(s)
        }
        XCTAssertEqual(store.recent.count, 20)
    }

    func testIsTrackingActive() {
        let store = SessionStore()
        store.add(Session(issue: issue(id: "abc")))
        XCTAssertTrue(store.isTracking(issueId: "abc"))
        XCTAssertFalse(store.isTracking(issueId: "xyz"))
    }

    func testIsTrackingRecent() {
        let store = SessionStore()
        let s = Session(issue: issue(id: "abc"))
        store.add(s); store.finish(s)
        XCTAssertTrue(store.isTracking(issueId: "abc"))
    }

    func testFinishOnlyRemovesMatchingSession() {
        let store = SessionStore()
        let a = Session(issue: issue(id: "a"))
        let b = Session(issue: issue(id: "b"))
        store.add(a); store.add(b)
        store.finish(a)
        XCTAssertEqual(store.active.count, 1)
        XCTAssertEqual(store.active.first?.issue.id, "b")
    }

    func testAppendLogCapsAt2000Lines() {
        let s = Session(issue: issue())
        for i in 0 ..< 2005 {
            s.appendLog("line \(i)")
        }
        XCTAssertEqual(s.logLines.count, 2000)
        XCTAssertEqual(s.logLines.first, "line 5")
    }

    /// Locks down the fix for the stopSession-vs-natural-finish race that
    /// would otherwise double-insert the same session into `recent`.
    func testFinishIsIdempotent() {
        let store = SessionStore()
        let s = Session(issue: issue(id: "race"))
        store.add(s)
        store.finish(s)
        store.finish(s) // simulates stopSession racing with runner's onStatusChange terminal callback
        XCTAssertEqual(store.recent.count, 1, "Double-finish must not duplicate the session in recent")
        XCTAssertEqual(store.recent.first?.issue.id, "race")
    }

    func testFinishOnUnknownSessionIsSafe() {
        let store = SessionStore()
        let stranger = Session(issue: issue(id: "ghost"))
        store.finish(stranger)
        XCTAssertEqual(store.active.count, 0)
        XCTAssertEqual(store.recent.count, 1, "First-time finish of an off-store session is still valid")

        store.finish(stranger)
        XCTAssertEqual(store.recent.count, 1, "Second finish still idempotent")
    }

    // MARK: - Persisted snapshot projection (issue #35)

    private func tracked(id: String = "i1", status: SessionStatus = .executing) -> Session {
        let s = Session(issue: issue(id: id))
        s.workspaceId = UUID()
        s.status = status
        return s
    }

    func testSnapshotIncludesStartedSession() {
        let store = SessionStore()
        store.add(tracked())
        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.issue.id, "i1")
        XCTAssertEqual(snap.first?.status, .executing)
        // Default branch derives from the issue's pathSlug (DEMO-1 → demo-1).
        XCTAssertEqual(snap.first?.branch, "lemon/demo-1")
    }

    func testSnapshotExcludesSessionWithoutWorkspaceId() {
        let store = SessionStore()
        let s = Session(issue: issue()) // workspaceId stays nil (mock/smoke)
        s.status = .executing
        store.add(s)
        XCTAssertTrue(store.snapshot().isEmpty, "No workspaceId → can't reattach → excluded")
    }

    func testSnapshotExcludesTerminalSessions() {
        let store = SessionStore()
        store.add(tracked(status: .done))
        store.add(tracked(id: "i2", status: .failed))
        XCTAssertTrue(store.snapshot().isEmpty, "Terminal sessions are not reattachable")
    }

    func testSnapshotPreservesBranchAndRetrigger() {
        let store = SessionStore()
        let s = tracked(status: .reviewing)
        s.branch = "lemon/custom"
        s.retrigger = LemonMarker(branch: "lemon/custom", prNumber: "7",
                                  commentId: "c1", repoPath: "/tmp/r", source: .github)
        s.cleanupInfo = WorktreeCleanupInfo(sessionPath: "/tmp/lemon-demo-1", isMultiRepo: false,
                                            repos: [.init(name: "r", repoPath: "/tmp/r")], slug: "demo-1")
        store.add(s)
        let p = store.snapshot().first
        XCTAssertEqual(p?.branch, "lemon/custom")
        XCTAssertEqual(p?.retrigger?.prNumber, "7")
        XCTAssertEqual(p?.cleanupInfo?.slug, "demo-1")
    }
}
