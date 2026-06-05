import Foundation
import SwiftUI
import os

@Observable
@MainActor
final class Orchestrator {
    let sessions = SessionStore()
    var lastPollError: String?
    var lastPolledAt: Date?
    var isPolling = false
    var aiState: LocalLLM.AIState = .notConfigured

    private let linear = LinearClient()
    private var pollTask: Task<Void, Never>?
    private var runners: [UUID: WorktreeRunner] = [:]

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

        let apiKey = keychain.linearApiKey

        do {
            let userId = keychain.linearUserId

            // Ensure 🍋 labels exist in all teams on first poll.
            await bootstrapLabels(apiKey: apiKey)

            // 1. New 🍋-labeled issues assigned to this user → start a session.
            let newIssues = try await linear.fetchLemonQueue(apiKey: apiKey, userId: userId)
            lastPollError = nil
            Logger.orchestrator.info("Poll: \(newIssues.count) queued, \(self.sessions.active.count) active")

            for issue in newIssues {
                guard !sessions.isTracking(issueId: issue.id) else { continue }
                guard sessions.active.count < maxConcurrent else {
                    Logger.orchestrator.info("At max concurrent sessions, skipping \(issue.identifier)")
                    break
                }
                guard let repo = keychain.repoFor(issuePrefix: issue.identifierPrefix) else {
                    let msg = "No workspace configured for prefix \(issue.identifierPrefix)"
                    Logger.orchestrator.error("\(msg)")
                    lastPollError = msg
                    continue
                }
                Logger.orchestrator.info("Starting session for \(issue.identifier): \(issue.title)")
                await startSession(for: issue, repo: repo, retrigger: nil)
            }

            // 2. 🍋 Complete issues assigned to this user → check for human replies to re-trigger.
            let completeIssues = try await linear.fetchCompleteIssues(apiKey: apiKey, userId: userId)
            Logger.orchestrator.info("Poll: \(completeIssues.count) complete issues to check for replies")
            for issue in completeIssues {
                if sessions.isTracking(issueId: issue.id) {
                    Logger.orchestrator.info("Retrigger skip \(issue.identifier): already tracking")
                    continue
                }
                let maybeMarker: LemonMarker?
                do {
                    maybeMarker = try await linear.findLemonMarker(issueId: issue.id, apiKey: apiKey)
                } catch {
                    Logger.orchestrator.error("Retrigger skip \(issue.identifier): findLemonMarker error: \(error.localizedDescription)")
                    continue
                }
                guard let marker = maybeMarker else {
                    // Diagnostic: also dump comment count + first 80 chars of last body
                    let count = (try? await linear.fetchComments(issueId: issue.id, apiKey: apiKey).count) ?? -1
                    Logger.orchestrator.info("Retrigger skip \(issue.identifier): no Lemon marker found (\(count) comments visible)")
                    continue
                }
                let hasReply: Bool
                do {
                    hasReply = try await linear.hasNewComment(
                        issueId: issue.id,
                        afterCommentId: marker.commentId,
                        apiKey: apiKey
                    )
                } catch {
                    Logger.orchestrator.error("Retrigger \(issue.identifier) hasNewComment failed: \(error)")
                    continue
                }
                if !hasReply {
                    Logger.orchestrator.info("Retrigger skip \(issue.identifier): no new comment after marker \(marker.commentId)")
                    continue
                }
                guard let repo = keychain.repoFor(issuePrefix: issue.identifierPrefix) else {
                    Logger.orchestrator.error("Retrigger skip \(issue.identifier): no repo configured for prefix \(issue.identifierPrefix)")
                    continue
                }
                Logger.orchestrator.info("Re-triggering \(issue.identifier) from reply")
                await startSession(for: issue, repo: repo, retrigger: marker)
            }
        } catch {
            Logger.orchestrator.error("Poll error: \(error)")
            lastPollError = error.localizedDescription
        }
    }

    private var maxConcurrent: Int { 2 }

    // MARK: - Label bootstrapping

    private var labelsBootstrapped = false

    private func bootstrapLabels(apiKey: String) async {
        guard !labelsBootstrapped else { return }
        do {
            let teams = try await linear.fetchTeams(apiKey: apiKey)
            Logger.orchestrator.info("Bootstrapping Lemon labels for \(teams.count) team(s)")
            for team in teams {
                for label in [LinearClient.labelTrigger, LinearClient.labelInProgress,
                              LinearClient.labelWaiting, LinearClient.labelComplete] {
                    _ = try? await linear.ensureLabelId(name: label, teamId: team.id, apiKey: apiKey)
                }
            }
            // Mark complete only after the fetch + ensure loop ran. The previous
            // code set this guard before the network call, so a transient
            // fetchTeams failure on first launch would permanently skip the
            // eager bootstrap. WorktreeRunner.run still calls ensureLabelId
            // lazily, but the eager pass is what makes onboarding's "Labels
            // ready in N teams" indicator green; better to retry on next poll.
            labelsBootstrapped = true
            Logger.orchestrator.info("Label bootstrap complete")
        } catch {
            Logger.orchestrator.error("Label bootstrap failed: \(error) — will retry on next poll")
        }
    }

    // MARK: - Session management

    @MainActor
    private func startSession(for issue: LinearIssue, repo: WorkspaceRepo, retrigger: LemonMarker?) async {
        let session = Session(issue: issue)
        session.worktreePath = "/tmp/lemon-\(issue.identifier.lowercased())"
        session.terminalWindowName = "Lemon · \(issue.identifier)"
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

        Task.detached(priority: .background) {
            await runner.run(issue: issue, workspace: repo, retrigger: retrigger)
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

        let active1 = Session(issue: LinearIssue(
            id: "mock-1", identifier: "DEMO-42",
            title: "Add dark mode to dashboard cards",
            description: "All card components need a dark variant matching the system appearance.",
            labelNames: ["🍋 In Progress"], teamId: "mock-team"
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

        let active2 = Session(issue: LinearIssue(
            id: "mock-2", identifier: "DEMO-39",
            title: "Fix auth redirect loop on token expiry",
            description: "Users are stuck in a redirect loop when their JWT expires mid-session.",
            labelNames: ["🍋 In Progress"], teamId: "mock-team"
        ), startedAt: now.addingTimeInterval(-420))
        active2.status = .waiting
        active2.aiSummary = "Needs decision: refresh token silently or redirect to login?"
        active2.pendingAction = "Accepting MCP servers… (Cancel to abort)"
        for line in [
            "[lemon] Starting session for DEMO-39",
            "[lemon] Worktree ready at /tmp/lemon-demo-39",
            "Reviewing AuthMiddleware.swift...",
            "Found expired token handling at line 84",
            "[error] Multiple redirect paths detected — needs clarification",
            "[gemma] Session waiting for input — ambiguous auth strategy"
        ] { active2.appendLog(line) }

        let recent = Session(issue: LinearIssue(
            id: "mock-3", identifier: "DEMO-31",
            title: "Migrate user table to UUID primary keys",
            description: nil,
            labelNames: ["🍋 Complete"], teamId: "mock-team"
        ), startedAt: now.addingTimeInterval(-5400))
        recent.status = .done
        recent.prUrl = "https://github.com/example/repo/pull/201"
        recent.endedAt = now.addingTimeInterval(-3600)
        recent.aiSummary = "Migration complete — backfill ran in 4m, all FK constraints updated"

        sessions.add(active1)
        sessions.add(active2)
        sessions.finish(recent)
    }
    #endif
}
