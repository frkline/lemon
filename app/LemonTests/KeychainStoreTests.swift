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

    // MARK: - Env-var bypass (for unattended iteration + recursive Claude loops)

    private func withEnv(_ vars: [String: String?], _ body: () -> Void) {
        // setenv/unsetenv mutate process-global state — caller's job to ensure
        // tests don't run in parallel against the same vars (XCTest does sequential
        // by default within a class).
        let prior = vars.keys.reduce(into: [String: String?]()) { acc, k in
            acc[k] = ProcessInfo.processInfo.environment[k]
        }
        for (k, v) in vars {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        defer {
            for (k, v) in prior {
                if let v { setenv(k, v, 1) } else { unsetenv(k) }
            }
        }
        body()
    }

    func testEnvBypassNilWhenUnset() {
        withEnv(["LEMON_LINEAR_KEY": nil, "LEMON_LINEAR_KEY_FILE": nil]) {
            XCTAssertNil(KeychainStore.envKeyBypass())
        }
    }

    func testEnvBypassDirectKey() {
        withEnv(["LEMON_LINEAR_KEY": "lin_direct_value"]) {
            XCTAssertEqual(KeychainStore.envKeyBypass(), "lin_direct_value")
        }
    }

    func testEnvBypassDirectKeyTrimsWhitespace() {
        withEnv(["LEMON_LINEAR_KEY": "  lin_with_spaces  \n"]) {
            XCTAssertEqual(KeychainStore.envKeyBypass(), "lin_with_spaces")
        }
    }

    func testEnvBypassEmptyDirectKeyIsIgnored() {
        withEnv(["LEMON_LINEAR_KEY": "   ", "LEMON_LINEAR_KEY_FILE": nil]) {
            XCTAssertNil(KeychainStore.envKeyBypass())
        }
    }

    func testEnvBypassFilePath() throws {
        let path = NSTemporaryDirectory() + "kc-bypass-\(UUID().uuidString)"
        try "lin_from_file\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        withEnv(["LEMON_LINEAR_KEY": nil, "LEMON_LINEAR_KEY_FILE": path]) {
            XCTAssertEqual(KeychainStore.envKeyBypass(), "lin_from_file")
        }
    }

    func testEnvBypassFilePathExpandsTilde() throws {
        let home = NSHomeDirectory()
        let filename = "kc-tilde-\(UUID().uuidString).key"
        let realPath = home + "/" + filename
        try "lin_tilde_test".write(toFile: realPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: realPath) }
        withEnv(["LEMON_LINEAR_KEY": nil, "LEMON_LINEAR_KEY_FILE": "~/" + filename]) {
            XCTAssertEqual(KeychainStore.envKeyBypass(), "lin_tilde_test")
        }
    }

    func testEnvBypassDirectKeyWinsOverFile() throws {
        let path = NSTemporaryDirectory() + "kc-loses-\(UUID().uuidString)"
        try "from_file".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        withEnv(["LEMON_LINEAR_KEY": "from_env", "LEMON_LINEAR_KEY_FILE": path]) {
            XCTAssertEqual(KeychainStore.envKeyBypass(), "from_env")
        }
    }

    func testEnvBypassFileMissingReturnsNil() {
        withEnv(["LEMON_LINEAR_KEY": nil,
                 "LEMON_LINEAR_KEY_FILE": "/tmp/does-not-exist-\(UUID().uuidString)"]) {
            XCTAssertNil(KeychainStore.envKeyBypass())
        }
    }
}
