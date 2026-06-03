import XCTest
@testable import Lemon

final class KeychainStoreTests: XCTestCase {
    private func store() -> KeychainStore { KeychainStore.makeForTesting() }

    func testLinearApiKeyRoundTrip() {
        let s = store()
        s.linearApiKey = "lin_api_test"
        XCTAssertEqual(s.linearApiKey, "lin_api_test")
    }

    func testLinearApiKeyOverwrite() {
        let s = store()
        s.linearApiKey = "first"
        s.linearApiKey = "second"
        XCTAssertEqual(s.linearApiKey, "second")
    }

    func testLinearApiKeyEmptyByDefault() {
        XCTAssertEqual(store().linearApiKey, "")
    }

    func testIsConfiguredFalseWhenEmpty() {
        XCTAssertFalse(store().isConfigured)
    }

    func testIsConfiguredFalseWithOnlyApiKey() {
        let s = store()
        s.linearApiKey = "lin_api_test"
        XCTAssertFalse(s.isConfigured)
    }

    func testIsConfiguredTrueWithKeyAndRepo() {
        let s = store()
        s.linearApiKey = "lin_api_test"
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo")])
        XCTAssertTrue(s.isConfigured)
    }

    func testRepoRoundTrip() {
        let s = store()
        let repos = [
            WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo-a"),
            WorkspaceRepo(issuePrefix: "LEM", path: "/tmp/lemon"),
        ]
        s.saveWorkspaceRepos(repos)
        let loaded = s.workspaceRepos
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].issuePrefix, "ABC")
        XCTAssertEqual(loaded[1].path, "/tmp/lemon")
    }

    func testRepoForPrefix() {
        let s = store()
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo-a")])
        XCTAssertNotNil(s.repoFor(issuePrefix: "ABC"))
        XCTAssertNotNil(s.repoFor(issuePrefix: "abc"))  // case-insensitive match
        XCTAssertNil(s.repoFor(issuePrefix: "LEM"))
    }

    func testDeleteAllClearsEverything() {
        let s = store()
        s.linearApiKey = "lin_api_test"
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo-a")])
        s.deleteAll()
        XCTAssertEqual(s.linearApiKey, "")
        XCTAssertTrue(s.workspaceRepos.isEmpty)
    }

    func testLinearUserIdRoundTrip() {
        let s = store()
        s.linearUserId = "u_12345"
        XCTAssertEqual(s.linearUserId, "u_12345")
    }

    func testStoresAreIsolated() {
        let a = store()
        let b = store()
        a.linearApiKey = "key-a"
        XCTAssertEqual(b.linearApiKey, "")
    }
}
