@testable import Lemon
import XCTest

final class LemonMarkerExtractorTests: XCTestCase {
    // MARK: - parse

    func testParseFallsBackToHostCommentId() {
        // Lemon Report comments don't know their own ID at write time, so the
        // marker omits `comment:` and the parser falls back to the host comment.
        let body = """
        ## 🍋 Lemon Report — DEMO-42

        **PR:** [#101](https://github.com/x/y/pull/101)

        <!-- lemon
        branch: lemon/DEMO-42
        pr: 101
        repo: /tmp/repo
        -->
        """
        let marker = LemonMarkerExtractor.parse(body: body, commentId: "host-comment-real-id")
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.commentId, "host-comment-real-id",
                       "Must use the host comment id when `comment:` is absent — re-trigger detection depends on it.")
        XCTAssertEqual(marker?.branch, "lemon/DEMO-42")
        XCTAssertEqual(marker?.prNumber, "101")
        XCTAssertEqual(marker?.repoPath, "/tmp/repo")
        XCTAssertNil(marker?.source, "Pre-upgrade comments omit the `source:` line.")
    }

    func testParseExplicitCommentIdWins() {
        let body = """
        <!-- lemon
        branch: lemon/DEMO-7
        pr: 22
        comment: explicit-id
        repo: /tmp/r
        -->
        """
        let marker = LemonMarkerExtractor.parse(body: body, commentId: "host-id")
        XCTAssertEqual(marker?.commentId, "explicit-id")
    }

    func testParseHonorsPlaceholderCommentId() {
        // Documents the bug we just fixed: a literal "PENDING" placeholder
        // poisons the re-trigger detection. The Lemon Report builder must
        // not emit `comment: PENDING`.
        let body = """
        <!-- lemon
        branch: lemon/DEMO-1
        pr: 99
        comment: PENDING
        repo: /tmp/r
        -->
        """
        let marker = LemonMarkerExtractor.parse(body: body, commentId: "real-id")
        XCTAssertEqual(marker?.commentId, "PENDING",
                       "Parser honors what's written. Builder must not write a placeholder; see WorktreeRunner.buildLemonComment.")
    }

    func testParseMissingFieldsReturnsNil() {
        let body = """
        <!-- lemon
        branch: lemon/DEMO-1
        -->
        """
        XCTAssertNil(LemonMarkerExtractor.parse(body: body, commentId: "x"),
                     "Required pr + repo fields must be present.")
    }

    func testParseGithubSourceLine() {
        // Post-upgrade Lemon Reports on a GitHub issue emit `source: github`.
        let body = """
        <!-- lemon
        branch: lemon/issue-7
        pr: 14
        repo: /tmp/lemon-acme-widgets-7
        source: github
        -->
        """
        let marker = LemonMarkerExtractor.parse(body: body, commentId: "c")
        XCTAssertEqual(marker?.source, .github)
    }

    func testParseUnknownSourceLineIsNil() {
        let body = """
        <!-- lemon
        branch: lemon/x
        pr: 1
        repo: /tmp/r
        source: jira
        -->
        """
        let marker = LemonMarkerExtractor.parse(body: body, commentId: "c")
        XCTAssertNotNil(marker)
        XCTAssertNil(marker?.source, "Unknown source values parse as nil rather than crashing.")
    }

    // MARK: - findLatest / hasNewComment / bodiesAfter

    private func comment(_ id: String, _ body: String, _ ts: TimeInterval) -> IssueComment {
        IssueComment(id: id, body: body, createdAt: Date(timeIntervalSinceReferenceDate: ts))
    }

    private func markerBody(branch: String, pr: String, repo: String) -> String {
        """
        Some prose.

        <!-- lemon
        branch: \(branch)
        pr: \(pr)
        repo: \(repo)
        -->
        """
    }

    func testFindLatestPicksMostRecentMarker() {
        let comments = [
            comment("c1", markerBody(branch: "lemon/X-1", pr: "10", repo: "/r"), 1),
            comment("c2", "no marker here", 2),
            comment("c3", markerBody(branch: "lemon/X-2", pr: "20", repo: "/r"), 3),
        ]
        let marker = LemonMarkerExtractor.findLatest(in: comments)
        XCTAssertEqual(marker?.branch, "lemon/X-2", "findLatest walks newest → oldest.")
    }

    func testFindLatestReturnsNilWhenNoMarker() {
        let comments = [
            comment("c1", "first reply", 1),
            comment("c2", "second reply", 2),
        ]
        XCTAssertNil(LemonMarkerExtractor.findLatest(in: comments))
    }

    func testHasNewCommentDetectsLaterComments() {
        let comments = [
            comment("c1", "first", 1),
            comment("c2", "second", 2),
            comment("c3", "third", 3),
        ]
        XCTAssertTrue(LemonMarkerExtractor.hasNewComment(in: comments, afterCommentId: "c2"))
        XCTAssertFalse(LemonMarkerExtractor.hasNewComment(in: comments, afterCommentId: "c3"))
        XCTAssertFalse(LemonMarkerExtractor.hasNewComment(in: comments, afterCommentId: "missing"))
    }

    func testBodiesAfterReturnsLaterBodies() {
        let comments = [
            comment("c1", "first", 1),
            comment("c2", "second", 2),
            comment("c3", "third", 3),
        ]
        XCTAssertEqual(LemonMarkerExtractor.bodiesAfter(in: comments, afterCommentId: "c1"), ["second", "third"])
        XCTAssertEqual(LemonMarkerExtractor.bodiesAfter(in: comments, afterCommentId: "c3"), [])
        XCTAssertEqual(LemonMarkerExtractor.bodiesAfter(in: comments, afterCommentId: "missing"), [])
    }
}
