import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    /// In --mock, use in-memory storage so smoke runs / mock data don't
    /// touch real UserDefaults. Non-mock launches keep the production
    /// Keychain + UserDefaults backing.
    static let shared = KeychainStore(
        inMemory: ProcessInfo.processInfo.arguments.contains("--mock"),
    )

    /// Pass --mock to enable fake-data UI mode (no Linear account needed).
    static let isMockMode: Bool = ProcessInfo.processInfo.arguments.contains("--mock")

    /// Pass --smoke-test (alongside --mock) to auto-navigate and screenshot all UI states.
    static let isSmokeTesting: Bool = ProcessInfo.processInfo.arguments.contains("--smoke-test")

    /// Sandbox iteration mode: swaps the tracker for MockIssueClient and seeds a
    /// single fixture workspace/identity so the full poll loop runs against
    /// /tmp/lemon-sandbox with no GitHub/Linear traffic. See SandboxFixtures.
    static let isSandbox: Bool = ProcessInfo.processInfo.arguments.contains("--sandbox")
        || ProcessInfo.processInfo.environment["LEMON_SANDBOX"] == "1"

    /// Detected automatically when launched by XCTest — suppresses Keychain dialogs.
    static let isTestRun: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// non-nil = fully in-memory (tests or mock)
    private var memory: [String: String]?

    private init(inMemory: Bool) {
        self.memory = inMemory ? [:] : nil
    }

    static func makeForTesting() -> KeychainStore {
        KeychainStore(inMemory: true)
    }

    // MARK: - Convenience accessors

    // Only the API key lives in Keychain (it's a secret).
    // userId and workspaceConfig are non-sensitive and stored in UserDefaults.

    var linearApiKey: String {
        get { credential(memoryKey: "linearApiKey", keychainService: "lemon-linear-key", envPrefix: "LEMON_LINEAR_KEY") }
        set { writeCredential(memoryKey: "linearApiKey", keychainService: "lemon-linear-key", envPrefix: "LEMON_LINEAR_KEY", value: newValue) }
    }

    var githubToken: String {
        get { credential(memoryKey: "githubToken", keychainService: "lemon-github-token", envPrefix: "LEMON_GITHUB_TOKEN") }
        set { writeCredential(memoryKey: "githubToken", keychainService: "lemon-github-token", envPrefix: "LEMON_GITHUB_TOKEN", value: newValue) }
    }

    /// Returns the bypass value (from {prefix} or {prefix}_FILE) or nil if
    /// neither env var is set. Trims whitespace and expands ~ in paths.
    ///
    /// Used for unattended iteration loops and recursive Claude-Code-driving-Lemon
    /// sessions. Both forms skip Keychain entirely, which avoids the OS prompt
    /// on first launch and keeps tests/scripts headless. Direct value wins
    /// over file path.
    ///   {prefix}=lin_...       — value inline (less safe)
    ///   {prefix}_FILE=~/path   — read from disk (file perms = auth)
    static func envBypass(prefix: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let direct = env[prefix]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty
        {
            return direct
        }
        if let raw = env["\(prefix)_FILE"], !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Back-compat shim for callers that haven't migrated to envBypass(prefix:).
    static func envKeyBypass() -> String? {
        envBypass(prefix: "LEMON_LINEAR_KEY")
    }

    /// Shared credential read/write so Linear + GitHub follow identical
    /// env-bypass + in-memory + Keychain semantics.
    private func credential(memoryKey: String, keychainService: String, envPrefix: String) -> String {
        if memory != nil { return memory?[memoryKey] ?? "" }
        if let bypass = Self.envBypass(prefix: envPrefix) { return bypass }
        if Self.isTestRun || Self.isMockMode { return "" }
        return readKeychain(keychainService) ?? ""
    }

    private func writeCredential(memoryKey: String, keychainService: String, envPrefix: String, value: String) {
        if memory != nil { memory?[memoryKey] = value; return }
        if Self.isTestRun || Self.isMockMode { return }
        // Don't mutate the real Keychain entry when env-var bypass is in
        // play — the user is explicitly running with an external key, so
        // writes should be no-ops to avoid polluting their stored secret.
        if Self.envBypass(prefix: envPrefix) != nil { return }
        writeKeychain(keychainService, value: value)
    }

    var linearUserId: String {
        get {
            if memory != nil { return memory?["linearUserId"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-linear-user-id") ?? ""
        }
        set {
            if memory != nil { memory?["linearUserId"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-linear-user-id")
        }
    }

    var githubUser: String {
        get {
            if memory != nil { return memory?["githubUser"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-github-user") ?? ""
        }
        set {
            if memory != nil { memory?["githubUser"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-github-user")
        }
    }

    var workspaceConfig: String {
        get {
            if memory != nil { return memory?["workspaceConfig"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-workspace-config") ?? ""
        }
        set {
            if memory != nil { memory?["workspaceConfig"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-workspace-config")
        }
    }

    // MARK: - Workspace pairs (replacement for workspaceRepos)

    //
    // The pair list lives under "lemon-workspace-pairs". On first read after
    // the multi-source upgrade we migrate any legacy "lemon-workspace-config"
    // into a single Linear-source pair list and stamp the migration sentinel.
    //
    // Cap: 10 pairs. Enforced on the setter; the UI also disables "Add"
    // buttons at the cap. The number is soft — raise it if real users hit it,
    // but it bounds per-poll fan-out and keeps the Settings list legible.

    static let maxPairs = 10

    var pairs: [WorkspacePair] {
        get {
            migrateLegacyWorkspaceIfNeeded()
            let json = pairsJSON
            guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([WorkspacePair].self, from: data)) ?? []
        }
        set {
            let clipped = Array(newValue.prefix(Self.maxPairs))
            guard let data = try? JSONEncoder().encode(clipped),
                  let json = String(data: data, encoding: .utf8) else { return }
            pairsJSON = json
        }
    }

    private var pairsJSON: String {
        get {
            if memory != nil { return memory?["workspacePairs"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-workspace-pairs") ?? ""
        }
        set {
            if memory != nil { memory?["workspacePairs"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-workspace-pairs")
        }
    }

    private var migrationSentinel: String {
        get {
            if memory != nil { return memory?["pairsMigratedAt"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-workspace-config-migrated-at") ?? ""
        }
        set {
            if memory != nil { memory?["pairsMigratedAt"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-workspace-config-migrated-at")
        }
    }

    /// Idempotent. After the first successful migration the sentinel keeps it
    /// off; deleting "lemon-workspace-pairs" without clearing the sentinel
    /// does NOT cause a re-migration (the user has explicitly emptied their
    /// pair list).
    func migrateLegacyWorkspaceIfNeeded() {
        guard migrationSentinel.isEmpty else { return }
        let legacy = workspaceRepos
        guard !legacy.isEmpty else {
            // No legacy data → mark migrated so we don't keep checking.
            migrationSentinel = ISO8601DateFormatter().string(from: Date())
            return
        }
        let linearSource = SourceConfig(
            source: .linear,
            displayName: "Linear",
            linearTeamKeys: legacy.map(\.issuePrefix),
            githubRepos: nil,
        )
        let migrated = legacy.map { repo in
            WorkspacePair(
                source: linearSource,
                workspace: WorkspaceMapping(
                    matchKey: repo.issuePrefix,
                    path: repo.path,
                    allReposInFolder: repo.allReposInFolder,
                    homeRepo: repo.homeRepo,
                ),
            )
        }
        if let data = try? JSONEncoder().encode(migrated),
           let json = String(data: data, encoding: .utf8)
        {
            pairsJSON = json
            migrationSentinel = ISO8601DateFormatter().string(from: Date())
        }
    }

    /// Pair lookup keyed by IssueRef. Linear refs match by team key prefix
    /// (the matchKey); GitHub refs match by "owner/repo".
    func pair(for ref: IssueRef) -> WorkspacePair? {
        switch ref.scope {
        case .linearTeam:
            let needle = ref.identifierPrefix.lowercased()
            return pairs.first { pair in
                pair.source.source == .linear &&
                    pair.workspace.matchKey.lowercased() == needle
            }
        case let .githubRepo(owner, repo, _):
            let needle = "\(owner)/\(repo)".lowercased()
            return pairs.first { pair in
                pair.source.source == .github &&
                    pair.workspace.matchKey.lowercased() == needle
            }
        }
    }

    /// SourceAuth assembled per pair from the credentials in this store.
    /// Nil if the credential for the pair's source is missing.
    func authFor(pair: WorkspacePair) -> SourceAuth? {
        switch pair.source.source {
        case .linear:
            guard !linearApiKey.isEmpty, !linearUserId.isEmpty else { return nil }
            return .linear(apiKey: linearApiKey, userId: linearUserId)
        case .github:
            guard !githubToken.isEmpty, !githubUser.isEmpty else { return nil }
            return .github(pat: githubToken, login: githubUser)
        }
    }

    /// Looser than `authFor` — used by `isConfigured` to gate UI without
    /// demanding a fully-resolved principal id. linearUserId / githubUser are
    /// hydrated at first verifyCredential and during onboarding.
    private func credentialPresent(for pair: WorkspacePair) -> Bool {
        switch pair.source.source {
        case .linear: !linearApiKey.isEmpty
        case .github: !githubToken.isEmpty
        }
    }

    var isConfigured: Bool {
        if Self.isMockMode || Self.isSandbox { return true }
        // Real Keychain store in test mode: always false to prevent the Keychain dialog
        // when there's no user to click it. In-memory stores (makeForTesting) are unaffected.
        if memory == nil, Self.isTestRun { return false }
        // Source of truth is the new (Identity, Workspace) model — the old
        // synthesized `pairs` view is no longer written by onboarding so
        // gating on it would force the wizard to re-launch on every
        // restart even after a successful save.
        let configuredWorkspaces = workspaces
        guard !configuredWorkspaces.isEmpty else { return false }
        for ws in configuredWorkspaces {
            guard let identity = identity(for: ws) else { return false }
            // Per-identity Keychain entry — the actual GitHub PAT /
            // Linear API key live here, keyed by Identity.id.
            if identitySecret(for: identity.id).isEmpty { return false }
        }
        // Local AI is required AND its files must still exist on disk. Without
        // the disk-existence check, a user who upgraded across a dirName
        // change (or deleted ~/Library/Application Support/Lemon/Models) would
        // keep aiEnabled=true and slip into the main app with a broken model.
        let fm = FileManager.default
        return aiEnabled
            && !modelPath.isEmpty
            && fm.fileExists(atPath: modelPath + "/config.json")
            && !swiftLMPath.isEmpty
            && fm.isExecutableFile(atPath: swiftLMPath)
    }

    // MARK: - Identities + Workspaces (the richer model per the

    //         identity refactor discussion). Identities are credentials with
    //         their cached surfaces; Workspaces are local folders with a
    //         single routing into an identity+surface. The old `pairs` API
    //         is kept as a synthesized read-only view during the transition.

    var identities: [Identity] {
        get {
            if Self.isSandbox { return [SandboxFixtures.identity] }
            migrateLegacyWorkspaceIfNeeded()
            migrateLegacyPairsIfNeeded()
            let json = identitiesJSON
            guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Identity].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            identitiesJSON = json
        }
    }

    var workspaces: [Workspace] {
        get {
            if Self.isSandbox { return [SandboxFixtures.workspace] }
            migrateLegacyWorkspaceIfNeeded()
            migrateLegacyPairsIfNeeded()
            let json = workspacesJSON
            guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
        }
        set {
            let clipped = Array(newValue.prefix(Self.maxPairs))
            guard let data = try? JSONEncoder().encode(clipped),
                  let json = String(data: data, encoding: .utf8) else { return }
            workspacesJSON = json
        }
    }

    private var identitiesJSON: String {
        get {
            if memory != nil { return memory?["identities"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-identities") ?? ""
        }
        set {
            if memory != nil { memory?["identities"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-identities")
        }
    }

    private var workspacesJSON: String {
        get {
            if memory != nil { return memory?["workspaces"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-workspaces") ?? ""
        }
        set {
            if memory != nil { memory?["workspaces"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-workspaces")
        }
    }

    private var identityMigrationSentinel: String {
        get {
            if memory != nil { return memory?["identityMigratedAt"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-identity-migrated-at") ?? ""
        }
        set {
            if memory != nil { memory?["identityMigratedAt"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-identity-migrated-at")
        }
    }

    /// One-shot migration: pairs + legacy linearApiKey/githubToken → identities + workspaces.
    /// Idempotent via `identityMigrationSentinel`. Runs lazily on first read of
    /// `identities` or `workspaces`.
    func migrateLegacyPairsIfNeeded() {
        guard identityMigrationSentinel.isEmpty else { return }

        let legacyPairs = decodedPairs()
        guard !legacyPairs.isEmpty else {
            identityMigrationSentinel = ISO8601DateFormatter().string(from: Date())
            return
        }

        // Group pairs by source so we make at most one identity per source.
        var linearIdentity: Identity?
        var githubIdentity: Identity?
        var newWorkspaces: [Workspace] = []

        for pair in legacyPairs {
            switch pair.source.source {
            case .linear:
                if linearIdentity == nil {
                    let surfaces = (pair.source.linearTeamKeys ?? []).filter { !$0.isEmpty }.map {
                        Surface(id: $0, key: $0, displayName: $0)
                    }
                    linearIdentity = Identity(
                        kind: .linear,
                        label: linearUserId.isEmpty ? "Linear" : "Linear · \(linearUserId.prefix(8))",
                        handle: linearUserId,
                        principalId: linearUserId,
                        host: nil,
                        knownSurfaces: surfaces,
                        surfacesFetchedAt: surfaces.isEmpty ? nil : Date(),
                    )
                    if !linearApiKey.isEmpty, let id = linearIdentity?.id {
                        setIdentitySecret(linearApiKey, for: id)
                    }
                } else if let existing = linearIdentity, !pair.workspace.matchKey.isEmpty,
                          !existing.knownSurfaces.contains(where: { $0.key == pair.workspace.matchKey })
                {
                    linearIdentity?.knownSurfaces.append(
                        Surface(id: pair.workspace.matchKey,
                                key: pair.workspace.matchKey,
                                displayName: pair.workspace.matchKey),
                    )
                }

                if let identityId = linearIdentity?.id {
                    newWorkspaces.append(Workspace(
                        path: pair.workspace.path,
                        allReposInFolder: pair.workspace.allReposInFolder,
                        homeRepo: pair.workspace.homeRepo,
                        routing: Routing(
                            identityId: identityId,
                            surfaceId: pair.workspace.matchKey,
                        ),
                    ))
                }

            case .github:
                if githubIdentity == nil {
                    let surfaces = (pair.source.githubRepos ?? []).filter { !$0.isEmpty }.map {
                        Surface(id: $0, key: $0, displayName: $0)
                    }
                    githubIdentity = Identity(
                        kind: .github,
                        label: githubUser.isEmpty ? "GitHub" : "GitHub · @\(githubUser)",
                        handle: githubUser,
                        principalId: githubUser,
                        host: nil,
                        knownSurfaces: surfaces,
                        surfacesFetchedAt: surfaces.isEmpty ? nil : Date(),
                    )
                    if !githubToken.isEmpty, let id = githubIdentity?.id {
                        setIdentitySecret(githubToken, for: id)
                    }
                } else if let existing = githubIdentity, !pair.workspace.matchKey.isEmpty,
                          !existing.knownSurfaces.contains(where: { $0.key == pair.workspace.matchKey })
                {
                    githubIdentity?.knownSurfaces.append(
                        Surface(id: pair.workspace.matchKey,
                                key: pair.workspace.matchKey,
                                displayName: pair.workspace.matchKey),
                    )
                }

                if let identityId = githubIdentity?.id {
                    newWorkspaces.append(Workspace(
                        path: pair.workspace.path,
                        allReposInFolder: pair.workspace.allReposInFolder,
                        homeRepo: pair.workspace.homeRepo,
                        routing: Routing(
                            identityId: identityId,
                            surfaceId: pair.workspace.matchKey,
                        ),
                    ))
                }
            }
        }

        var migrated: [Identity] = []
        if let l = linearIdentity { migrated.append(l) }
        if let g = githubIdentity { migrated.append(g) }

        if let data = try? JSONEncoder().encode(migrated),
           let json = String(data: data, encoding: .utf8)
        {
            identitiesJSON = json
        }
        if let data = try? JSONEncoder().encode(newWorkspaces),
           let json = String(data: data, encoding: .utf8)
        {
            workspacesJSON = json
        }
        identityMigrationSentinel = ISO8601DateFormatter().string(from: Date())
    }

    /// Read pairs directly without triggering the recursive migration chain
    /// (used internally during migration to avoid infinite mutual recursion).
    private func decodedPairs() -> [WorkspacePair] {
        let json = pairsJSON
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkspacePair].self, from: data)) ?? []
    }

    // MARK: - Per-identity secret (Keychain)

    //
    // Each Identity carries its credential in Keychain under
    // "lemon-identity-{uuid}-secret". Linear's credential is the API key;
    // GitHub's is the PAT. Memory-backed stores keep them in-process.

    func identitySecret(for identityId: UUID) -> String {
        let memoryKey = "id-\(identityId.uuidString)-secret"
        let service = "lemon-identity-\(identityId.uuidString)-secret"
        if memory != nil { return memory?[memoryKey] ?? "" }
        if Self.isTestRun || Self.isMockMode { return "" }
        return readKeychain(service) ?? ""
    }

    func setIdentitySecret(_ value: String, for identityId: UUID) {
        let memoryKey = "id-\(identityId.uuidString)-secret"
        let service = "lemon-identity-\(identityId.uuidString)-secret"
        if memory != nil { memory?[memoryKey] = value; return }
        if Self.isTestRun || Self.isMockMode { return }
        writeKeychain(service, value: value)
    }

    func deleteIdentitySecret(for identityId: UUID) {
        let memoryKey = "id-\(identityId.uuidString)-secret"
        let service = "lemon-identity-\(identityId.uuidString)-secret"
        if memory != nil { memory?.removeValue(forKey: memoryKey); return }
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: service] as CFDictionary)
    }

    /// Build a `SourceAuth` from an identity. Returns nil if the credential
    /// or principal is missing.
    func authFor(identity: Identity) -> SourceAuth? {
        if Self.isSandbox { return SandboxFixtures.auth }
        let secret = identitySecret(for: identity.id)
        guard !secret.isEmpty, !identity.principalId.isEmpty else { return nil }
        switch identity.kind {
        case .linear:
            return .linear(apiKey: secret, userId: identity.principalId)
        case .github:
            // GitHub Enterprise: Identity.host holds the API host
            // ("api.github.acmecorp.com"); github.com identities leave it nil.
            return .github(pat: secret, login: identity.handle, host: identity.host)
        }
    }

    /// Lookup a Workspace's identity by id, returning nil if the routing
    /// points at a deleted identity (graceful drift handling).
    func identity(for workspace: Workspace) -> Identity? {
        identities.first { $0.id == workspace.routing.identityId }
    }

    /// Lookup the routed Surface on the identity, or nil if it was removed
    /// upstream (team deleted on Linear, repo deleted on GitHub, etc.).
    func surface(for workspace: Workspace) -> Surface? {
        identity(for: workspace).flatMap { ident in
            ident.knownSurfaces.first { $0.id == workspace.routing.surfaceId }
        }
    }

    // MARK: - Legacy workspace repos helpers

    //
    // Kept one release for any external callers (older onboarding paths,
    // tests that pre-date the pair model). Reads decode the legacy JSON
    // directly; writes still target the legacy key. `pairs` is authoritative.

    var workspaceRepos: [WorkspaceRepo] {
        guard let data = workspaceConfig.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkspaceRepo].self, from: data)) ?? []
    }

    func saveWorkspaceRepos(_ repos: [WorkspaceRepo]) {
        guard let data = try? JSONEncoder().encode(repos),
              let json = String(data: data, encoding: .utf8) else { return }
        workspaceConfig = json
    }

    func repoFor(issuePrefix: String) -> WorkspaceRepo? {
        workspaceRepos.first { $0.issuePrefix.lowercased() == issuePrefix.lowercased() }
    }

    // MARK: - Local AI config (UserDefaults, non-sensitive)

    var swiftLMPath: String {
        get {
            if memory != nil { return memory?["swiftLMPath"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-swiftlm-path") ?? ""
        }
        set {
            if memory != nil { memory?["swiftLMPath"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-swiftlm-path")
        }
    }

    var modelPath: String {
        get {
            if memory != nil { return memory?["modelPath"] ?? "" }
            return UserDefaults.standard.string(forKey: "lemon-gemma-model-path") ?? ""
        }
        set {
            if memory != nil { memory?["modelPath"] = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-gemma-model-path")
        }
    }

    var aiEnabled: Bool {
        get {
            if memory != nil { return memory?["aiEnabled"] == "1" }
            return UserDefaults.standard.bool(forKey: "lemon-ai-enabled")
        }
        set {
            if memory != nil { memory?["aiEnabled"] = newValue ? "1" : "0"; return }
            UserDefaults.standard.set(newValue, forKey: "lemon-ai-enabled")
        }
    }

    // MARK: - Legacy write shim (called from onboarding finish())

    @discardableResult
    func write(_ key: LegacyKey, value: String) -> Bool {
        switch key {
        case .linearApiKey: linearApiKey = value; return true
        case .linearUserId: linearUserId = value; return true
        case .workspaceConfig: workspaceConfig = value; return true
        }
    }

    /// Keys still referenced in OnboardingView.finish()
    enum LegacyKey {
        case linearApiKey, linearUserId, workspaceConfig
    }

    // MARK: - Keychain (API key only)

    func deleteAll() {
        if memory != nil { memory = [:]; return }
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: "lemon-linear-key"] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: "lemon-github-token"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "lemon-linear-user-id")
        UserDefaults.standard.removeObject(forKey: "lemon-github-user")
        UserDefaults.standard.removeObject(forKey: "lemon-workspace-config")
        UserDefaults.standard.removeObject(forKey: "lemon-workspace-pairs")
        UserDefaults.standard.removeObject(forKey: "lemon-workspace-config-migrated-at")
        UserDefaults.standard.removeObject(forKey: "lemon-swiftlm-path")
        UserDefaults.standard.removeObject(forKey: "lemon-gemma-model-path")
        UserDefaults.standard.removeObject(forKey: "lemon-ai-enabled")
    }

    private func readKeychain(_ service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ service: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
