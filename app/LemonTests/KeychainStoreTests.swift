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

    func testIsConfiguredFalseWithoutAI() {
        let s = store()
        s.linearApiKey = "lin_api_test"
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo")])
        XCTAssertFalse(s.isConfigured, "Local AI is required")
    }

    func testIsConfiguredTrueWithKeyAndRepoAndAI() throws {
        // isConfigured also verifies the model + binary files exist on disk now,
        // so the test fixtures need to live somewhere real.
        let fm = FileManager.default
        let modelDir = NSTemporaryDirectory() + "kc-test-model-\(UUID().uuidString)"
        let swiftLM  = NSTemporaryDirectory() + "kc-test-swiftlm-\(UUID().uuidString)"
        try fm.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        try "{}".write(toFile: modelDir + "/config.json", atomically: true, encoding: .utf8)
        try Data().write(to: URL(fileURLWithPath: swiftLM))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftLM)
        defer {
            try? fm.removeItem(atPath: modelDir)
            try? fm.removeItem(atPath: swiftLM)
        }

        let s = store()
        s.linearApiKey = "lin_api_test"
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo")])
        s.modelPath = modelDir
        s.swiftLMPath = swiftLM
        s.aiEnabled = true
        XCTAssertTrue(s.isConfigured)
    }

    func testIsConfiguredFalseWhenModelMissingOnDisk() {
        // Locks the bug fix: stale modelPath pointing at a deleted dir must
        // NOT count as configured. Otherwise users who upgrade past a dirName
        // change get dropped into the main app with a broken Gemma.
        let s = store()
        s.linearApiKey = "lin_api_test"
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "ABC", path: "/tmp/repo")])
        s.modelPath = "/tmp/this-path-does-not-exist-\(UUID().uuidString)"
        s.swiftLMPath = "/tmp/also-fake-\(UUID().uuidString)"
        s.aiEnabled = true
        XCTAssertFalse(s.isConfigured)
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
