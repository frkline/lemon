import Foundation
import SwiftUI
import os

// Per-workspace diagnostic snapshot — surfaced in Settings so the user can
// see at a glance whether each configured workspace is healthy. Updated
// after every pollWorkspace call (success or failure).
struct WorkspaceStatus: Equatable {
    var lastPolledAt: Date?
    var triggerCount: Int = 0
    var completeCount: Int = 0
    var error: String? = nil

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

    // Per-workspace diagnostics keyed on Workspace.id. Settings reads this
    // to render each workspace row's connection chip + subtitle line.
    var workspaceStatuses: [UUID: WorkspaceStatus] = [:]

    func workspaceStatus(for workspaceId: UUID) -> WorkspaceStatus? { workspaceStatuses[workspaceId] }

    // Back-compat readers for any view still keyed on the old pair shape.
    var pairStatuses: [UUID: WorkspaceStatus] { workspaceStatuses }
    func pairStatus(for pairId: UUID) -> WorkspaceStatus? { workspaceStatuses[pairId] }

    // Per-source clients, lazily created on first use per process.
    private let linearClient = LinearClient()
    private let githubClient = GitHubClient()
    private var pollTask: Task<Void, Never>?
    private var runners: [UUID: WorktreeRunner] = [:]

    private func client(for identity: Identity) -> any IssueSourceClient {
        switch identity.kind {
        case .linear: return linearClient
        case .github: return githubClient
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        Task { await LocalLLM.shared.start() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                // Poll faster when sessions are active so status updates feel responsive.
                let hasActive = self?.sessions.active.isEmpty == false
                try? await Task.sleep(for: .seconds(hasActive ? 15 : 45))
            }
        }
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
                    error: "Routing points at a deleted identity. Edit the workspace."
                )
                continue
            }
            guard let auth = keychain.authFor(identity: identity) else {
                Logger.orchestrator.info("Skip workspace \(workspace.path): \(identity.label) credentials missing")
                workspaceStatuses[workspace.id] = WorkspaceStatus(
                    lastPolledAt: Date(),
                    error: "\(identity.label): credentials missing"
                )
                continue
            }
            let cli = client(for: identity)
            await pollWorkspace(workspace: workspace, identity: identity, client: cli, auth: auth)
        }
    }

    @MainActor
    private func pollWorkspace(workspace: Workspace, identity: Identity,
                               client: any IssueSourceClient, auth: SourceAuth) async {
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
            return SourceConfig(
                source: .linear, displayName: identity.label,
                linearTeamKeys: [surfaceId], githubRepos: nil
            )
        case .github:
            return SourceConfig(
                source: .github, displayName: identity.label,
                linearTeamKeys: nil, githubRepos: [surfaceId]
            )
        }
    }

    private var maxConcurrent: Int { 2 }

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

    // MARK: - Session management

    @MainActor
    private func startSession(ref: IssueRef, workspace: Workspace, identity: Identity,
                              client: any IssueSourceClient, auth: SourceAuth,
                              retrigger: LemonMarker?) async {
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
                homeRepo: workspace.homeRepo
            )
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

    // MARK: - Mock data (--mock launch argument)

    #if DEBUG
    func seedMockSessions() {
        // Fixed anchor: pins all relative timestamps so screenshots are stable across runs
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let active1 = Session(issue: IssueRef(
            id: "mock-1", identifier: "DEMO-42",
            title: "Add dark mode to dashboard cards",
            description: "All card components need a dark variant matching the system appearance.",
            labelNames: ["🍋 In Progress"], scope: .linearTeam(id: "mock-team")
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
            "[gemma] Session active — modifying color tokens across 4 files"
        ] { active1.appendLog(line) }

        let active2 = Session(issue: IssueRef(
            id: "mock-2", identifier: "acme/widgets#39",
            title: "Fix auth redirect loop on token expiry",
            description: "Users are stuck in a redirect loop when their JWT expires mid-session.",
            labelNames: ["🍋 In Progress"], scope: .githubRepo(owner: "acme", repo: "widgets", number: 39)
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
            "[gemma] Session waiting for input — ambiguous auth strategy"
        ] { active2.appendLog(line) }

        let recent = Session(issue: IssueRef(
            id: "mock-3", identifier: "DEMO-31",
            title: "Migrate user table to UUID primary keys",
            description: nil,
            labelNames: ["🍋 Complete"], scope: .linearTeam(id: "mock-team")
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
                path: "/Users/frank/Projects/HarpyRocks",
                allReposInFolder: true,
                homeRepo: "memory"
            )
        )
        let githubPair = WorkspacePair(
            source: SourceConfig(source: .github, displayName: "GitHub",
                                 linearTeamKeys: nil, githubRepos: ["acme/widgets"]),
            workspace: WorkspaceMapping(
                matchKey: "acme/widgets",
                path: "/Users/frank/Projects/widgets",
                allReposInFolder: false,
                homeRepo: ""
            )
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
            error: nil
        )
        workspaceStatuses[githubPair.id] = WorkspaceStatus(
            lastPolledAt: now.addingTimeInterval(-8),
            triggerCount: 1,
            completeCount: 0,
            error: nil
        )

        // Also stamp workspace-keyed statuses so the new (identity-aware)
        // settings view renders the same mock live state.
        for ws in KeychainStore.shared.workspaces {
            workspaceStatuses[ws.id] = WorkspaceStatus(
                lastPolledAt: now.addingTimeInterval(-10),
                triggerCount: 0,
                completeCount: 0,
                error: nil
            )
        }
    }
    #endif
}
