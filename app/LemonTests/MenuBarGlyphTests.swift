@testable import Lemon
import XCTest

/// The menu-bar status glyph maps the full set of session states down to the
/// six handoff glyphs (idle/working/waiting/done/error/disabled). These pin the
/// priority so "which icon shows" stays correct as states are added.
final class MenuBarGlyphTests: XCTestCase {
    private func glyph(_ active: [SessionStatus],
                       recent: SessionStatus? = nil,
                       configured: Bool = true) -> MenuBarGlyph
    {
        MenuBarGlyph.aggregate(activeStatuses: active, lastRecentStatus: recent, configured: configured)
    }

    func testDisabledWhenNotConfigured() {
        XCTAssertEqual(glyph([.executing], configured: false), .disabled)
    }

    func testIdleWhenNothingActiveOrRecent() {
        XCTAssertEqual(glyph([]), .idle)
    }

    func testWorkingWhilePlanningOrExecuting() {
        XCTAssertEqual(glyph([.planning]), .working)
        XCTAssertEqual(glyph([.executing]), .working)
    }

    func testWaitingForEitherGateOrMidBuildQuestion() {
        XCTAssertEqual(glyph([.planReview]), .waiting)
        XCTAssertEqual(glyph([.resultReview]), .waiting)
        XCTAssertEqual(glyph([.waiting]), .waiting)
    }

    func testReviewingShowsDone() {
        XCTAssertEqual(glyph([.reviewing]), .done)
    }

    func testRecentOutcomeWhenNoActive() {
        XCTAssertEqual(glyph([], recent: .failed), .error)
        XCTAssertEqual(glyph([], recent: .done), .done)
    }

    func testNeedsHumanWinsOverWorking() {
        // A second session awaiting input should pull the whole menu bar to waiting.
        XCTAssertEqual(glyph([.executing, .planReview]), .waiting)
    }

    func testActiveWorkWinsOverRecentError() {
        // A fresh run in progress shouldn't be masked by an old failure.
        XCTAssertEqual(glyph([.executing], recent: .failed), .working)
    }

    func testEveryGlyphHasAnAsset() {
        for g in MenuBarGlyph.allCases {
            XCTAssertFalse(g.assetName.isEmpty)
        }
    }
}
