@testable import Lemon
import XCTest

final class KeychainStoreTests: XCTestCase {
    private func store() -> KeychainStore {
        KeychainStore.makeForTesting()
    }

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
        let swiftLM = NSTemporaryDirectory() + "kc-test-swiftlm-\(UUID().uuidString)"
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
        XCTAssertNotNil(s.repoFor(issuePrefix: "abc")) // case-insensitive match
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
                 "LEMON_LINEAR_KEY_FILE": "/tmp/does-not-exist-\(UUID().uuidString)"])
        {
            XCTAssertNil(KeychainStore.envKeyBypass())
        }
    }

    // MARK: - GitHub credential

    func testGithubTokenRoundTrip() {
        let s = store()
        s.githubToken = "ghp_test_value"
        XCTAssertEqual(s.githubToken, "ghp_test_value")
    }

    func testGithubUserRoundTrip() {
        let s = store()
        s.githubUser = "frkline"
        XCTAssertEqual(s.githubUser, "frkline")
    }

    func testEnvBypassGithubTokenDirect() {
        withEnv(["LEMON_GITHUB_TOKEN": "ghp_env_direct"]) {
            XCTAssertEqual(KeychainStore.envBypass(prefix: "LEMON_GITHUB_TOKEN"), "ghp_env_direct")
        }
    }

    func testEnvBypassGithubTokenFile() throws {
        let path = NSTemporaryDirectory() + "kc-gh-\(UUID().uuidString)"
        try "ghp_from_file\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        withEnv(["LEMON_GITHUB_TOKEN": nil, "LEMON_GITHUB_TOKEN_FILE": path]) {
            XCTAssertEqual(KeychainStore.envBypass(prefix: "LEMON_GITHUB_TOKEN"), "ghp_from_file")
        }
    }

    // MARK: - Workspace pairs

    private func mapping(matchKey: String, path: String = "/tmp/repo") -> WorkspaceMapping {
        WorkspaceMapping(matchKey: matchKey, path: path)
    }

    private func linearPair(matchKey: String, teamKeys: [String]? = nil) -> WorkspacePair {
        WorkspacePair(
            source: SourceConfig(source: .linear, displayName: "Linear", linearTeamKeys: teamKeys ?? [matchKey]),
            workspace: mapping(matchKey: matchKey),
        )
    }

    private func githubPair(repo: String, path: String = "/tmp/repo") -> WorkspacePair {
        WorkspacePair(
            source: SourceConfig(source: .github, displayName: "GitHub", githubRepos: [repo]),
            workspace: mapping(matchKey: repo, path: path),
        )
    }

    func testPairsRoundTrip() {
        let s = store()
        s.pairs = [linearPair(matchKey: "HRP"), githubPair(repo: "acme/widgets")]
        XCTAssertEqual(s.pairs.count, 2)
        XCTAssertEqual(s.pairs[0].workspace.matchKey, "HRP")
        XCTAssertEqual(s.pairs[1].source.source, .github)
    }

    func testPairCapEnforcedAtTen() {
        let s = store()
        let many = (0 ..< 15).map { linearPair(matchKey: "PFX\($0)") }
        s.pairs = many
        XCTAssertEqual(s.pairs.count, KeychainStore.maxPairs,
                       "Setter must clip to maxPairs.")
    }

    func testPairLookupForLinearRef() {
        let s = store()
        s.pairs = [linearPair(matchKey: "HRP"), linearPair(matchKey: "LEM")]
        let ref = IssueRef(
            id: "n1", identifier: "LEM-42", title: "x", description: nil,
            labelNames: [], scope: .linearTeam(id: "team1"),
        )
        XCTAssertEqual(s.pair(for: ref)?.workspace.matchKey, "LEM")
    }

    func testPairLookupForGitHubRef() {
        let s = store()
        s.pairs = [linearPair(matchKey: "HRP"), githubPair(repo: "acme/widgets")]
        let ref = IssueRef(
            id: "acme/widgets#7", identifier: "acme/widgets#7", title: "x", description: nil,
            labelNames: [], scope: .githubRepo(owner: "acme", repo: "widgets", number: 7),
        )
        XCTAssertEqual(s.pair(for: ref)?.workspace.matchKey, "acme/widgets")
    }

    func testPairLookupIsCaseInsensitive() {
        let s = store()
        s.pairs = [githubPair(repo: "Acme/Widgets")]
        let ref = IssueRef(
            id: "acme/widgets#1", identifier: "acme/widgets#1", title: "x", description: nil,
            labelNames: [], scope: .githubRepo(owner: "acme", repo: "widgets", number: 1),
        )
        XCTAssertNotNil(s.pair(for: ref), "owner/repo match should be case-insensitive.")
    }

    // MARK: - Migration

    func testMigrationFromLegacyWorkspaceConfig() {
        let s = store()
        s.saveWorkspaceRepos([
            WorkspaceRepo(issuePrefix: "HRP", path: "/tmp/a"),
            WorkspaceRepo(issuePrefix: "LEM", path: "/tmp/b"),
        ])
        XCTAssertTrue(s.pairs.count == 2, "Legacy config should migrate to two Linear-source pairs on first read.")
        XCTAssertTrue(s.pairs.allSatisfy { $0.source.source == .linear })
        XCTAssertEqual(s.pairs.map(\.workspace.matchKey).sorted(), ["HRP", "LEM"])
    }

    func testMigrationIsIdempotent() {
        let s = store()
        s.saveWorkspaceRepos([WorkspaceRepo(issuePrefix: "HRP", path: "/tmp/a")])
        _ = s.pairs // triggers migration
        // Mutate pairs to simulate user editing
        s.pairs = [githubPair(repo: "acme/widgets")]
        // A second read must NOT re-overlay the legacy Linear pair on top.
        XCTAssertEqual(s.pairs.count, 1)
        XCTAssertEqual(s.pairs.first?.source.source, .github)
    }

    func testMigrationWithNoLegacyMarksSentinel() {
        let s = store()
        // No saveWorkspaceRepos call → legacy is empty
        _ = s.pairs
        // Subsequent writes shouldn't be disturbed
        s.pairs = [linearPair(matchKey: "HRP")]
        XCTAssertEqual(s.pairs.count, 1)
    }

    func testAuthForLinearPairRequiresKeyAndUserId() {
        let s = store()
        let pair = linearPair(matchKey: "HRP")
        XCTAssertNil(s.authFor(pair: pair))
        s.linearApiKey = "lin_t"; s.linearUserId = "u1"
        XCTAssertNotNil(s.authFor(pair: pair))
    }

    func testAuthForGitHubPairRequiresTokenAndLogin() {
        let s = store()
        let pair = githubPair(repo: "acme/widgets")
        XCTAssertNil(s.authFor(pair: pair))
        s.githubToken = "ghp_t"; s.githubUser = "frkline"
        XCTAssertNotNil(s.authFor(pair: pair))
    }

    // MARK: - Identity refactor migration

    func testMigratePairsToIdentitiesAndWorkspaces() throws {
        let s = store()
        s.linearApiKey = "lin_t"
        s.linearUserId = "user-linear"
        s.githubToken = "ghp_t"
        s.githubUser = "frkline"
        s.pairs = [
            linearPair(matchKey: "HRP"),
            linearPair(matchKey: "LEM"),
            githubPair(repo: "acme/widgets"),
        ]

        // Touch identities → migration runs
        let ids = s.identities
        XCTAssertEqual(ids.count, 2, "One identity per source kind, regardless of pair count.")
        XCTAssertEqual(ids.count(where: { $0.kind == .linear }), 1)
        XCTAssertEqual(ids.count(where: { $0.kind == .github }), 1)

        let linear = try XCTUnwrap(ids.first { $0.kind == .linear })
        let github = try XCTUnwrap(ids.first { $0.kind == .github })
        XCTAssertEqual(linear.handle, "user-linear")
        XCTAssertEqual(github.handle, "frkline")

        // Both HRP and LEM should land as surfaces on the linear identity.
        let linearKeys = Set(linear.knownSurfaces.map(\.key))
        XCTAssertEqual(linearKeys, ["HRP", "LEM"])

        let workspaces = s.workspaces
        XCTAssertEqual(workspaces.count, 3)
        XCTAssertEqual(Set(workspaces.map(\.routing.surfaceId)), ["HRP", "LEM", "acme/widgets"])
        XCTAssertTrue(workspaces.allSatisfy { ws in
            ws.routing.identityId == linear.id || ws.routing.identityId == github.id
        })

        // Per-identity secrets migrated into Keychain memory.
        XCTAssertEqual(s.identitySecret(for: linear.id), "lin_t")
        XCTAssertEqual(s.identitySecret(for: github.id), "ghp_t")
    }

    func testMigrationIsIdempotentAfterUserEdits() {
        let s = store()
        s.linearApiKey = "lin_t"; s.linearUserId = "user-linear"
        s.pairs = [linearPair(matchKey: "HRP")]
        _ = s.identities // triggers migration
        // User then mutates the identity list
        s.identities = []
        // Another read must NOT re-overlay the legacy migration
        XCTAssertEqual(s.identities.count, 0)
        XCTAssertEqual(s.workspaces.count, 1, "Workspace list survives identity edit (separate storage).")
    }

    func testIdentitySecretRoundTrip() {
        let s = store()
        let id = UUID()
        XCTAssertEqual(s.identitySecret(for: id), "")
        s.setIdentitySecret("super-secret", for: id)
        XCTAssertEqual(s.identitySecret(for: id), "super-secret")
        s.deleteIdentitySecret(for: id)
        XCTAssertEqual(s.identitySecret(for: id), "")
    }

    func testAuthForIdentityReturnsCorrectShape() {
        let s = store()
        let linear = Identity(
            kind: .linear, label: "Linear · work", handle: "user",
            principalId: "user-id", host: nil,
        )
        s.identities = [linear]
        XCTAssertNil(s.authFor(identity: linear), "Missing secret → nil.")
        s.setIdentitySecret("lin_secret", for: linear.id)
        guard case let .linear(key, userId) = s.authFor(identity: linear) else {
            return XCTFail("Expected linear auth")
        }
        XCTAssertEqual(key, "lin_secret")
        XCTAssertEqual(userId, "user-id")
    }

    func testIdentityAndSurfaceLookupForWorkspace() {
        let s = store()
        let identity = Identity(
            kind: .github, label: "GitHub", handle: "frkline",
            principalId: "frkline", host: nil,
            knownSurfaces: [
                Surface(id: "acme/widgets", key: "acme/widgets", displayName: "Widgets"),
            ],
        )
        s.identities = [identity]
        let workspace = Workspace(
            path: "/tmp/repo",
            allReposInFolder: false,
            homeRepo: "",
            routing: Routing(identityId: identity.id, surfaceId: "acme/widgets"),
        )
        XCTAssertEqual(s.identity(for: workspace)?.id, identity.id)
        XCTAssertEqual(s.surface(for: workspace)?.displayName, "Widgets")
    }

    // MARK: - isConfigured via the modern (Identity, Workspace, secret) model

    //
    // Regression: persistTrackers() writes identities + workspaces + per-identity
    // secrets but does NOT write to the legacy `pairs` storage. isConfigured
    // used to gate on `pairs`, so on restart it returned false and the wizard
    // re-launched — even though the credential was sitting in Keychain. These
    // tests lock the modern code path against re-introducing that bug.

    private func aiFixtures() throws -> (modelDir: String, swiftLM: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let modelDir = NSTemporaryDirectory() + "kc-test-model-\(UUID().uuidString)"
        let swiftLM = NSTemporaryDirectory() + "kc-test-swiftlm-\(UUID().uuidString)"
        try fm.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        try "{}".write(toFile: modelDir + "/config.json", atomically: true, encoding: .utf8)
        try Data().write(to: URL(fileURLWithPath: swiftLM))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftLM)
        return (modelDir, swiftLM, {
            try? fm.removeItem(atPath: modelDir)
            try? fm.removeItem(atPath: swiftLM)
        })
    }

    func testIsConfiguredTrueWithIdentityAndWorkspaceAndAI() throws {
        let fix = try aiFixtures(); defer { fix.cleanup() }
        let s = store()

        let identity = Identity(
            kind: .github, label: "GitHub · frkline", handle: "frkline",
            principalId: "frkline", host: nil,
        )
        s.identities = [identity]
        s.setIdentitySecret("ghp_modern_path", for: identity.id)
        s.workspaces = [Workspace(
            path: "/tmp/repo",
            routing: Routing(identityId: identity.id, surfaceId: "frkline/lemon"),
        )]
        s.modelPath = fix.modelDir
        s.swiftLMPath = fix.swiftLM
        s.aiEnabled = true

        XCTAssertTrue(s.isConfigured, "Identity + workspace + secret + AI should configure cleanly.")
    }

    func testIsConfiguredFalseWhenIdentitySecretMissing() throws {
        let fix = try aiFixtures(); defer { fix.cleanup() }
        let s = store()

        let identity = Identity(
            kind: .github, label: "GitHub · frkline", handle: "frkline",
            principalId: "frkline", host: nil,
        )
        s.identities = [identity]
        // Deliberately do NOT call setIdentitySecret — the workspace routes
        // through an identity whose Keychain entry is missing.
        s.workspaces = [Workspace(
            path: "/tmp/repo",
            routing: Routing(identityId: identity.id, surfaceId: "frkline/lemon"),
        )]
        s.modelPath = fix.modelDir
        s.swiftLMPath = fix.swiftLM
        s.aiEnabled = true

        XCTAssertFalse(s.isConfigured, "Missing per-identity Keychain secret must NOT count as configured.")
    }

    func testIsConfiguredFalseWhenWorkspaceRoutesToMissingIdentity() throws {
        let fix = try aiFixtures(); defer { fix.cleanup() }
        let s = store()

        // Workspace exists but the identity it routes to was deleted /
        // never persisted. Drift scenario from manual UserDefaults edits
        // or interrupted persists.
        let orphanId = UUID()
        s.identities = []
        s.workspaces = [Workspace(
            path: "/tmp/repo",
            routing: Routing(identityId: orphanId, surfaceId: "any"),
        )]
        s.modelPath = fix.modelDir
        s.swiftLMPath = fix.swiftLM
        s.aiEnabled = true

        XCTAssertFalse(s.isConfigured, "Workspace pointing at a missing identity must NOT count as configured.")
    }

    func testStaleRoutingReturnsNilSurface() {
        let s = store()
        let identity = Identity(
            kind: .linear, label: "Linear", handle: "u",
            principalId: "u-id", host: nil,
            knownSurfaces: [],
        )
        s.identities = [identity]
        let workspace = Workspace(
            path: "/tmp/r",
            routing: Routing(identityId: identity.id, surfaceId: "GONE"),
        )
        XCTAssertNotNil(s.identity(for: workspace), "identity lookup still works")
        XCTAssertNil(s.surface(for: workspace), "surface deleted upstream → nil")
    }
}
