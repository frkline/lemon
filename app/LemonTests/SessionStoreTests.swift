import XCTest
@testable import Lemon

final class SessionStoreTests: XCTestCase {
    private func issue(id: String = "i1") -> LinearIssue {
        LinearIssue(id: id, identifier: "HRP-1", title: "Test", description: nil, labelNames: [], teamId: "team1")
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
        for i in 0..<25 {
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
        for i in 0..<2005 { s.appendLog("line \(i)") }
        XCTAssertEqual(s.logLines.count, 2000)
        XCTAssertEqual(s.logLines.first, "line 5")
    }
}
