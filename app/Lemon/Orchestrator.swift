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

    // Per-source clients, lazily created on first use per process.
    private let linearClient = LinearClient()
    private let githubClient = GitHubClient()
    private var pollTask: Task<Void, Never>?
    private var runners: [UUID: WorktreeRunner] = [:]

    private func client(for pair: WorkspacePair) -> any IssueSourceClient {
        switch pair.source.source {
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

        let pairs = keychain.pairs
        guard !pairs.isEmpty else {
            lastPollError = "No workspace pairs configured."
            return
        }

        lastPollError = nil

        // Bootstrap labels once per process, per pair. Failures don't abort
        // polling — bootstrapLabels logs and retries on the next poll.
        await bootstrapLabels(pairs: pairs, keychain: keychain)

        // Iterate pairs sequentially: avoids GitHub rate-limit bursts on
        // first poll and keeps log lines easy to follow per source.
        for pair in pairs {
            guard let auth = keychain.authFor(pair: pair) else {
                Logger.orchestrator.info("Skip pair \(pair.workspace.matchKey): missing credentials")
                continue
            }
            let cli = client(for: pair)
            await pollPair(pair: pair, client: cli, auth: auth)
        }
    }

    @MainActor
    private func pollPair(pair: WorkspacePair, client: any IssueSourceClient, auth: SourceAuth) async {
        do {
            // 1. New 🍋-labeled issues → start a session.
            let newIssues = try await client.fetchTriggerQueue(config: pair.source, auth: auth)
            Logger.orchestrator.info("Poll[\(pair.source.source.rawValue)/\(pair.workspace.matchKey)]: \(newIssues.count) queued, \(self.sessions.active.count) active")

            for ref in newIssues {
                guard !sessions.isTracking(ref: ref) else { continue }
                guard sessions.active.count < maxConcurrent else {
                    Logger.orchestrator.info("At max concurrent sessions, skipping \(ref.identifier)")
                    break
                }
                Logger.orchestrator.info("Starting session for \(ref.identifier): \(ref.title)")
                await startSession(ref: ref, pair: pair, client: client, auth: auth, retrigger: nil)
            }

            // 2. 🍋 Complete issues → check for human replies to re-trigger.
            let completeIssues = try await client.fetchCompleteQueue(config: pair.source, auth: auth)
            Logger.orchestrator.info("Poll[\(pair.source.source.rawValue)]: \(completeIssues.count) complete issues to check for replies")
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
                await startSession(ref: ref, pair: pair, client: client, auth: auth, retrigger: marker)
            }
        } catch {
            Logger.orchestrator.error("Poll error for pair \(pair.workspace.matchKey): \(error)")
            lastPollError = error.localizedDescription
        }
    }

    private var maxConcurrent: Int { 2 }

    // MARK: - Label bootstrapping

    private var bootstrappedPairs: Set<UUID> = []

    private func bootstrapLabels(pairs: [WorkspacePair], keychain: KeychainStore) async {
        for pair in pairs {
            if bootstrappedPairs.contains(pair.id) { continue }
            guard let auth = keychain.authFor(pair: pair) else { continue }
            let cli = client(for: pair)
            do {
                try await cli.bootstrapLabels(config: pair.source, auth: auth)
                bootstrappedPairs.insert(pair.id)
                Logger.orchestrator.info("Bootstrapped labels for pair \(pair.workspace.matchKey)")
            } catch {
                Logger.orchestrator.error("Label bootstrap failed for \(pair.workspace.matchKey): \(error) — will retry on next poll")
            }
        }
    }

    // MARK: - Session management

    @MainActor
    private func startSession(ref: IssueRef, pair: WorkspacePair, client: any IssueSourceClient,
                              auth: SourceAuth, retrigger: LemonMarker?) async {
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
    }
    #endif
}
