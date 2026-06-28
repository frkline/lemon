import Foundation
import os
import SwiftUI

/// Per-workspace diagnostic snapshot — surfaced in Settings so the user can
/// see at a glance whether each configured workspace is healthy. Updated
/// after every pollWorkspace call (success or failure).
struct WorkspaceStatus: Equatable {
    var lastPolledAt: Date?
    var triggerCount: Int = 0
    var completeCount: Int = 0
    var error: String?

    /// One-line settings subtitle: "polled 12s ago · 0 queued · 1 complete".
    /// Returns nil pre-first-poll so the row stays editorial-quiet.
    var subtitle: String? {
        guard let t = lastPolledAt else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let rel = f.localizedString(for: t, relativeTo: Date())
        if let err = error {
            return "polled \(rel) · \(err.prefix(80))"
        }
        return "polled \(rel) · \(triggerCount) queued · \(completeCount) complete"
    }
}

/// Back-compat alias for any view code still naming PairStatus.
typealias PairStatus = WorkspaceStatus

@Observable
@MainActor
final class Orchestrator {
    let sessions = SessionStore()
    var lastPollError: String?
    var lastPolledAt: Date?
    var isPolling = false
    var aiState: LocalLLM.AIState = .notConfigured

    /// Per-workspace diagnostics keyed on Workspace.id. Settings reads this
    /// to render each workspace row's connection chip + subtitle line.
    var workspaceStatuses: [UUID: WorkspaceStatus] = [:]

    func workspaceStatus(for workspaceId: UUID) -> WorkspaceStatus? {
        workspaceStatuses[workspaceId]
    }

    /// Back-compat readers for any view still keyed on the old pair shape.
    var pairStatuses: [UUID: WorkspaceStatus] {
        workspaceStatuses
    }

    func pairStatus(for pairId: UUID) -> WorkspaceStatus? {
        workspaceStatuses[pairId]
    }

    // Per-source clients, lazily created on first use per process.
    private let linearClient = LinearClient()
    private let githubClient = GitHubClient()
    // Sandbox iteration mode: a single file-backed client replaces both, so the
    // poll loop runs against /tmp/lemon-sandbox fixtures. See SandboxFixtures.
    private let mockClient = MockIssueClient()
    private var pollTask: Task<Void, Never>?
    private var runners: [UUID: WorktreeRunner] = [:]

    private func client(for identity: Identity) -> any IssueSourceClient {
        client(for: identity.kind)
    }

    /// Public client resolver — used by the editor when adding a new identity
    /// (verify + list surfaces) before the identity is persisted.
    func client(for kind: IdentityKind) -> any IssueSourceClient {
        if KeychainStore.isSandbox { return mockClient }
        switch kind {
        case .linear: return linearClient
        case .github: return githubClient
        }
    }

    /// Result of a verify-credential pass on a new identity. The identity
    /// surface includes the verified login, a fresh surface list, and a
    /// count of open issues currently assigned to the user — the editor
    /// shows that count instead of the abstract "surfaces" number so the
    /// user gets concrete proof the credential reaches actual work.
    struct IdentityVerifyResult {
        let credential: CredentialIdentity
        let surfaces: [Surface]
        let assignedIssueCount: Int
    }

    /// Verify a credential + pull the user's known surfaces + assigned-issue
    /// count in one shot. Used by the identity-add flow in Settings.
    func verifyAndDiscover(kind: IdentityKind, token: String, host: String?) async throws -> IdentityVerifyResult {
        let cli = client(for: kind)
        let credential = try await cli.verifyCredential(token: token, host: host)
        let surfaces = await (try? cli.listSurfaces(token: token, host: host)) ?? []
        // For Linear, the assigned-count query uses the user node id; for
        // GitHub, the search expects the `login` (handle). The credential
        // exposes both via `id` and `handle` so we pick the right one per kind.
        let principal: String = switch kind {
        case .linear: credential.id
        case .github: credential.handle
        }
        let assignedCount = await (try? cli.countAssignedOpenIssues(
            token: token, host: host, principalId: principal,
        )) ?? 0
        return IdentityVerifyResult(
            credential: credential,
            surfaces: surfaces,
            assignedIssueCount: assignedCount,
        )
    }

    /// Re-fetch surfaces for an existing identity and persist the updated
    /// `knownSurfaces` + `surfacesFetchedAt`. Silently logs on failure so a
    /// refresh-button tap never breaks the editor.
    func refreshSurfaces(identityId: UUID) async {
        let keychain = KeychainStore.shared
        guard let identity = keychain.identities.first(where: { $0.id == identityId }) else { return }
        let secret = keychain.identitySecret(for: identityId)
        guard !secret.isEmpty else {
            Logger.orchestrator.info("Refresh surfaces skipped \(identity.label): no secret")
            return
        }
        let cli = client(for: identity.kind)
        do {
            let surfaces = try await cli.listSurfaces(token: secret, host: identity.host)
            var updated = identity
            updated.knownSurfaces = surfaces
            updated.surfacesFetchedAt = Date()
            var all = keychain.identities
            if let idx = all.firstIndex(where: { $0.id == identityId }) {
                all[idx] = updated
                keychain.identities = all
                Logger.orchestrator.info("Refreshed \(surfaces.count) surfaces for \(identity.label)")
            }
        } catch {
            Logger.orchestrator.error("Refresh surfaces failed for \(identity.label): \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        Task { await LocalLLM.shared.start() }
        Task { @MainActor [weak self] in
            self?.reconstructDanglingSessions()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                // Poll faster when sessions are active so status updates feel responsive.
                let hasActive = self?.sessions.active.isEmpty == false
                try? await Task.sleep(for: .seconds(hasActive ? 15 : 45))
            }
        }
    }

    /// On launch, scan `/tmp/lemon-*` for worktrees Lemon left behind in
    /// a previous process. Match each by slug-shape against the
    /// configured workspaces, then synthesize a Session in `.reviewing`
    /// with `cleanupInfo` populated. The user sees the stuck session in
    /// the active list with a "Cleanup worktree" affordance ready to
    /// fire — no manual `git worktree remove` required.
    @MainActor
    private func reconstructDanglingSessions() {
        let fm = FileManager.default
        guard let tmpEntries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        let lemonDirs = tmpEntries.filter { $0.hasPrefix("lemon-") }
        guard !lemonDirs.isEmpty else { return }

        let keychain = KeychainStore.shared
        let workspaces = keychain.workspaces
        guard !workspaces.isEmpty else { return }

        for dirName in lemonDirs {
            let slug = String(dirName.dropFirst("lemon-".count))
            let sessionPath = "/tmp/\(dirName)"

            // Skip Lemon's own tmp scratch dirs (build output, smoke
            // results, etc.) — only directories whose name matches the
            // `lemon-<slug>` worktree convention count.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Already tracked this process — skip.
            if sessions.active.contains(where: { $0.cleanupInfo?.slug == slug }) { continue }
            if sessions.recent.contains(where: { $0.cleanupInfo?.slug == slug }) { continue }

            guard let (ref, info) = matchSlugToWorkspace(slug: slug, sessionPath: sessionPath,
                                                         workspaces: workspaces) else { continue }
            let session = Session(issue: ref)
            session.status = .reviewing
            session.worktreePath = sessionPath
            session.cleanupInfo = info
            session.appendLog("[lemon] reconstructed on launch — worktree at \(sessionPath)")
            sessions.add(session)
            Logger.orchestrator.info("Reconstructed dangling session for \(ref.identifier) at \(sessionPath)")
        }
    }

    /// Match a slug ("lem-42" / "frkline-lemon-14") against a configured
    /// workspace's expected slug shape. Returns the synthesized IssueRef
    /// and cleanupInfo on a hit, nil otherwise.
    private func matchSlugToWorkspace(slug: String, sessionPath: String,
                                      workspaces: [Workspace]) -> (IssueRef, WorktreeCleanupInfo)?
    {
        for ws in workspaces {
            let surfaceId = ws.routing.surfaceId
            guard !surfaceId.isEmpty else { continue }
            // Linear: surfaceId is the team key (e.g. "LEM"); slug is
            // "lem-<number>".
            if let identity = KeychainStore.shared.identity(for: ws),
               identity.kind == .linear
            {
                let prefix = surfaceId.lowercased() + "-"
                if slug.hasPrefix(prefix),
                   let _ = Int(slug.dropFirst(prefix.count))
                {
                    let identifier = slug.uppercased().replacingOccurrences(of: "-", with: "-")
                    let ref = IssueRef(
                        id: "reconstructed-\(slug)",
                        identifier: identifier,
                        title: identifier,
                        description: nil,
                        labelNames: [],
                        scope: .linearTeam(id: surfaceId),
                    )
                    return (ref, makeCleanupInfo(slug: slug, sessionPath: sessionPath, workspace: ws))
                }
            }
            // GitHub: surfaceId is "owner/repo"; slug is
            // "owner-repo-<number>" lowercased.
            if let identity = KeychainStore.shared.identity(for: ws),
               identity.kind == .github
            {
                let flat = surfaceId.lowercased().replacingOccurrences(of: "/", with: "-") + "-"
                if slug.hasPrefix(flat),
                   let number = Int(slug.dropFirst(flat.count))
                {
                    let parts = surfaceId.split(separator: "/", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let owner = String(parts[0]); let repo = String(parts[1])
                    let identifier = "\(owner)/\(repo)#\(number)"
                    let ref = IssueRef(
                        id: identifier,
                        identifier: identifier,
                        title: identifier,
                        description: nil,
                        labelNames: [],
                        scope: .githubRepo(owner: owner, repo: repo, number: number),
                    )
                    return (ref, makeCleanupInfo(slug: slug, sessionPath: sessionPath, workspace: ws))
                }
            }
        }
        return nil
    }

    private func makeCleanupInfo(slug: String, sessionPath: String,
                                 workspace: Workspace) -> WorktreeCleanupInfo
    {
        // For allReposInFolder workspaces, we can't reliably know which
        // repos were checked out without rescanning — fall back to the
        // single-repo shape pointing at the workspace path. The cleanup
        // helper's FileManager fallback handles any stragglers under
        // sessionPath anyway.
        let workspaceName = URL(fileURLWithPath: workspace.path).lastPathComponent
        return WorktreeCleanupInfo(
            sessionPath: sessionPath,
            isMultiRepo: workspace.allReposInFolder,
            repos: [WorktreeCleanupInfo.RepoRef(name: workspaceName, repoPath: workspace.path)],
            slug: slug,
        )
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    @MainActor
    private func poll() async {
        let keychain = KeychainStore.shared
        guard keychain.isConfigured else {
            lastPollError = "Not configured — open Settings."
            return
        }

        isPolling = true
        defer {
            isPolling = false
            lastPolledAt = Date()
            aiState = LocalLLM.shared.state()
        }

        let workspaces = keychain.workspaces
        guard !workspaces.isEmpty else {
            lastPollError = "No workspaces configured."
            return
        }

        lastPollError = nil

        // Bootstrap labels once per process per (identity, surface) combo.
        // Failures don't abort polling — bootstrapLabels logs and retries.
        await bootstrapLabels(workspaces: workspaces, keychain: keychain)

        // Iterate workspaces sequentially: avoids GitHub rate-limit bursts
        // on first poll and keeps log lines easy to follow per source.
        for workspace in workspaces {
            guard let identity = keychain.identity(for: workspace) else {
                workspaceStatuses[workspace.id] = WorkspaceStatus(
                    lastPolledAt: Date(),
                    error: "Routing points at a deleted identity. Edit the workspace.",
                )
                continue
            }
            guard let auth = keychain.authFor(identity: identity) else {
                Logger.orchestrator.info("Skip workspace \(workspace.path): \(identity.label) credentials missing")
                workspaceStatuses[workspace.id] = WorkspaceStatus(
                    lastPolledAt: Date(),
                    error: "\(identity.label): credentials missing",
                )
                continue
            }
            let cli = client(for: identity)
            await pollWorkspace(workspace: workspace, identity: identity, client: cli, auth: auth)
        }
    }

    @MainActor
    private func pollWorkspace(workspace: Workspace, identity: Identity,
                               client: any IssueSourceClient, auth: SourceAuth) async
    {
        var status = workspaceStatuses[workspace.id] ?? WorkspaceStatus()
        let config = sourceConfig(identity: identity, surfaceId: workspace.routing.surfaceId)
        let scopeTag = "\(identity.kind.rawValue)/\(workspace.routing.surfaceId)"
        do {
            // 1. New 🍋-labeled issues → start a session.
            let newIssues = try await client.fetchTriggerQueue(config: config, auth: auth)
            status.triggerCount = newIssues.count
            Logger.orchestrator.info("Poll[\(scopeTag)]: \(newIssues.count) queued, \(self.sessions.active.count) active")

            for ref in newIssues {
                guard !sessions.isTracking(ref: ref) else { continue }
                guard sessions.active.count < maxConcurrent else {
                    Logger.orchestrator.info("At max concurrent sessions, skipping \(ref.identifier)")
                    break
                }
                Logger.orchestrator.info("Starting session for \(ref.identifier): \(ref.title)")
                await startSession(ref: ref, workspace: workspace, identity: identity,
                                   client: client, auth: auth, retrigger: nil)
            }

            // 2. 🍋 Complete issues → check for human replies to re-trigger.
            let completeIssues = try await client.fetchCompleteQueue(config: config, auth: auth)
            status.completeCount = completeIssues.count
            Logger.orchestrator.info("Poll[\(scopeTag)]: \(completeIssues.count) complete issues to check for replies")
            for ref in completeIssues {
                if sessions.isTracking(ref: ref) {
                    Logger.orchestrator.info("Retrigger skip \(ref.identifier): already tracking")
                    continue
                }
                let maybeMarker: LemonMarker?
                do {
                    maybeMarker = try await client.findLemonMarker(ref: ref, auth: auth)
                } catch {
                    Logger.orchestrator.error("Retrigger skip \(ref.identifier): findLemonMarker error: \(error.localizedDescription)")
                    continue
                }
                guard let marker = maybeMarker else {
                    Logger.orchestrator.info("Retrigger skip \(ref.identifier): no Lemon marker found")
                    continue
                }
                let hasReply: Bool
                do {
                    hasReply = try await client.hasNewComment(ref: ref, afterCommentId: marker.commentId, auth: auth)
                } catch {
                    Logger.orchestrator.error("Retrigger \(ref.identifier) hasNewComment failed: \(error)")
                    continue
                }
                if !hasReply {
                    Logger.orchestrator.info("Retrigger skip \(ref.identifier): no new comment after marker \(marker.commentId)")
                    continue
                }
                Logger.orchestrator.info("Re-triggering \(ref.identifier) from reply")
                await startSession(ref: ref, workspace: workspace, identity: identity,
                                   client: client, auth: auth, retrigger: marker)
            }
            status.error = nil
        } catch {
            Logger.orchestrator.error("Poll error for workspace \(workspace.path) [\(scopeTag)]: \(error)")
            status.error = error.localizedDescription
            lastPollError = error.localizedDescription
        }
        status.lastPolledAt = Date()
        workspaceStatuses[workspace.id] = status
    }

    /// Build the per-call SourceConfig from an identity + the surface the
    /// workspace is routed to. Linear: filter by team key (surfaceId);
    /// GitHub: filter by owner/repo (surfaceId).
    private func sourceConfig(identity: Identity, surfaceId: String) -> SourceConfig {
        switch identity.kind {
        case .linear:
            SourceConfig(
                source: .linear, displayName: identity.label,
                linearTeamKeys: [surfaceId], githubRepos: nil,
            )
        case .github:
            SourceConfig(
                source: .github, displayName: identity.label,
                linearTeamKeys: nil, githubRepos: [surfaceId],
            )
        }
    }

    private var maxConcurrent: Int {
        2
    }

    // MARK: - Label bootstrapping

    /// Memo keyed on (identity.id, surfaceId) so bootstrapping a Linear team
    /// or GitHub repo happens at most once per process, even if multiple
    /// workspaces route to the same surface.
    private var bootstrappedScopes: Set<String> = []

    private func bootstrapLabels(workspaces: [Workspace], keychain: KeychainStore) async {
        for workspace in workspaces {
            let scopeKey = "\(workspace.routing.identityId.uuidString)/\(workspace.routing.surfaceId)"
            if bootstrappedScopes.contains(scopeKey) { continue }
            guard let identity = keychain.identity(for: workspace),
                  let auth = keychain.authFor(identity: identity) else { continue }
            let cli = client(for: identity)
            let config = sourceConfig(identity: identity, surfaceId: workspace.routing.surfaceId)
            do {
                try await cli.bootstrapLabels(config: config, auth: auth)
                bootstrappedScopes.insert(scopeKey)
                Logger.orchestrator.info("Bootstrapped labels for \(scopeKey)")
            } catch {
                Logger.orchestrator.error("Label bootstrap failed for \(scopeKey): \(error) — will retry on next poll")
            }
        }
    }

    /// User-triggered re-bootstrap of the 🍋 state labels for one
    /// (identity, surface) scope. Used by the workspace editor's
    /// "Re-seed 🍋 labels" action so the user can repair a repo whose
    /// labels got deleted (or were never created — see the bare-emoji
    /// trigger-label regression) without restarting the app.
    /// The per-process memo is left alone — the client's POST-treat-422
    /// flow is idempotent, so this is safe to call repeatedly.
    @MainActor
    func reseedLabels(identityId: UUID, surfaceId: String) async throws -> Int {
        struct ReseedError: LocalizedError {
            let errorDescription: String?
            init(_ msg: String) {
                self.errorDescription = msg
            }
        }
        let keychain = KeychainStore.shared
        guard let identity = keychain.identities.first(where: { $0.id == identityId }) else {
            throw ReseedError("Identity not found")
        }
        guard let auth = keychain.authFor(identity: identity) else {
            throw ReseedError("Missing credential — re-verify this identity in Settings")
        }
        let cli = client(for: identity)
        let config = sourceConfig(identity: identity, surfaceId: surfaceId)
        try await cli.bootstrapLabels(config: config, auth: auth)
        Logger.orchestrator.info("Reseeded labels for \(identityId.uuidString)/\(surfaceId)")
        return LemonState.allCases.count
    }

    // MARK: - Session management

    @MainActor
    private func startSession(ref: IssueRef, workspace: Workspace, identity: Identity,
                              client: any IssueSourceClient, auth: SourceAuth,
                              retrigger: LemonMarker?) async
    {
        let session = Session(issue: ref)
        session.worktreePath = "/tmp/lemon-\(ref.pathSlug)"
        session.terminalWindowName = "Lemon · \(ref.identifier)"
        sessions.add(session)

        let runner = WorktreeRunner()
        runners[session.id] = runner

        runner.onLogLine = { [weak session] line in
            DispatchQueue.main.async { session?.appendLog(line) }
        }
        runner.onStatusChange = { [weak self, weak session] status in
            DispatchQueue.main.async {
                session?.status = status
                if status.isTerminal {
                    if let s = session { self?.sessions.finish(s) }
                    self?.runners.removeValue(forKey: session?.id ?? UUID())
                }
            }
        }
        runner.onPRUrl = { [weak session] url in
            DispatchQueue.main.async { session?.prUrl = url }
        }
        runner.onAiSummary = { [weak session] summary in
            DispatchQueue.main.async { session?.aiSummary = summary }
        }
        runner.onPendingAction = { [weak session] msg in
            DispatchQueue.main.async { session?.pendingAction = msg }
        }
        runner.onCleanupReady = { [weak session] info in
            DispatchQueue.main.async { session?.cleanupInfo = info }
        }

        // WorktreeRunner still consumes the pair shape internally; build the
        // matching pair from the workspace + identity. (R-next will switch
        // the runner signature too, but this keeps the cut minimal.)
        let pair = WorkspacePair(
            id: workspace.id,
            source: sourceConfig(identity: identity, surfaceId: workspace.routing.surfaceId),
            workspace: WorkspaceMapping(
                matchKey: workspace.routing.surfaceId,
                path: workspace.path,
                allReposInFolder: workspace.allReposInFolder,
                homeRepo: workspace.homeRepo,
            ),
        )

        Task.detached(priority: .background) {
            await runner.run(ref: ref, pair: pair, client: client, auth: auth, retrigger: retrigger)
        }
    }

    func stopSession(_ session: Session) {
        runners[session.id]?.stop()
        runners.removeValue(forKey: session.id)
        session.status = .failed
        sessions.finish(session)
    }

    func cancelPendingAction(for session: Session) {
        runners[session.id]?.cancelPendingAction()
        // Clear directly — covers mock sessions that have no backing runner.
        session.pendingAction = nil
    }

    /// User clicked "Cleanup worktree" in the Ready-for-review card.
    /// Reads the session's stashed `cleanupInfo`, fires the worktree +
    /// tmux + /tmp teardown, transitions the session to `.done`, and
    /// drops it from the active list. Idempotent — no-ops if there's
    /// no cleanup info (already cleaned up, or never reached
    /// reviewing).
    func cleanupSession(_ session: Session) {
        guard let info = session.cleanupInfo else {
            Logger.orchestrator.warning("cleanupSession called on \(session.issue.identifier) with no cleanupInfo")
            return
        }
        // Capture only Sendable values; the @Observable Session can't
        // cross actor boundaries directly. Look up by sessionId on the
        // way back.
        let sessionId = session.id
        Task.detached(priority: .background) { [weak self] in
            // Look up the existing runner (if the session completed
            // this process lifetime). Otherwise spin up a throwaway
            // WorktreeRunner — cleanup's instance helpers don't depend
            // on the runner having ever called `run()`.
            let runner: WorktreeRunner = await self?.runnerOrThrowaway(sessionId: sessionId) ?? WorktreeRunner()
            await runner.cleanup(info: info)
            await MainActor.run { [weak self] in
                self?.finishCleanedUpSession(sessionId: sessionId)
            }
        }
    }

    @MainActor
    private func runnerOrThrowaway(sessionId: UUID) -> WorktreeRunner {
        runners[sessionId] ?? WorktreeRunner()
    }

    @MainActor
    private func finishCleanedUpSession(sessionId: UUID) {
        guard let session = sessions.active.first(where: { $0.id == sessionId })
            ?? sessions.recent.first(where: { $0.id == sessionId })
        else {
            runners.removeValue(forKey: sessionId)
            return
        }
        session.cleanupInfo = nil
        session.status = .done
        sessions.finish(session)
        runners.removeValue(forKey: sessionId)
    }

    // MARK: - Mock data (--mock launch argument)

    #if DEBUG
        func seedMockSessions() {
            // Fixed anchor: pins all relative timestamps so screenshots are stable across runs
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

            let active1 = Session(issue: IssueRef(
                id: "mock-1", identifier: "DEMO-42",
                title: "Add dark mode to dashboard cards",
                description: "All card components need a dark variant matching the system appearance.",
                labelNames: ["🍋 In Progress"], scope: .linearTeam(id: "mock-team"),
            ), startedAt: now.addingTimeInterval(-180))
            active1.status = .executing
            active1.aiSummary = "Updating ColorScheme tokens in CardView and running snapshot tests"
            for line in [
                "[lemon] Starting session for DEMO-42",
                "[lemon] Worktree ready at /tmp/lemon-demo-42",
                "[lemon] Claude session launched in tmux: lemon-demo-42",
                "Reading CardView.swift...",
                "Checking existing color tokens in DesignSystem.swift...",
                "✓ Snapshot tests passed successfully",
                "[gemma] Session active — modifying color tokens across 4 files",
            ] {
                active1.appendLog(line)
            }

            let active2 = Session(issue: IssueRef(
                id: "mock-2", identifier: "acme/widgets#39",
                title: "Fix auth redirect loop on token expiry",
                description: "Users are stuck in a redirect loop when their JWT expires mid-session.",
                labelNames: ["🍋 In Progress"], scope: .githubRepo(owner: "acme", repo: "widgets", number: 39),
            ), startedAt: now.addingTimeInterval(-420))
            active2.worktreePath = "/tmp/lemon-\(active2.issue.pathSlug)"
            active2.terminalWindowName = "Lemon · \(active2.issue.identifier)"
            active2.status = .waiting
            active2.aiSummary = "Needs decision: refresh token silently or redirect to login?"
            active2.pendingAction = "Accepting MCP servers… (Cancel to abort)"
            for line in [
                "[lemon] Starting session for acme/widgets#39",
                "[lemon] Worktree ready at /tmp/lemon-acme-widgets-39",
                "Reviewing AuthMiddleware.swift...",
                "Found expired token handling at line 84",
                "[error] Multiple redirect paths detected — needs clarification",
                "[gemma] Session waiting for input — ambiguous auth strategy",
            ] {
                active2.appendLog(line)
            }

            let recent = Session(issue: IssueRef(
                id: "mock-3", identifier: "DEMO-31",
                title: "Migrate user table to UUID primary keys",
                description: nil,
                labelNames: ["🍋 Complete"], scope: .linearTeam(id: "mock-team"),
            ), startedAt: now.addingTimeInterval(-5400))
            recent.status = .done
            recent.prUrl = "https://github.com/example/repo/pull/201"
            recent.endedAt = now.addingTimeInterval(-3600)
            recent.aiSummary = "Migration complete — backfill ran in 4m, all FK constraints updated"

            sessions.add(active1)
            sessions.add(active2)
            sessions.finish(recent)

            // Seed pairs + per-pair statuses so Settings renders a mixed-source
            // state under --smoke-test without needing a real Linear/GitHub config.
            seedMockPairs()
        }

        func seedMockPairs() {
            let linearPair = WorkspacePair(
                source: SourceConfig(source: .linear, displayName: "Linear",
                                     linearTeamKeys: ["DEMO"], githubRepos: nil),
                workspace: WorkspaceMapping(
                    matchKey: "DEMO",
                    path: "/Users/you/Projects/demo-app",
                    allReposInFolder: true,
                    homeRepo: "memory",
                ),
            )
            let githubPair = WorkspacePair(
                source: SourceConfig(source: .github, displayName: "GitHub",
                                     linearTeamKeys: nil, githubRepos: ["acme/widgets"]),
                workspace: WorkspaceMapping(
                    matchKey: "acme/widgets",
                    path: "/Users/you/Projects/widgets",
                    allReposInFolder: false,
                    homeRepo: "",
                ),
            )
            KeychainStore.shared.pairs = [linearPair, githubPair]
            KeychainStore.shared.linearApiKey = "lin_mock_demo_key"
            KeychainStore.shared.linearUserId = "user-mock"
            KeychainStore.shared.githubToken = "ghp_mock_demo_token"
            KeychainStore.shared.githubUser = "frkline"

            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            workspaceStatuses[linearPair.id] = WorkspaceStatus(
                lastPolledAt: now.addingTimeInterval(-12),
                triggerCount: 0,
                completeCount: 1,
                error: nil,
            )
            workspaceStatuses[githubPair.id] = WorkspaceStatus(
                lastPolledAt: now.addingTimeInterval(-8),
                triggerCount: 1,
                completeCount: 0,
                error: nil,
            )

            // Also stamp workspace-keyed statuses so the new (identity-aware)
            // settings view renders the same mock live state.
            for ws in KeychainStore.shared.workspaces {
                workspaceStatuses[ws.id] = WorkspaceStatus(
                    lastPolledAt: now.addingTimeInterval(-10),
                    triggerCount: 0,
                    completeCount: 0,
                    error: nil,
                )
            }
        }
    #endif
}
