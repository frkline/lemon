import Foundation
import os

/// Manages git worktrees and a claude --auto --remote-control session for one
/// issue (Linear or GitHub). Supports single-repo and multi-repo (all git
/// repos in a folder) modes.
final class WorktreeRunner: @unchecked Sendable {
    private var pollTask: Task<Void, Never>?
    private var stopped = false
    private var pendingActionTask: Task<Void, Never>?

    var onStatusChange: ((SessionStatus) -> Void)?
    var onLogLine: ((String) -> Void)?
    var onPRUrl: ((String) -> Void)?
    /// Fired when a gated session writes its plan to the plan sentinel (claude
    /// does this directly, per the kickoff prompt). Carries the plan markdown for
    /// the .planReview card.
    var onPlanReady: ((String) -> Void)?
    /// Fired when the build signals "ready for review" (result sentinel) instead
    /// of opening the PR directly. Carries the result summary for the gate card.
    var onResultReady: ((String) -> Void)?
    var onAiSummary: ((String) -> Void)?
    var onPendingAction: ((String?) -> Void)?
    /// Fired from handleComplete once the Lemon Report is posted and
    /// intermediate labels are cleared. The session is now in
    /// `.reviewing` and waiting for the user to hit "Cleanup worktree".
    /// Orchestrator stashes this info on the Session.
    var onCleanupReady: ((WorktreeCleanupInfo) -> Void)?
    /// Fired each poll tick during the build with the silence-detector timing —
    /// last pane activity + last Gemma classify — so the UI can render the idle
    /// countdown ("Gemma checks in 0:48" / "Listening — pane active") (#50).
    var onGemmaTiming: ((_ lastActivityAt: Date, _ lastGemmaAt: Date?) -> Void)?

    func cancelPendingAction() {
        pendingActionTask?.cancel()
        pendingActionTask = nil
        onPendingAction?(nil)
    }

    // MARK: - Entry point

    func run(ref: IssueRef, pair: WorkspacePair, client: any IssueSourceClient,
             auth: SourceAuth, retrigger: LemonMarker? = nil,
             lockdown: Bool = false, trustedAuthor: String? = nil) async
    {
        let workspace = pair.workspace
        let identifier = ref.identifier
        let slug = ref.pathSlug
        let branch = retrigger?.branch ?? "lemon/\(slug)"
        let sessionPath = "/tmp/lemon-\(slug)"
        let homeRepo = workspace.homeRepo.trimmingCharacters(in: .whitespacesAndNewlines)

        log("[lemon] starting session for \(identifier)")
        onStatusChange?(.planning)

        // Warm up the classifier now (#70): if SwiftLM was unloaded after idle,
        // the ~60-90 s reload overlaps worktree setup so the first pane classify
        // never stalls. Fire-and-forget; idempotent; a no-op when AI is disabled.
        Task { _ = await LocalLLM.shared.ensureReady() }

        // Discover repos to include in this session.
        let repos: [(name: String, repoPath: String)]
        if workspace.allReposInFolder {
            repos = discoverRepos(in: workspace.path)
            guard !repos.isEmpty else {
                log("[lemon] no git repos found in \(workspace.path)", level: .error)
                onStatusChange?(.failed)
                return
            }
            log("[lemon] found repos: \(repos.map(\.name).joined(separator: ", "))")
        } else {
            let name = URL(fileURLWithPath: workspace.path).lastPathComponent
            repos = [(name: name, repoPath: workspace.path)]
        }

        // Set up worktrees.
        do {
            try await setupWorktrees(
                repos: repos,
                sessionPath: sessionPath,
                isMultiRepo: workspace.allReposInFolder,
                branch: branch,
                isRetrigger: retrigger != nil,
            )
        } catch {
            let msg = error.localizedDescription
            log("[lemon] worktree setup failed: \(msg)", level: .error)
            // Clean up source so the issue is in a neutral state.
            // User can retry by re-adding the 🍋 label.
            try? await client.clearState(ref: ref, state: .trigger, auth: auth)
            try? await client.clearState(ref: ref, state: .inProgress, auth: auth)
            _ = try? await client.postComment(
                ref: ref,
                body: "🍋 Session failed to start: \(msg)\n\nRe-add the 🍋 label to retry.",
                auth: auth,
            )
            onStatusChange?(.failed)
            return
        }

        // Write issue context for Claude. Team instructions from {homeRepo}/LEMON.md come first.
        let lemonMdPath = homeRepo.isEmpty ? nil : "\(workspace.path)/\(homeRepo)/LEMON.md"
        let devPort = Self.devPort(for: identifier)

        // On re-trigger, pull every comment posted after the Lemon Report
        // marker — those are the human's revision requests. Without this
        // context, Claude reads only the original issue body and concludes
        // the task is already done.
        // Author-aware so the trust boundary (#13) can frame/exclude untrusted
        // content. In lockdown, comments not authored by the user are dropped
        // entirely; otherwise they're kept but flagged untrusted for delimiting.
        var revisionComments: [RevisionComment] = []
        if let marker = retrigger {
            do {
                let all = try await client.fetchComments(ref: ref, auth: auth)
                if let idx = all.firstIndex(where: { $0.id == marker.commentId }) {
                    for c in all[all.index(after: idx)...] {
                        let trusted = isTrusted(c.author, trustedAuthor: trustedAuthor)
                        if lockdown, !trusted {
                            log("[lemon] lockdown: dropping untrusted comment by \(c.author ?? "?")")
                            continue
                        }
                        revisionComments.append(RevisionComment(body: c.body, author: c.author, trusted: trusted))
                    }
                }
                if !revisionComments.isEmpty {
                    log("[lemon] re-trigger with \(revisionComments.count) revision comment(s)")
                }
            } catch {
                log("[lemon] failed to fetch revision comments: \(error)", level: .error)
            }
        }

        // Fresh sessions (not a retrigger, not autopilot) go through BOTH gates:
        // plan review before building, and result review before the PR opens (#53).
        // Retriggers revise an already-open PR; autopilot is the explicit opt-out.
        let autopilot = TrustPolicy.isAutopilot(labels: ref.labelNames)
        if autopilot { log("[lemon] autopilot (🍋 auto) — skipping the plan + result gates") }
        let gated = retrigger == nil && !autopilot

        writeContext(
            to: sessionPath,
            ref: ref,
            repos: workspace.allReposInFolder ? repos : [],
            lemonMdPath: lemonMdPath,
            devPort: devPort,
            revisionComments: revisionComments,
            trustedAuthor: trustedAuthor,
            lockdown: lockdown,
            resultGate: gated,
        )

        // Update source state labels.
        try? await client.clearState(ref: ref, state: .trigger, auth: auth)
        if retrigger != nil {
            try? await client.clearState(ref: ref, state: .complete, auth: auth)
        }
        try? await client.applyState(ref: ref, state: .inProgress, auth: auth)

        // Launch Claude inside a tmux session, starting in homeRepo if configured.
        let launchPath = homeRepo.isEmpty ? sessionPath : "\(sessionPath)/\(homeRepo)"
        let sentinelPath = "/tmp/lemon-exit-\(slug)"
        // Remove any leftover sentinel and log from a prior run.
        try? FileManager.default.removeItem(atPath: sentinelPath)
        try? FileManager.default.removeItem(atPath: logPath(slug: slug))

        // Pre-merge .mcp.json files so Claude skips the interactive MCP discovery prompt.
        let mcpConfigPath = prepareMcpConfig(sessionPath: sessionPath, repos: repos,
                                             isMultiRepo: workspace.allReposInFolder,
                                             slug: slug)

        // Plan mode mirrors the gating decided above (fresh, non-autopilot work).
        let planMode = gated
        try? FileManager.default.removeItem(atPath: planReadyPath(slug: slug))
        try? FileManager.default.removeItem(atPath: gateSentinelPath(slug: slug))
        try? FileManager.default.removeItem(atPath: resultReadyPath(slug: slug))
        pretrustWorktree(path: launchPath) // skip claude's folder-trust prompt

        let sessionLabel = WorktreeRunner.remoteControlName(
            identifier: identifier, title: ref.title,
        )
        if let failure = launchTmux(sessionPath: launchPath, slug: slug, sessionLabel: sessionLabel,
                                    sentinelPath: sentinelPath, mcpConfigPath: mcpConfigPath,
                                    planMode: planMode)
        {
            log("[lemon] tmux launch failed — session aborted", level: .error)
            try? await client.clearState(ref: ref, state: .trigger, auth: auth)
            try? await client.clearState(ref: ref, state: .inProgress, auth: auth)
            let body = switch failure {
            case .tmuxMissing:
                "🍋 Failed to launch tmux session. Ensure tmux is installed (`brew install tmux`) and re-add the 🍋 label to retry."
            case let .claudeMissing(bin):
                "🍋 Couldn't find the `\(bin)` binary on PATH. Install the Claude CLI (or fix your PATH) and re-add the 🍋 label to retry."
            case let .launchError(detail):
                "🍋 Failed to launch tmux session: \(detail). Re-add the 🍋 label to retry."
            }
            _ = try? await client.postComment(ref: ref, body: body, auth: auth)
            onStatusChange?(.failed)
            return
        }
        log("[lemon] tmux session started — join: \(Self.tmuxBase) attach -t \(tmuxSessionName(slug: slug))")

        // Plan gate: surface the plan, wait for human approval, then continue
        // into the build in the SAME session. Returns false if abandoned/failed.
        if planMode {
            let proceed = await planGatePhase(ref: ref, client: client, auth: auth,
                                              slug: slug, sentinelPath: sentinelPath)
            guard proceed else { return }
        }

        onStatusChange?(.executing)

        await pollUntilDone(
            ref: ref,
            pair: pair,
            client: client,
            auth: auth,
            sessionPath: sessionPath,
            repos: repos,
            isMultiRepo: workspace.allReposInFolder,
            branch: branch,
            retrigger: retrigger,
            workspacePath: workspace.path,
            sentinelPath: sentinelPath,
        )
    }

    /// Reattach to a still-running tmux session after an app relaunch/crash
    /// (issue #35). Unlike `run()`, this does NO worktree setup, NO context
    /// write, NO label apply, and NO `launchTmux` — the detached `tmux` session
    /// and its on-disk sentinels are already live, so re-launching would
    /// double-launch claude and clobber live state. It rebuilds the locals `run()`
    /// derives and resumes the lifecycle at the persisted status. The caller
    /// (Orchestrator.restoreSessions) has already confirmed the tmux session is
    /// alive (debounced) and wired the same callbacks as `startSession`.
    func reattach(persisted: PersistedSession, pair: WorkspacePair,
                  client: any IssueSourceClient, auth: SourceAuth) async
    {
        let workspace = pair.workspace
        let ref = persisted.issue
        let slug = persisted.slug
        let branch = persisted.branch
        let sessionPath = "/tmp/lemon-\(slug)"
        let sentinelPath = "/tmp/lemon-exit-\(slug)"

        // Rediscover repos exactly as run() does — the worktrees already exist.
        let repos: [(name: String, repoPath: String)]
        if workspace.allReposInFolder {
            repos = discoverRepos(in: workspace.path)
        } else {
            let name = URL(fileURLWithPath: workspace.path).lastPathComponent
            repos = [(name: name, repoPath: workspace.path)]
        }

        log("[lemon] reattaching to \(ref.identifier) at \(persisted.status.displayLabel)")

        func resumePoll() async {
            await pollUntilDone(
                ref: ref, pair: pair, client: client, auth: auth,
                sessionPath: sessionPath, repos: repos,
                isMultiRepo: workspace.allReposInFolder, branch: branch,
                retrigger: persisted.retrigger, workspacePath: workspace.path,
                sentinelPath: sentinelPath,
            )
        }

        switch persisted.status {
        case .planning:
            // Mirror run()'s gate decision: plan-mode sessions wait for + post a
            // plan (resuming:false — not yet posted at .planning); retrigger /
            // autopilot sessions skip the gate and poll directly.
            let autopilot = TrustPolicy.isAutopilot(labels: ref.labelNames)
            let planMode = persisted.retrigger == nil && !autopilot
            if planMode {
                guard await planGatePhase(ref: ref, client: client, auth: auth,
                                          slug: slug, sentinelPath: sentinelPath,
                                          resuming: false) else { return }
            }
            onStatusChange?(.executing)
            await resumePoll()

        case .planReview:
            // Plan already posted + 🍋 Waiting applied pre-crash — resume the park
            // loop without re-posting (resuming:true).
            guard await planGatePhase(ref: ref, client: client, auth: auth,
                                      slug: slug, sentinelPath: sentinelPath,
                                      resuming: true) else { return }
            onStatusChange?(.executing)
            await resumePoll()

        case .executing, .waiting, .resultReview:
            // pollUntilDone is fully resumable: it re-reads the result sentinel,
            // PR state, and labels from scratch each tick.
            onStatusChange?(persisted.status)
            await resumePoll()

        case .reviewing:
            // handleComplete already ran — or was interrupted mid-post. If the
            // Lemon Report marker is present the report was posted, so restore
            // .reviewing statically (cleanupInfo was rehydrated from the index).
            // If absent, the crash beat the post — finish the job.
            let marker = try? await client.findLemonMarker(ref: ref, auth: auth)
            if marker != nil {
                onStatusChange?(.reviewing)
                log("[lemon] reattached at review — report already posted")
            } else {
                log("[lemon] reattached at review but no report found — completing")
                await handleComplete(
                    ref: ref, pair: pair, client: client, auth: auth,
                    sessionPath: sessionPath, repos: repos,
                    isMultiRepo: workspace.allReposInFolder, branch: branch,
                    retrigger: persisted.retrigger, workspacePath: workspace.path,
                )
            }

        case .queued, .done, .failed:
            // .queued is re-adopted by restoreSessions (promoted by the poll
            // loop, never reattached here); terminal statuses are never
            // persisted. No-op defensively.
            break
        }
    }

    func stop() {
        stopped = true
        pollTask?.cancel()
    }

    // MARK: - Repo discovery

    private func discoverRepos(in folderPath: String) -> [(name: String, repoPath: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }
        return contents.compactMap { name -> (name: String, repoPath: String)? in
            let repoPath = "\(folderPath)/\(name)"
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: "\(repoPath)/.git", isDirectory: &isDir) else { return nil }
            return (name: name, repoPath: repoPath)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Worktree setup

    private func setupWorktrees(
        repos: [(name: String, repoPath: String)],
        sessionPath: String,
        isMultiRepo: Bool,
        branch: String,
        isRetrigger: Bool,
    ) async throws {
        if isMultiRepo {
            // Create the session root directory (not a worktree itself).
            try FileManager.default.createDirectory(atPath: sessionPath, withIntermediateDirectories: true)
            for repo in repos {
                let worktreePath = "\(sessionPath)/\(repo.name)"
                try await setupSingleWorktree(repoPath: repo.repoPath, worktreePath: worktreePath, branch: branch, isRetrigger: isRetrigger)
            }
        } else {
            // Single repo: worktree IS the session path.
            try await setupSingleWorktree(repoPath: repos[0].repoPath, worktreePath: sessionPath, branch: branch, isRetrigger: isRetrigger)
        }
    }

    private func setupSingleWorktree(
        repoPath: String,
        worktreePath: String,
        branch: String,
        isRetrigger: Bool,
    ) async throws {
        // Remove any leftover worktree and orphaned branch from a previous failed run.
        _ = try? await shell("git -C \(q(repoPath)) worktree remove \(q(worktreePath)) --force")
        if !isRetrigger {
            _ = try? await shell("git -C \(q(repoPath)) branch -D \(branch)")
        }
        try await shell("git -C \(q(repoPath)) fetch origin")

        if isRetrigger {
            try await shell("git -C \(q(repoPath)) worktree add \(q(worktreePath)) \(branch)")
            try await shell("git -C \(q(worktreePath)) pull origin \(branch) --rebase || true")
        } else {
            let base = await defaultBranch(repoPath: repoPath)
            try await shell("git -C \(q(repoPath)) worktree add -b \(branch) \(q(worktreePath)) origin/\(base)")
        }
    }

    private func defaultBranch(repoPath: String) async -> String {
        let result = try? await shell("git -C \(q(repoPath)) remote show origin | grep 'HEAD branch' | awk '{print $NF}'")
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "main" : trimmed
    }

    // MARK: - Worktree cleanup

    /// Multi-step force-remove for a single worktree. `git worktree remove
    /// --force` works most of the time but fails silently when (a) Claude
    /// left a `.git/index.lock`, (b) the worktree path is a symlink target
    /// mismatch (`/tmp` ↔ `/private/tmp` on macOS), or (c) git's own
    /// worktree record is out of sync. Without the fallback the directory
    /// stays on disk and the user later hits "contains modified or
    /// untracked files, use --force to delete it" trying to clean up
    /// themselves.
    ///
    /// Strategy:
    ///  1. `git worktree remove --force` (the happy path)
    ///  2. If that didn't actually delete the dir, blow it away with FileManager
    ///  3. `git worktree prune` so git's internal record matches reality
    private func forceRemoveWorktree(repoPath: String, worktreePath: String) async {
        do {
            try await shell("git -C \(q(repoPath)) worktree remove \(q(worktreePath)) --force")
        } catch {
            Logger.worktree.warning("git worktree remove --force failed for \(worktreePath): \(error.localizedDescription) — falling back to FileManager")
        }
        // Step 2: if the directory still exists (git refused for whatever
        // reason), nuke it manually. This is what the user would have to
        // do by hand otherwise.
        if FileManager.default.fileExists(atPath: worktreePath) {
            do {
                try FileManager.default.removeItem(atPath: worktreePath)
                Logger.worktree.info("FileManager removed leftover worktree dir at \(worktreePath)")
            } catch {
                Logger.worktree.error("FileManager removal failed at \(worktreePath): \(error.localizedDescription)")
            }
        }
        // Step 3: prune so `git worktree list` no longer shows the path
        // and a future `git checkout <branch>` in the main repo isn't
        // blocked by a stale record.
        _ = try? await shell("git -C \(q(repoPath)) worktree prune")
    }

    /// User-triggered (or reconstructed-session-triggered) cleanup
    /// entry point. Orchestrator calls this on the per-session runner;
    /// for reconstructed sessions whose runner was destroyed at a
    /// previous process exit, Orchestrator spins up a fresh throwaway
    /// WorktreeRunner just for this call.
    func cleanup(info: WorktreeCleanupInfo) async {
        let repos = info.repos.map { (name: $0.name, repoPath: $0.repoPath) }
        await cleanupWorktrees(repos: repos,
                               sessionPath: info.sessionPath,
                               isMultiRepo: info.isMultiRepo,
                               slug: info.slug)
    }

    func cleanupWorktrees(
        repos: [(name: String, repoPath: String)],
        sessionPath: String,
        isMultiRepo: Bool,
        slug: String,
    ) async {
        if isMultiRepo {
            for repo in repos {
                let worktreePath = "\(sessionPath)/\(repo.name)"
                await forceRemoveWorktree(repoPath: repo.repoPath, worktreePath: worktreePath)
            }
            do {
                try FileManager.default.removeItem(atPath: sessionPath)
            } catch {
                Logger.worktree.warning("Session dir removal failed at \(sessionPath): \(error)")
            }
        } else {
            await forceRemoveWorktree(repoPath: repos[0].repoPath, worktreePath: sessionPath)
        }
        // Kill tmux session and remove all per-session artefacts in /tmp so
        // repeated runs don't leak launcher scripts, sentinel files, merged
        // MCP configs, or pane logs.
        runSync("\(Self.tmuxBase) kill-session -t '\(tmuxSessionName(slug: slug))' 2>/dev/null || true")
        let leftovers = [
            logPath(slug: slug),
            "/tmp/lemon-launch-\(slug).sh",
            "/tmp/lemon-exit-\(slug)",
            "/tmp/lemon-mcp-\(slug).json",
            // Plan-gate sentinels — without these, a GC'd-then-recreated slug
            // could inherit a stale plan/decision/result and skip or mis-drive
            // its gate (issue #35).
            planReadyPath(slug: slug),
            gateSentinelPath(slug: slug),
            resultReadyPath(slug: slug),
            "/tmp/lemon-pr-\(slug)", // sandbox PR sentinel (#53/#54 completion path)
        ]
        for path in leftovers {
            try? FileManager.default.removeItem(atPath: path)
        }
        log("[lemon] worktree(s) cleaned up")
    }

    // MARK: - Startup GC (#55)

    /// A lemon-owned worktree registration from `git worktree list`.
    struct LemonWorktree { let path: String; let slug: String; let branch: String? }

    /// Git subrepo paths for a folder workspace (public wrapper over the private
    /// discovery used at setup). Single-repo workspaces pass their own path.
    func discoverRepoPaths(in folderPath: String) -> [String] {
        discoverRepos(in: folderPath).map(\.repoPath)
    }

    /// Parse `git worktree list --porcelain`, returning only Lemon-owned
    /// entries: worktrees whose path is under /tmp/lemon- OR whose branch is
    /// lemon/<slug>. Keying on the registration (not an on-disk /tmp dir) is the
    /// point — the stale entry that breaks a later `git worktree add` can persist
    /// after the directory itself is gone (#55).
    func lemonWorktrees(porcelain: String) -> [LemonWorktree] {
        var out: [LemonWorktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let p = path, let slug = lemonSlug(path: p, branch: branch) {
                out.append(LemonWorktree(path: p, slug: slug, branch: branch))
            }
            path = nil; branch = nil
        }
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)) }
            else if line.isEmpty { flush() }
        }
        flush()
        return out
    }

    private func lemonSlug(path: String, branch: String?) -> String? {
        let prefix = "/tmp/lemon-"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        if let b = branch, let r = b.range(of: "lemon/") { return String(b[r.upperBound...]) }
        return nil
    }

    /// Prune stale lemon-owned worktree registrations across `repoPaths` whose
    /// slug isn't in `keepSlugs` and whose tmux session is dead (#55). Removes
    /// the dir + git registration + the lemon/<slug> branch so a re-run's
    /// `git worktree add` for the same slug succeeds. Live-but-untracked
    /// worktrees are LEFT (a re-trigger can adopt them, consistent with #38).
    /// Returns the pruned slugs.
    func gcStaleWorktrees(repoPaths: [String], keepSlugs: Set<String>) async -> [String] {
        var pruned: [String] = []
        for repoPath in repoPaths {
            guard let porcelain = try? await shell("git -C \(q(repoPath)) worktree list --porcelain") else { continue }
            for wt in lemonWorktrees(porcelain: porcelain) {
                if keepSlugs.contains(wt.slug) { continue }
                if await !tmuxSessionDead(slug: wt.slug) { continue } // live → leave for reattach
                await forceRemoveWorktree(repoPath: repoPath, worktreePath: wt.path)
                if let b = wt.branch {
                    let name = b.replacingOccurrences(of: "refs/heads/", with: "")
                    _ = try? await shell("git -C \(q(repoPath)) branch -D \(q(name))")
                }
                pruned.append(wt.slug)
                Logger.worktree.info("[gc] pruned stale worktree \(wt.slug) in \(repoPath)")
            }
        }
        return pruned
    }

    /// Slugs of all live tmux sessions on the -L lemon socket (session name
    /// `lemon-<slug>` → `<slug>`). Empty when no tmux server is running.
    func lemonTmuxSlugs() async -> [String] {
        guard let out = try? await shell("\(Self.tmuxBase) ls -F '#{session_name}'") else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let name = String(line)
            guard name.hasPrefix("lemon-") else { return nil }
            return String(name.dropFirst("lemon-".count))
        }
    }

    func killTmuxSession(slug: String) {
        runSync("\(Self.tmuxBase) kill-session -t '\(tmuxSessionName(slug: slug))' 2>/dev/null || true")
    }

    // MARK: - Context file

    /// Pane must be silent this long before Gemma classifies; Gemma won't re-fire
    /// within `gemmaCooldown` of its last verdict. Shared with the UI so the idle
    /// countdown shows the real numbers (#50).
    static let gemmaSilenceThreshold: TimeInterval = 120
    static let gemmaCooldown: TimeInterval = 180

    /// Returns true when the silence detector should fire Gemma.
    /// Extracted for unit testability — call sites pass `now` explicitly.
    static func shouldInvokeGemma(
        lastActivityAt: Date,
        lastGemmaAt: Date?,
        now: Date = Date(),
        silenceThreshold: TimeInterval = WorktreeRunner.gemmaSilenceThreshold,
        cooldown: TimeInterval = WorktreeRunner.gemmaCooldown,
    ) -> Bool {
        let silence = now.timeIntervalSince(lastActivityAt)
        let gemmaCooldown = lastGemmaAt.map { now.timeIntervalSince($0) } ?? .infinity
        return silence > silenceThreshold && gemmaCooldown > cooldown
    }

    /// Derives a stable dev server port from the issue number (e.g. HRP-42 → 3042).
    /// Keeps concurrent sessions on different ports without coordination.
    static func devPort(for identifier: String) -> Int {
        let n = Int(identifier.split(separator: "-").last.flatMap(String.init) ?? "0") ?? 0
        return 3000 + (n % 1000) // stays in 3000–3999, wraps for very large issue numbers
    }

    /// A revision-request comment plus whether its author is the trusted user.
    struct RevisionComment {
        let body: String
        let author: String?
        let trusted: Bool
    }

    private func isTrusted(_ author: String?, trustedAuthor: String?) -> Bool {
        TrustPolicy.isTrusted(author: author, trustedAuthor: trustedAuthor)
    }

    private func untrustedBlock(_ body: String, author: String?, role: String, source: IssueSource) -> String {
        TrustPolicy.untrustedBlock(body, author: author, role: role, source: source)
    }

    private func writeContext(
        to sessionPath: String,
        ref: IssueRef,
        repos: [(name: String, repoPath: String)],
        lemonMdPath: String?,
        devPort: Int,
        revisionComments: [RevisionComment] = [],
        trustedAuthor: String? = nil,
        lockdown _: Bool = false,
        resultGate: Bool = false,
    ) {
        var content = ""

        // Team operating instructions come first — Claude reads this before the issue.
        if let path = lemonMdPath,
           let instructions = try? String(contentsOfFile: path, encoding: .utf8),
           !instructions.isEmpty
        {
            content += instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n\n---\n\n"
            log("[lemon] loaded team instructions from \(path)")
        }

        // Issue details. The body is trusted only if the user opened the issue;
        // otherwise it's attacker-influenceable (#13 A3) and gets the untrusted
        // delimiter + framing so Claude treats it as data, not instructions.
        let bodyTrusted = isTrusted(ref.authorLogin, trustedAuthor: trustedAuthor)
        content += "# \(ref.source.displayName) Issue: \(ref.identifier) — \(ref.title)\n\n"
        if let desc = ref.description, !desc.isEmpty {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if bodyTrusted {
                content += trimmed + "\n\n"
            } else {
                content += untrustedBlock(trimmed, author: ref.authorLogin, role: "issue reporter", source: ref.source)
            }
        }

        // Re-trigger context — comments posted after the last Lemon Report.
        // Without this section, Claude reads only the original issue body
        // on a re-run and concludes the task is already done. Each entry is
        // the revision the human is asking for; treat them as the authoritative
        // *current* request, layered on top of the original issue description.
        if !revisionComments.isEmpty {
            content += "## 🔄 Revision Request (this is a re-run — read carefully)\n\n"
            content += "Your previous PR for this issue has already been opened. "
            content += "A human has replied to the Lemon Report comment asking for changes. "
            content += "Treat the items below as the authoritative current request — "
            content += "they layer on top of (and supersede where applicable) the original "
            content += "issue description above.\n\n"
            for (i, comment) in revisionComments.enumerated() {
                let trimmed = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                content += "### Revision \(i + 1)\n\n"
                if comment.trusted {
                    content += trimmed + "\n\n"
                } else {
                    content += untrustedBlock(trimmed, author: comment.author, role: "commenter", source: ref.source)
                }
            }
        }

        // Available repos (multi-repo mode).
        if !repos.isEmpty {
            content += "### Available Repos\n"
            for repo in repos {
                content += "- `\(repo.name)/`\n"
            }
            content += "\n"
        }

        // Dev environment — only the project-agnostic bits. Anything stack-specific
        // (Next.js, databases, deploy targets) belongs in the team's LEMON.md.
        content += "### Session Environment\n"
        content += "- **Reserved dev-server port:** `\(devPort)` — use this if you launch a dev server so concurrent Lemon sessions don't collide.\n"
        content += "- **Worktree:** you're in a fresh git worktree on branch `\(ref.identifier.hasPrefix("lemon/") ? ref.identifier : "lemon/\(ref.pathSlug)")`. Don't switch branches.\n\n"

        // Self-isolation guard (#40). This worktree may be a checkout of Lemon
        // itself, which ships dev/test scripts that tear down Lemon + tmux. Run
        // from inside this Lemon-managed session, they kill the session you're in.
        content += "### ⚠️ You are inside a Lemon-managed tmux session\n"
        content += "This worktree runs inside a detached tmux session that Lemon owns and monitors. "
        content += "Do NOT run Lemon teardown — it kills the session you're running in:\n"
        content += "- No `make sandbox*` / `scripts/sandbox*.sh`\n"
        content += "- No `tmux kill-server` / `tmux kill-session` / `pkill -f Lemon`\n"
        content += "To validate, use plain `xcodebuild`, `make test`, or `make build-ui` instead.\n\n"

        // Source-specific completion instructions. The label set is identical
        // (🍋 / 🍋 In Progress / 🍋 Waiting / 🍋 Complete); the verb differs.
        let completeInstruction = switch ref.source {
        case .linear: "Apply the Linear label **🍋 Complete** to issue \(ref.identifier) via `gh`, the Linear MCP, or any Linear client."
        case .github: "Apply the GitHub label **🍋 Complete** to issue \(ref.identifier) via `gh issue edit \(ref.identifier.components(separatedBy: "#").last ?? "") --add-label '🍋 Complete'` (run inside the worktree where `gh` knows the repo)."
        }

        // Completion checklist. Gated (fresh) sessions go through a result-review
        // gate: claude commits + pushes + writes the result sentinel, then raises a
        // native AskUserQuestion picker for the go/no-go (#57). On approve claude
        // writes the gate sentinel itself before opening the PR, so the release
        // signal works for phone approval too (which bypasses resolveGate — #64).
        // Retrigger / autopilot sessions open the PR directly (legacy path).
        let resultPath = resultReadyPath(slug: ref.pathSlug)
        let gatePath = gateSentinelPath(slug: ref.pathSlug)
        let completionChecklist = resultGate ? """
        ## Completion checklist (result review required)

        This issue uses a **result-review gate**: a human reviews your build before the PR is opened. Do NOT open a PR or apply any 🍋 label until you are told the result is approved.

        When your implementation is finished and verified — it builds, lints, and tests pass — and you have committed your work and pushed the branch:
        1. Write a concise summary of what you changed and how you verified it to BOTH:
           - `.lemon-summary.md` in this worktree, and
           - the result-review sentinel `\(resultPath)` — creating that file signals Lemon your build is ready for review.
        2. Then **present the decision as a selectable choice** using the **AskUserQuestion tool** (do NOT just stop and idle, and do NOT open the PR yet). Ask one question — e.g. "Open the PR for \(ref.identifier)?" — with these two options, in this exact order:
           1. **Approve — open the PR now**
           2. **Request changes**
           This renders as a tappable choice on the reviewer's phone (remote-control) and in Lemon's popover. The reviewer may tap an option, or use the free-text / "Other" field to type specific feedback. Wait for the selection.
        3. Act on the selection:
           - **Approve** → FIRST write the file `\(gatePath)` containing exactly the text `approve` (no newline needed, no file extension — this is the release signal Lemon watches; native phone approval reaches you directly and never runs Lemon's own writer, so you must write it). THEN open the PR (`gh pr create …`), then \(completeInstruction)
           - **Request changes** (or any typed feedback) → do NOT write `\(gatePath)`. Address the feedback, re-commit and push, write `\(resultPath)` again, and **ask the same AskUserQuestion again** for another review.
        4. Kill any dev servers, background tasks, or external resources you started.

        If you need human input mid-build, apply the label **🍋 Waiting** and pause.
        If the issue's team LEMON.md above gave you extra steps, do those too.
        """ : """
        ## Completion checklist

        When the PR is open and ready for review:
        1. \(completeInstruction)
        2. Write a brief summary of what you did to `.lemon-summary.md` in this worktree (referenced by the Lemon Report comment).
        3. Kill any dev servers, background tasks, or external resources you started.

        If you need human input at any point, apply the label **🍋 Waiting** and pause.
        If the issue's team LEMON.md above gave you extra steps, do those too.
        """

        content += """
        ---
        \(completionChecklist)

        ---
        ## Use `/loop` for iterative work

        Lemon itself is a hand-coded `/loop` — Orchestrator polls, Gemma
        watches the pane, the session keeps going until 🍋 Complete fires.
        For your work inside this session, prefer `/loop` whenever the
        task benefits from iteration rather than one pass:

        - **Polish** a UI / a doc / a code path (try, look, refine)
        - **Reviews** of a diff, a PR, a module — one finding per tick
        - **Refactors** where you can't enumerate every site upfront
        - **Bug-hunting sweeps** — fix one, run tests, find the next
        - **Test backfill** — write one, watch it pass, find the next gap
        - **Exploration** where the next move depends on the last result

        Each tick: make one concrete change, validate it, commit if it
        landed, decide what's next, repeat. Stop when the completion
        checklist above is satisfied. The pattern works because each
        loop iteration is small, scoped, and verifiable — same reason
        Lemon's outer loop works.
        """
        try? content.write(toFile: "\(sessionPath)/LEMON_CONTEXT.md", atomically: true, encoding: .utf8)
    }

    // MARK: - Session naming helpers

    //
    // Paths/tmux names are keyed off the IssueRef.pathSlug, not the human-facing
    // identifier — slashes and `#` in GitHub identifiers ("acme/widgets#7")
    // break shell quoting + filesystem paths. Slug is already
    // lowercased + slash-flattened ("acme-widgets-7").

    // Lemon runs its tmux on a DEDICATED socket so sessions never attach to a
    // manual/sandbox-era default-socket server and inherit its global env (the
    // `LEMON_CLAUDE_BIN` → deleted-fake-claude → exit-127 leak, #40). Every
    // Lemon-owned tmux invocation — here, in LemonMCPTools, Orchestrator, and
    // the user-facing Join command in SessionDetailView — must use `tmuxBase`.
    static let tmuxSocket = "lemon"
    static let tmuxBase = "tmux -L \(tmuxSocket)"

    func tmuxSessionName(slug: String) -> String {
        "lemon-\(slug)"
    }

    /// One `tmux has-session` probe. True if the detached session is alive.
    func tmuxSessionAlive(slug: String) -> Bool {
        runSync("\(Self.tmuxBase) has-session -t '\(tmuxSessionName(slug: slug))' 2>/dev/null")
    }

    /// Debounced death check. A *single* `tmux has-session` miss is not proof a
    /// session ended — it can transiently fail for a still-alive claude (observed
    /// live: a session was marked Failed mid-plan, then produced its plan three
    /// minutes later). Re-probe up to `confirmations` times with a short gap and
    /// report dead only if EVERY probe misses. A live session answers on the first
    /// probe, so the happy path stays a single fast call. Used everywhere a lone
    /// miss could move a live session to a terminal/cleanup state (planGatePhase,
    /// pollUntilDone, and reattach reconciliation #35).
    func tmuxSessionDead(slug: String, confirmations: Int = 3, delayMs: Int = 700) async -> Bool {
        for attempt in 0 ..< max(1, confirmations) {
            if tmuxSessionAlive(slug: slug) { return false }
            if attempt < confirmations - 1 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }
        return true
    }

    func logPath(slug: String) -> String {
        "/tmp/lemon-log-\(slug).txt"
    }

    // MARK: - Plan-gate paths (the contract between the claude side and Lemon)

    /// Written by claude (real or fake-claude in the sandbox) when a plan is
    /// ready — the kickoff prompt instructs writing the plan here in auto mode
    /// (#76). Contains the plan markdown; its presence is the signal that the
    /// session has reached the plan gate.
    func planReadyPath(slug: String) -> String {
        "/tmp/lemon-plan-\(slug).md"
    }

    /// The result-gate release signal ("approve" or "changes"). Both gate
    /// park-loops watch for it. Written by Orchestrator.resolveGate (desk/MCP
    /// approval) AND, at the result gate, by claude itself on approve — native
    /// phone approval over remote-control reaches claude directly and never runs
    /// resolveGate, so claude must write it or pollUntilDone never releases (#64).
    /// The double-write is idempotent.
    func gateSentinelPath(slug: String) -> String {
        "/tmp/lemon-gate-\(slug)"
    }

    /// Optional result gate: if the build writes this (instead of opening the PR
    /// directly), Lemon parks at .resultReview until the human approves. Absent
    /// → the existing 🍋 Complete → handleComplete path runs unchanged.
    func resultReadyPath(slug: String) -> String {
        "/tmp/lemon-result-\(slug).md"
    }

    /// Clear a 🍋* state label and CONFIRM it's actually gone, retrying a few
    /// times. The plain one-shot `try? clearState` swallows failures, and a stale
    /// 🍋 Waiting left behind after a gate approval desyncs the whole build (#51):
    /// `Orchestrator.reconcileLabels` then reads [In Progress + Waiting] and clears
    /// In Progress (keeping Waiting) every poll, and `pollUntilDone` re-derives the
    /// status as Waiting. Gate transitions use this so the label set is clean before
    /// the build proceeds.
    func clearStateConfirmed(ref: IssueRef, state: LemonState,
                             client: any IssueSourceClient, auth: SourceAuth,
                             attempts: Int = 4) async
    {
        for attempt in 0 ..< max(1, attempts) {
            try? await client.clearState(ref: ref, state: state, auth: auth)
            guard let labels = try? await client.fetchIssueLabels(ref: ref, auth: auth) else { return }
            if !labels.contains(state.labelName) { return }
            if attempt < attempts - 1 { try? await Task.sleep(for: .seconds(1)) }
        }
        log("[lemon] clearStateConfirmed: \(state.labelName) still set after retries on \(ref.identifier)", level: .error)
    }

    /// Pre-trust the worktree in `~/.claude.json` so real `claude` skips the
    /// "Is this a project you trust?" prompt on launch — otherwise the session
    /// stalls at that prompt until the 2-min silence timer lets Gemma answer it
    /// (a real snag found running real claude against a fresh worktree). Lemon
    /// created the worktree, so trusting it is legitimate. Written BEFORE launch
    /// so there's no concurrent write with the running session. No-op if the
    /// config is absent/unreadable (e.g. fake-claude sandbox runs).
    private func pretrustWorktree(path: String) {
        let configPath = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[path] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        entry["hasCompletedProjectOnboarding"] = true
        projects[path] = entry
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? out.write(to: URL(fileURLWithPath: configPath))
        log("[lemon] pre-trusted worktree for claude: \(path)")
    }

    // MARK: - Plan gate (the human approval before any code is written)

    /// Wait for the plan, surface it for approval, park until the human resolves
    /// the gate, then continue (approve → build) or abort. Returns true to
    /// proceed into pollUntilDone. Symmetric with the result gate (#76): the
    /// session runs in auto the whole time, claude writes its plan to the plan
    /// sentinel and raises a native AskUserQuestion picker; resolveGate (desk /
    /// MCP) send-keys "1"/"2" into that picker AND writes the gate sentinel,
    /// while phone approval over remote-control reaches claude directly and
    /// claude writes the gate sentinel itself. Either way this loop only watches
    /// the two sentinels — no pane-log detection, no mode transition.
    /// `resuming` is set when reattaching to a session already parked at the plan
    /// gate (issue #35): the plan was posted and the 🍋 Waiting label applied by
    /// the pre-crash process, so we restore the UI and re-enter the park loop
    /// WITHOUT re-posting the plan comment or re-applying labels.
    private func planGatePhase(ref: IssueRef, client: any IssueSourceClient,
                               auth: SourceAuth, slug: String, sentinelPath: String,
                               resuming: Bool = false) async -> Bool
    {
        let planPath = planReadyPath(slug: slug)
        let gatePath = gateSentinelPath(slug: slug)
        // When resuming a reattached gate, the plan (and possibly an unconsumed
        // gate decision) is already on disk — keep it. Only a fresh gate clears.
        if !resuming {
            try? FileManager.default.removeItem(atPath: planPath)
            try? FileManager.default.removeItem(atPath: gatePath)
        }

        /// The exit sentinel is authoritative — the launcher only writes it after
        /// claude truly exits. A tmux miss is debounced (a lone miss can be a false
        /// positive on a still-alive session).
        func sessionEnded() async -> Bool {
            if FileManager.default.fileExists(atPath: sentinelPath) { return true }
            return await tmuxSessionDead(slug: slug)
        }

        // The plan gate runs as rounds: wait for a plan, surface it, park on the
        // gate sentinel. On "approve" we build; on "changes" claude rewrites the
        // plan sentinel and re-raises AskUserQuestion, so we loop for the next
        // round. `surfaced` mirrors the result gate's `resultGateActive` — true
        // once the current round's plan has been posted + parked.
        var resumingRound = resuming
        var surfaced = resuming
        while !stopped {
            // 1. Wait for the plan to be ready (or early exit / timeout). On a
            // re-plan round (and on the very first round) the plan sentinel is
            // cleared, so this waits for the fresh plan; on resume it is already
            // on disk and we fall straight through.
            let planDeadline = Date().addingTimeInterval(2 * 3600)
            var plan: String?
            while !stopped, Date() < planDeadline {
                if let p = try? String(contentsOfFile: planPath, encoding: .utf8),
                   !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    plan = p
                    break
                }
                try? await Task.sleep(for: .seconds(3))
                if stopped { return false }
                // Triage reject: Claude judged the issue malformed/blocked, posted
                // a clarifying comment, and set 🍋 Waiting instead of planning.
                // Treat as awaiting-human, not a plan gate or a failure. (Only
                // before the plan is first surfaced — once we apply 🍋 Waiting for
                // the gate, that label is ours, not a triage signal.)
                if !surfaced,
                   let labels = try? await client.fetchIssueLabels(ref: ref, auth: auth),
                   labels.contains(LemonState.waiting.labelName)
                {
                    log("[lemon] triage: issue needs clarification (🍋 Waiting) — pausing for human")
                    onStatusChange?(.waiting)
                    return false
                }
                if await sessionEnded() {
                    log("[lemon] session ended during planning", level: .error)
                    onStatusChange?(.failed)
                    return false
                }
            }
            guard let plan else {
                log("[lemon] timed out waiting for a plan", level: .error)
                onStatusChange?(.failed)
                return false
            }

            // Surface the plan for approval: card + posted comment + 🍋 Waiting.
            // On resume the comment + labels are already in place — just restore
            // the card and status, then fall through to the park loop (no
            // double-post). Re-plan rounds post the revised plan afresh.
            onPlanReady?(plan)
            onStatusChange?(.planReview)
            if resumingRound {
                log("[lemon] reattached at plan gate for \(ref.identifier) — awaiting approval")
            } else {
                log("[lemon] plan ready for \(ref.identifier) — awaiting approval")
                await clearStateConfirmed(ref: ref, state: .inProgress, client: client, auth: auth)
                try? await client.applyState(ref: ref, state: .waiting, auth: auth)
                _ = try? await client.postComment(
                    ref: ref,
                    body: "## 🍋 Lemon Plan — \(ref.identifier)\n\n\(plan)\n\n---\nApprove to build, or request changes to revise.",
                    auth: auth,
                )
            }
            resumingRound = false
            surfaced = true

            // 2. Park until the gate is resolved.
            let gateDeadline = Date().addingTimeInterval(24 * 3600)
            var resolved = false
            while !stopped, Date() < gateDeadline {
                try? await Task.sleep(for: .seconds(2))
                if stopped { return false }
                if let raw = try? String(contentsOfFile: gatePath, encoding: .utf8) {
                    let decision = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? FileManager.default.removeItem(atPath: gatePath)
                    try? FileManager.default.removeItem(atPath: planPath)
                    if decision == "approve" {
                        log("[lemon] plan approved for \(ref.identifier) — building")
                        await clearStateConfirmed(ref: ref, state: .waiting, client: client, auth: auth)
                        try? await client.applyState(ref: ref, state: .inProgress, auth: auth)
                        return true
                    }
                    // Changes requested: claude revises and overwrites the plan
                    // sentinel, then re-raises AskUserQuestion. Reset the label to
                    // In Progress so the next round surfaces cleanly, and loop.
                    log("[lemon] changes requested for \(ref.identifier) — re-planning")
                    await clearStateConfirmed(ref: ref, state: .waiting, client: client, auth: auth)
                    try? await client.applyState(ref: ref, state: .inProgress, auth: auth)
                    onStatusChange?(.planning)
                    resolved = true
                    break
                }
                if await sessionEnded() {
                    log("[lemon] session ended while awaiting plan approval", level: .error)
                    onStatusChange?(.failed)
                    return false
                }
            }
            if !resolved {
                // Gate deadline elapsed without a decision.
                onStatusChange?(.failed)
                return false
            }
        }
        return false
    }

    // MARK: - MCP config preparation

    /// Merges .mcp.json files from all worktree repos into a single config file.
    /// Returns the path to the merged file, or nil if no MCP servers were found.
    /// Passing this via --mcp-config bypasses Claude's interactive MCP discovery prompt.
    private func prepareMcpConfig(sessionPath: String, repos: [(name: String, repoPath: String)],
                                  isMultiRepo: Bool, slug: String) -> String?
    {
        var mcpServers: [String: Any] = [:]
        var sourceOf: [String: String] = [:] // server name → repo it came from (for conflict logging)
        let searchPaths: [(label: String, path: String)] = isMultiRepo
            ? repos.map { (label: $0.name, path: "\(sessionPath)/\($0.name)") }
            : [(label: "session", path: sessionPath)]
        for entry in searchPaths {
            let mcpPath = "\(entry.path)/.mcp.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: mcpPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (name, config) in servers {
                if let prior = sourceOf[name], prior != entry.label {
                    Logger.worktree.warning("MCP server '\(name)' defined in both '\(prior)' and '\(entry.label)' — using '\(entry.label)'. Rename one if both should be active.")
                }
                mcpServers[name] = config
                sourceOf[name] = entry.label
            }
        }
        guard !mcpServers.isEmpty else { return nil }
        let configPath = "/tmp/lemon-mcp-\(slug).json"
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": mcpServers],
                                                     options: .prettyPrinted) else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return configPath
        } catch {
            Logger.worktree.error("MCP config write failed at \(configPath): \(error.localizedDescription)")
            return nil
        }
    }

    /// A human-readable name for the remote-control session — shown in the Claude
    /// mobile app / claude.ai/code list (and `/resume`) instead of a random
    /// "host-adjective-noun". Shape: "<issue> <short title> (<host>)". Single-
    /// quoted in the launcher, so apostrophes/newlines are stripped.
    static func remoteControlName(identifier: String, title: String) -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = trimmed.count > 40
            ? String(trimmed.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        let raw = shortTitle.isEmpty ? "\(identifier) (\(host))"
            : "\(identifier) \(shortTitle) (\(host))"
        return raw
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - tmux launch

    /// Creates a named tmux session running Claude and pipes output to a log file.
    /// Headless — no terminal window is auto-opened (use Join to attach on demand).
    /// The launcher script writes sentinelPath when claude exits so pollUntilDone
    /// can detect early exits without waiting for the 8h deadline.
    /// Why a launch couldn't start. `nil` from `launchTmux` means success; a
    /// non-nil value carries enough for the caller to post a specific issue
    /// comment instead of a generic failure (so a missing `claude` binary or a
    /// dead tmux server reads as a clear, actionable message — not a silent
    /// exit-127 pane death, #40).
    enum LaunchFailure {
        case tmuxMissing
        case claudeMissing(String)
        case launchError(String)
    }

    private func launchTmux(sessionPath: String, slug: String, sessionLabel: String,
                            sentinelPath: String, mcpConfigPath: String? = nil,
                            planMode: Bool = false) -> LaunchFailure?
    {
        // Verify tmux is installed.
        guard runSync("which tmux > /dev/null 2>&1") else {
            log("[lemon] tmux not found — install with: brew install tmux", level: .error)
            return .tmuxMissing
        }

        let sessionName = tmuxSessionName(slug: slug)
        let launcherPath = "/tmp/lemon-launch-\(slug).sh"
        let mcpFlag = mcpConfigPath.map { "--mcp-config '\($0)'" } ?? ""

        // Trailing positional kickoff prompt — `claude [options] [--] [prompt]`.
        // Without this Claude opens an empty REPL and just sits there; the
        // user is supposed to be afk, so Gemma sees an idle pane forever and
        // (correctly) returns state=running/action=null on every classify.
        // Pointing Claude at LEMON_CONTEXT.md makes the session self-starting.
        //
        // `--remote-control [name]` takes an *optional* positional argument. We
        // pass an explicit name (issue + short title + host) so the session shows
        // up meaningfully in remote control / the phone app instead of a random
        // "host-adjective-noun". The `--` separator still matters: it splits that
        // name from the trailing kickoff prompt. Without it the prompt gets
        // gobbled as the name, leaving Claude at an empty REPL with the prompt
        // mis-bound — live-test caught this on HRP-37 (Gemma saw the silence as
        // state=stuck). Both are single-quoted in bash, so neither the name nor
        // the prompt body may carry apostrophes.
        // Plan-gate flow (symmetric with the result gate, #76): launch in AUTO
        // — never plan mode. Claude triages, writes its plan to the plan
        // sentinel, posts it, and raises a native AskUserQuestion picker for the
        // go/no-go. Lemon's resolveGate send-keys "1"/"2" into that picker (or
        // Claude writes the gate sentinel itself on phone approval). There is no
        // mode to transition out of, so no post-approval edit prompts and
        // subagents during planning run under auto's classifier. Retriggers
        // (revisions) skip the gate. The prompt is single-quoted in bash, so it
        // must not contain apostrophes.
        let permissionMode = "auto"
        let planPath = planReadyPath(slug: slug)
        let gatePath = gateSentinelPath(slug: slug)
        let kickoffPrompt = planMode
            ? "Read LEMON_CONTEXT.md in this directory. FIRST triage the issue: is it clear, unambiguous, not already done, and unblocked? If it is malformed, a duplicate, or blocked, do NOT plan — post a short comment on the issue saying what you need, set the '🍋 Waiting' label, and stop. Otherwise investigate and write a concise implementation plan to the file \(planPath), post it to the issue, and present the go/no-go using the AskUserQuestion tool with exactly two options in this order: 1. Approve — build  2. Request changes. Do NOT edit any files until approved. On approve, FIRST write the file \(gatePath) containing exactly the text approve, THEN implement the plan, follow the completion checklist, and use /loop for iterative work. If changes are requested, revise the plan, overwrite \(planPath) with the new plan, and ask the same AskUserQuestion again."
            : "Read LEMON_CONTEXT.md in this directory and complete the task described there. Follow the completion checklist. Use /loop for iterative work."

        // Resolve the claude binary. SANDBOX runs honour `LEMON_CLAUDE_BIN`
        // (that's how fake-claude.sh is selected). REAL runs deliberately ignore
        // any inherited `LEMON_CLAUDE_BIN`: a leftover sandbox-era tmux server can
        // carry it (pointing at a now-deleted fake-claude) in its GLOBAL env, and a
        // pane that inherits it dies with a silent exit 127 (#40). Real runs bake
        // the literal `claude` and the launcher unsets the leak vars (below), so an
        // attached pre-existing server's globals can't poison the launch. The
        // dedicated `-L lemon` socket reinforces this — Lemon never shares a server
        // with a manual/sandbox session.
        let isSandbox = KeychainStore.isSandbox
        let claudeBin = isSandbox
            ? (ProcessInfo.processInfo.environment["LEMON_CLAUDE_BIN"] ?? "claude")
            : "claude"

        // Preflight: confirm the resolved binary actually resolves under the SAME
        // login-shell PATH the launcher gets (runSync uses `zsh -l -c`, sourcing the
        // same profiles). Fail loudly here — a missing binary becomes a clear issue
        // comment instead of a tmux pane that boots and instantly exits 127.
        guard runSync("command -v '\(claudeBin)' >/dev/null 2>&1") else {
            log("[lemon] claude binary '\(claudeBin)' not found on PATH", level: .error)
            return .claudeMissing(claudeBin)
        }

        // Source common shell profiles so PATH includes Homebrew, npm-global,
        // pyenv shims, etc. Same root cause as the runSync(zsh -l -c) fix:
        // `claude` is typically installed via brew or npm -g, which puts it
        // somewhere non-default-bash PATH won't find. Without this the launch
        // dies immediately with "claude: command not found" the moment tmux
        // boots the launcher.
        // Real runs `unset` the LEMON_* leak vars at the very top and invoke the
        // baked binary directly (no `${LEMON_CLAUDE_BIN:-…}` fallback to inherit).
        // Sandbox keeps the fallback so the fake-claude selection still works.
        let prelude = isSandbox ? "" : "unset LEMON_CLAUDE_BIN LEMON_SANDBOX LEMON_ENABLE_MCP\n"
        let binInvocation = isSandbox ? "\"${LEMON_CLAUDE_BIN:-\(claudeBin)}\"" : "\"\(claudeBin)\""
        let launcher = """
        #!/bin/bash
        \(prelude)[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
        [ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
        [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
        cd '\(sessionPath)' && \(binInvocation) \(mcpFlag) --permission-mode \(permissionMode) --remote-control '\(sessionLabel)' -- '\(kickoffPrompt)'
        echo $? > '\(sentinelPath)'
        """
        do {
            try launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
        } catch {
            Logger.worktree.error("Failed to write launcher: \(error)")
            return .launchError("couldn't write launcher script")
        }

        // Kill any leftover session from a prior run.
        runSync("\(Self.tmuxBase) kill-session -t '\(sessionName)' 2>/dev/null || true")

        // Create detached tmux session.
        guard runSync("\(Self.tmuxBase) new-session -d -s '\(sessionName)' -x 220 -y 50 '\(launcherPath)'") else {
            log("[lemon] Failed to create tmux session '\(sessionName)'", level: .error)
            return .launchError("tmux new-session failed for '\(sessionName)'")
        }

        // Pipe all pane output to the log file for Gemma to read.
        runSync("\(Self.tmuxBase) pipe-pane -t '\(sessionName)' -o 'cat >> \(logPath(slug: slug))'")

        // Headless by design. The tmux session is detached and the pane is piped
        // to the log for Gemma; we do NOT auto-open a terminal window. With the
        // plan gate + remote-control, the user drives from the popover/phone and
        // attaches on demand via the Join button (SessionDetailView.joinSession),
        // which opens + activates iTerm2/Terminal only when explicitly clicked.
        // Auto-popping a window per session was stale friction (sandbox was
        // already headless to avoid piling up scenario windows).
        log("[lemon] tmux session ready — headless; use Join to attach")
        return nil
    }

    // MARK: - Gemma orchestration

    /// Signature of the last classified pane tail. Skips re-classifying an
    /// unchanged (stuck) pane so a wedged session can't drive Gemma in a loop
    /// (defense-in-depth for the #44 CPU spin, alongside the input bounding).
    private var lastClassifySig: Int?

    /// Returns a resume `Date` if the pane shows a Max session-limit (quota)
    /// wall — the caller parks until then and auto-resumes (#39). Otherwise
    /// classifies the pane, acts on the verdict, and returns nil.
    @discardableResult
    private func invokeGemma(ref: IssueRef) async -> Date? {
        // Lazily (re)load SwiftLM if it was unloaded after idle (#70). Warm-up-
        // on-spawn usually means it's already ready by the time the silence
        // detector fires; this is the fallback that reloads on demand.
        guard await LocalLLM.shared.ensureReady() else {
            Logger.worktree.info("[gemma] skipped — LocalLLM not ready/loading for \(ref.identifier)")
            return nil
        }
        let lines = tailLog(slug: ref.pathSlug, last: 100)
        // Quota wall (#39): claude hit the Max session limit and parked on a pane
        // Gemma can't action — classifying it would just re-fire (and fed the
        // #44 spin). Detect it here, surface the reset time, and let the caller
        // park + auto-resume rather than burn inferences on a frozen pane.
        if let resetAt = WorktreeRunner.parseSessionLimitReset(from: lines.joined(separator: "\n")) {
            let when = WorktreeRunner.shortClock(resetAt)
            Logger.worktree.error("[gemma] Max session limit reached for \(ref.identifier) — pausing until \(when)")
            log("[gemma] Max session limit reached — pausing until \(when), then auto-resuming", level: .error)
            onAiSummary?("⏳ Max limit — resuming \(when)")
            return resetAt
        }
        // Pane-change gate: if the cleaned tail is identical to what we last
        // classified, there's nothing new to decide — skip the inference.
        var hasher = Hasher()
        for line in lines {
            hasher.combine(line)
        }
        let sig = hasher.finalize()
        if sig == lastClassifySig {
            Logger.worktree.info("[gemma] pane unchanged since last classify — skipping \(ref.identifier)")
            return nil
        }
        lastClassifySig = sig
        Logger.worktree.info("[gemma] classifying \(ref.identifier) with \(lines.count) log lines")
        do {
            let response = try await LocalLLM.shared.classify(issue: ref, logLines: lines)
            Logger.worktree.info("[gemma] state=\(response.state) action=\(response.action?.type ?? "nil") summary=\(response.summary, privacy: .public)")

            onAiSummary?(response.summary)
            log("[gemma] \(response.summary)")

            guard let action = response.action else { return nil }
            switch action.type {
            case "send_keys":
                handleSendKeys(keys: action.keys ?? "", slug: ref.pathSlug,
                               reason: response.summary)
            case "notify_user":
                // Route through the existing push-notification / 🍋 Waiting path via log line.
                // A future iteration can wire this to a native notification.
                log("[gemma] needs human: \(action.message ?? response.summary)", level: .error)
            default:
                Logger.worktree.error("[gemma] unknown action type=\(action.type)")
            }
        } catch {
            Logger.worktree.error("[gemma] classify failed for \(ref.identifier): \(error.localizedDescription)")
        }
        return nil
    }

    /// Parses Claude Code's Max session-limit banner — e.g.
    /// "You've hit your session limit · resets 3:20pm (America/Boise)" — and
    /// returns the next reset `Date` (today, or tomorrow if already past). The
    /// banner's clock is in the user's local timezone, so we resolve against the
    /// local calendar. Returns nil when no limit banner is present; falls back to
    /// "now + 1h" if the banner is present but the time can't be parsed. Pure +
    /// static so it's unit-testable.
    static func parseSessionLimitReset(from text: String, now: Date = Date(),
                                       calendar: Calendar = .current) -> Date?
    {
        guard text.range(of: "session limit", options: .caseInsensitive) != nil else { return nil }
        let fallback = now.addingTimeInterval(3600)
        guard let re = try? NSRegularExpression(
            pattern: "resets\\s+(\\d{1,2}):(\\d{2})\\s*([ap]m)?", options: [.caseInsensitive],
        ),
            let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return fallback }
        let ns = text as NSString
        var hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let minute = Int(ns.substring(with: m.range(at: 2))) ?? 0
        if m.range(at: 3).location != NSNotFound {
            switch ns.substring(with: m.range(at: 3)).lowercased() {
            case "pm" where hour < 12: hour += 12
            case "am" where hour == 12: hour = 0
            default: break
            }
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var reset = calendar.date(from: comps) else { return fallback }
        if reset <= now { reset = calendar.date(byAdding: .day, value: 1, to: reset) ?? reset }
        return reset
    }

    /// Short local-time string (e.g. "3:20 PM") for surfacing the reset time.
    static func shortClock(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Auto-resume nudge after a quota reset. Sends a continuation message and a
    /// SEPARATE Enter — claude's TUI leaves a single combined text+Enter queued
    /// in the composer without submitting, so the Enter must be its own event.
    private func sendResumeKeys(slug: String) {
        let msg = "Session limit has reset - please continue."
        let escaped = msg.replacingOccurrences(of: "'", with: "'\\''")
        let name = tmuxSessionName(slug: slug)
        runSync("\(Self.tmuxBase) send-keys -t '\(name)' '\(escaped)'")
        runSync("\(Self.tmuxBase) send-keys -t '\(name)' Enter")
    }

    // Shows a 5-second cancellable toast, then sends keys to the tmux pane.
    // Safety: only an allowlist of low-risk confirmations is permitted. Anything
    // outside the list is logged and dropped — we'd rather miss a prompt than
    // type arbitrary text into a running Claude session.
    private func handleSendKeys(keys: String, slug: String, reason: String) {
        let trimmed = keys.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorktreeRunner.isSafeSendKeys(trimmed) else {
            Logger.worktree.error("[gemma] dropping unsafe send_keys=\(trimmed, privacy: .public) reason=\(reason, privacy: .public)")
            log("[gemma] dropped unsafe keystroke (\(trimmed)); needs human review", level: .error)
            onPendingAction?(nil)
            return
        }
        onPendingAction?("Gemma: \(reason)…")
        pendingActionTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // Special tmux key names (Enter, Escape, Space, etc.) must be passed
            // as separate UNQUOTED arguments — `tmux send-keys 'Enter'` types the
            // literal string "Enter" rather than pressing the Enter key.
            // Letter keys still get an auto-Enter suffix to confirm.
            let cmd: String
            if WorktreeRunner.specialKeys.contains(trimmed) {
                cmd = "\(Self.tmuxBase) send-keys -t '\(tmuxSessionName(slug: slug))' \(trimmed)"
            } else {
                let escaped = trimmed.replacingOccurrences(of: "'", with: "'\\''")
                cmd = "\(Self.tmuxBase) send-keys -t '\(tmuxSessionName(slug: slug))' '\(escaped)' Enter"
            }
            runSync(cmd)
            log("[gemma] resolved: \(reason) (sent: \(trimmed.isEmpty ? "Enter" : trimmed))")
            onPendingAction?(nil)
        }
    }

    /// tmux special key names that don't need an Enter-suffix and must not be quoted.
    static let specialKeys: Set<String> = ["Enter", "Return", "Escape", "Space", "Tab", "BTab", "BSpace", "Up", "Down", "Left", "Right"]

    /// Safe confirmations: single keystrokes Claude/claude-code prompts accept,
    /// numeric menu selections (1-9), yes/no, and the navigation/confirmation
    /// special keys an MCP-picker style menu needs (Enter to confirm a
    /// pre-checked list, Space to toggle, Escape to reject).
    static func isSafeSendKeys(_ keys: String) -> Bool {
        let allowed: Set = [
            "", "y", "Y", "n", "N",
            "yes", "Yes", "YES", "no", "No", "NO",
            "1", "2", "3", "4", "5", "6", "7", "8", "9",
        ]
        return allowed.contains(keys) || specialKeys.contains(keys)
    }

    // MARK: - Log tail helper

    /// Counts non-empty lines in the pane log. Used by the silence detector
    /// instead of byte-count so ANSI cursor-redraw inflation doesn't reset the
    /// activity timer.
    private func countLogLines(at path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func tailLog(slug: String, last n: Int) -> [String] {
        guard let content = try? String(contentsOfFile: logPath(slug: slug), encoding: .utf8) else {
            return []
        }
        return WorktreeRunner.tailLines(from: content, last: n)
    }

    /// Bounds the Gemma classify input. The pane log is dense with ANSI
    /// cursor-redraw escapes and uses bare CRs (not LFs) for in-place repaints,
    /// so a naive "split on \n, take last N" can return a single multi-hundred-KB
    /// blob — which became a 600K-token prompt that wedged SwiftLM at prefill
    /// (#44). Strip ANSI, split on CR *and* LF, drop blanks, take the last N
    /// lines, then hard-cap total characters as a belt-and-suspenders ceiling.
    /// Pure + static so it's unit-testable.
    static func tailLines(from content: String, last n: Int, maxChars: Int = 6000) -> [String] {
        let cleaned = stripANSI(content)
        let lines = cleaned
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var tail = lines.count <= n ? lines : Array(lines[(lines.count - n)...])
        // Char ceiling: drop oldest lines until under budget (keep most recent).
        var total = tail.reduce(0) { $0 + $1.count }
        while total > maxChars, tail.count > 1 {
            total -= tail.removeFirst().count
        }
        // A single surviving line still over budget → truncate to its tail.
        if tail.count == 1, let only = tail.first, only.count > maxChars {
            tail[0] = String(only.suffix(maxChars))
        }
        return tail
    }

    /// Removes the common ANSI escape sequences (CSI + OSC) Claude's TUI emits,
    /// so the cleaned text is line-splittable and compact. Not a full terminal
    /// emulator — just enough to keep the classify prompt bounded and readable.
    static func stripANSI(_ s: String) -> String {
        var out = s
        let patterns = [
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", // CSI … final byte
            "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", // OSC … BEL/ST
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out
    }

    // MARK: - Synchronous shell helper (used for setup/teardown, not in async hot paths)

    /// Use a login shell (`zsh -l -c`) so Homebrew's PATH on Apple Silicon
    /// (/opt/homebrew/bin) is sourced from .zprofile. Without -l, tools like
    /// tmux installed via `brew install` are invisible at runtime even though
    /// the onboarding step (which also uses -l) correctly detects them — that
    /// mismatch caused "tmux not found" failures live, despite tmux being
    /// installed and verified at setup.
    @discardableResult
    private func runSync(_ command: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Label polling

    private func pollUntilDone(
        ref: IssueRef,
        pair: WorkspacePair,
        client: any IssueSourceClient,
        auth: SourceAuth,
        sessionPath: String,
        repos: [(name: String, repoPath: String)],
        isMultiRepo: Bool,
        branch: String,
        retrigger: LemonMarker?,
        workspacePath: String,
        sentinelPath: String,
    ) async {
        let deadline = Date().addingTimeInterval(8 * 3600) // 8h max; prevents forever-stuck icon
        let slug = ref.pathSlug
        var lastLineCount = 0
        var lastActivityAt = Date()
        var lastGemmaAt: Date? = nil
        var resultGateActive = false
        var resumeAt: Date? = nil // set when parked on a Max session-limit wall (#39)

        while !stopped, Date() < deadline {
            try? await Task.sleep(for: .seconds(10))
            guard !stopped else { break }

            // Result gate (opt-in): if the build wrote the result sentinel
            // instead of opening the PR, park at .resultReview until the human
            // approves, then let the same session open the PR. Absent → the
            // 🍋 Complete path below runs unchanged.
            let resultPath = resultReadyPath(slug: slug)
            if let summary = try? String(contentsOfFile: resultPath, encoding: .utf8),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if !resultGateActive {
                    resultGateActive = true
                    log("[lemon] build ready for review — awaiting approval to open PR")
                    onResultReady?(summary)
                    onStatusChange?(.resultReview)
                    try? await client.applyState(ref: ref, state: .waiting, auth: auth)
                }
                let gatePath = gateSentinelPath(slug: slug)
                if let raw = try? String(contentsOfFile: gatePath, encoding: .utf8) {
                    let decision = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? FileManager.default.removeItem(atPath: gatePath)
                    try? FileManager.default.removeItem(atPath: resultPath)
                    resultGateActive = false
                    if decision == "approve" {
                        log("[lemon] result approved for \(ref.identifier) — opening PR")
                        onStatusChange?(.executing)
                        await clearStateConfirmed(ref: ref, state: .waiting, client: client, auth: auth)
                        try? await client.applyState(ref: ref, state: .inProgress, auth: auth)
                    } else {
                        log("[lemon] result changes requested for \(ref.identifier)")
                        onStatusChange?(.executing)
                    }
                }
                continue // parked at the result gate; skip Complete/silence checks
            }

            // Poll PR URL from gh CLI (first match across all repos).
            if let prUrl = await detectPR(branch: branch, repos: repos) {
                onPRUrl?(prUrl)
            }

            // Check for 🍋 Complete label directly on this issue. We don't use
            // fetchCompleteQueue() here because it's scoped to the assignee and
            // would miss issues completed by someone else; fetchIssueLabels
            // targets the single ref and is cheaper too.
            if let labels = try? await client.fetchIssueLabels(ref: ref, auth: auth) {
                if labels.contains(LemonState.complete.labelName) {
                    let done = await handleComplete(
                        ref: ref,
                        pair: pair,
                        client: client,
                        auth: auth,
                        sessionPath: sessionPath,
                        repos: repos,
                        isMultiRepo: isMultiRepo,
                        branch: branch,
                        retrigger: retrigger,
                        workspacePath: workspacePath,
                    )
                    if done { return }
                    // Premature 🍋 Complete (no PR) was bounced to 🍋 Waiting —
                    // keep polling so the real PR can still open (#53).
                    continue
                }
                // Infer waiting vs executing from the current label set. #51:
                // check In Progress FIRST. When a gate approval's
                // clearState(.waiting) didn't take, both 🍋 In Progress and
                // 🍋 Waiting linger; the old waiting-first precedence then pinned
                // a building session to "Waiting" every tick (and fed
                // reconcileLabels building=false, which cleared In Progress and
                // kept Waiting — a desync death spiral). Resolve the inconsistent
                // both-present set to the more-advanced state (building) and
                // re-clear the stale Waiting so it self-heals.
                let hasInProgress = labels.contains(LemonState.inProgress.labelName)
                let hasWaiting = labels.contains(LemonState.waiting.labelName)
                if hasInProgress {
                    onStatusChange?(.executing)
                    if hasWaiting {
                        await clearStateConfirmed(ref: ref, state: .waiting, client: client, auth: auth)
                    }
                } else if hasWaiting {
                    onStatusChange?(.waiting)
                }
            }

            // Two ways the session can have ended without 🍋 Complete:
            //   (a) the launcher's `echo $? > sentinelPath` ran after claude
            //       exited cleanly — happy "claude died but session was alive"
            //   (b) the tmux session itself is gone — user killed the Terminal
            //       window (SIGHUPing the bash before it could write the sentinel),
            //       or `tmux kill-session` happened, or something OOM'd it.
            //
            // The previous code only handled (a). Without (b) the orchestrator
            // would happily poll for hours after the user closed the window,
            // showing "Executing" forever.
            let sentinelExists = FileManager.default.fileExists(atPath: sentinelPath)
            // Only pay for the debounced death probe when the sentinel is absent —
            // a sentinel is already proof claude exited, and the debounce guards
            // against a lone has-session false-positive killing a live session.
            var tmuxGone = false
            if !sentinelExists { tmuxGone = await tmuxSessionDead(slug: slug) }
            if sentinelExists || tmuxGone {
                let exitCode: String
                let cause: String
                if sentinelExists {
                    exitCode = (try? String(contentsOfFile: sentinelPath, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                    cause = "claude exited (code \(exitCode))"
                } else {
                    exitCode = "no-tmux"
                    cause = "tmux session disappeared (window closed or killed)"
                }
                Logger.worktree.warning("\(cause) without setting 🍋 Complete on \(ref.identifier)")
                log("[lemon] session ended without completing — \(cause)", level: .error)
                _ = try? await client.postComment(
                    ref: ref,
                    body: "🍋 Session ended without completing — \(cause). Re-add the 🍋 label to retry.",
                    auth: auth,
                )
                try? await client.clearState(ref: ref, state: .inProgress, auth: auth)
                try? await client.clearState(ref: ref, state: .waiting, auth: auth)
                _ = exitCode
                onStatusChange?(.failed)
                return
            }

            // Silence detection: track LINE-count growth, not byte count.
            // tmux pipe-pane streams ANSI cursor-redraw sequences continuously
            // even when Claude is wedged on an interactive prompt — byte count
            // keeps inflating and the silence timer never trips. Line count
            // only grows when actual output arrives.
            let currentLines = countLogLines(at: logPath(slug: slug))
            if currentLines > lastLineCount {
                lastLineCount = currentLines
                lastActivityAt = Date()
            }
            // Publish the silence-detector timing for the idle countdown UI (#50).
            onGemmaTiming?(lastActivityAt, lastGemmaAt)
            // Quota wall (#39): if parked on a Max session-limit, don't classify
            // (it would re-fire on a frozen pane). Auto-resume once the reset time
            // passes — a continuation nudge + a separate Enter — then resume normal
            // monitoring. The user reset the limit; we just un-park the session.
            if let resume = resumeAt {
                if Date() >= resume {
                    log("[lemon] session limit reset reached — auto-resuming \(ref.identifier)")
                    sendResumeKeys(slug: slug)
                    resumeAt = nil
                    lastClassifySig = nil
                    lastActivityAt = Date()
                    lastGemmaAt = Date()
                    onStatusChange?(.executing)
                    try? await client.clearState(ref: ref, state: .waiting, auth: auth)
                    try? await client.applyState(ref: ref, state: .inProgress, auth: auth)
                }
            } else if WorktreeRunner.shouldInvokeGemma(lastActivityAt: lastActivityAt, lastGemmaAt: lastGemmaAt) {
                lastGemmaAt = Date()
                if let reset = await invokeGemma(ref: ref) {
                    // Park on the quota wall: surface 🍋 Waiting + wait for reset.
                    resumeAt = reset
                    onStatusChange?(.waiting)
                    try? await client.applyState(ref: ref, state: .waiting, auth: auth)
                }
            }
        }
        // Loop exited without completing — either stopped externally or timed out.
        if !stopped {
            Logger.worktree.warning("Session for \(ref.identifier) timed out after 8h")
            onStatusChange?(.failed)
        }
    }

    // MARK: - Completion handler

    /// Returns true when the issue is genuinely complete (report posted, ready
    /// for review). Returns false when 🍋 Complete was premature — no PR exists —
    /// so the caller keeps polling instead of treating the session as done (#53).
    @discardableResult
    private func handleComplete(
        ref: IssueRef,
        pair _: WorkspacePair,
        client: any IssueSourceClient,
        auth: SourceAuth,
        sessionPath: String,
        repos: [(name: String, repoPath: String)],
        isMultiRepo: Bool,
        branch: String,
        retrigger: LemonMarker?,
        workspacePath: String,
    ) async -> Bool {
        log("[lemon] 🍋 Complete detected for \(ref.identifier)")

        let prUrl = await detectPR(branch: branch, repos: repos)

        // #53 defense: 🍋 Complete must not precede an actual PR. On a fresh
        // (non-retrigger) session with no detectable PR, claude jumped the gun —
        // don't post a PR-less "done" report or tear down. Bounce to 🍋 Waiting
        // with the work intact and keep polling so the real PR can still open.
        if prUrl == nil, retrigger == nil {
            Logger.worktree.warning("🍋 Complete on \(ref.identifier) with no PR — bouncing to 🍋 Waiting (premature complete, #53)")
            await clearStateConfirmed(ref: ref, state: .complete, client: client, auth: auth)
            try? await client.applyState(ref: ref, state: .waiting, auth: auth)
            _ = try? await client.postComment(
                ref: ref,
                body: "## 🍋 Lemon — no PR found\n\nThis issue was marked **🍋 Complete**, but no open PR was found for branch `\(branch)`. Open the PR first (`gh pr create …`), then re-apply **🍋 Complete**. The worktree is left intact.",
                auth: auth,
            )
            onStatusChange?(.waiting)
            return false
        }

        onStatusChange?(.reviewing)

        // Final Gemma summary before posting the report comment.
        await invokeGemma(ref: ref)

        let prNumber = prUrl.flatMap { URL(string: $0)?.lastPathComponent } ?? ""
        let summary = (try? String(contentsOfFile: "\(sessionPath)/.lemon-summary.md", encoding: .utf8)) ?? ""

        // The marker stores the workspace path so retrigger can rediscover repos.
        let markerPath = workspacePath

        let commentBody = buildLemonComment(
            ref: ref,
            prUrl: prUrl,
            prNumber: prNumber,
            branch: branch,
            summary: summary,
            repoPath: markerPath,
        )

        if retrigger != nil {
            let replyBody = buildReplyComment(prUrl: prUrl, summary: summary)
            do {
                _ = try await client.postComment(ref: ref, body: replyBody, auth: auth)
            } catch {
                Logger.worktree.error("Failed to post reply comment for \(ref.identifier): \(error)")
            }
            // #9: advance the marker. A fresh Lemon Report (same marker-bearing
            // shape as initial completion) becomes the new findLatest() anchor,
            // so this re-trigger's revision comments don't re-fire on every
            // subsequent poll/launch. Without this the marker stays pinned to the
            // ORIGINAL report and any reply after it re-triggers forever.
            if let commentId = try? await client.postComment(ref: ref, body: commentBody, auth: auth) {
                log("[lemon] posted Lemon comment \(commentId) (re-trigger marker advance)")
            }
        } else {
            if let commentId = try? await client.postComment(ref: ref, body: commentBody, auth: auth) {
                log("[lemon] posted Lemon comment \(commentId)")
            }
        }

        // Clean up intermediate state labels — without this, finished
        // issues accumulate 🍋 (trigger) + 🍋 In Progress + 🍋 Waiting
        // alongside 🍋 Complete. GitHub doesn't auto-remove labels when
        // a new one is applied (Linear's source-state machinery does,
        // GH doesn't), so we have to be explicit at the transition.
        try? await client.clearState(ref: ref, state: .trigger, auth: auth)
        try? await client.clearState(ref: ref, state: .inProgress, auth: auth)
        try? await client.clearState(ref: ref, state: .waiting, auth: auth)

        // Stash cleanup info on the Session via the orchestrator's
        // callback. The runner stops here — the user fires the actual
        // worktree/tmux/tmp teardown by clicking "Cleanup worktree" in
        // the detail view, which routes through
        // Orchestrator.cleanupSession. Letting the user inspect or
        // check out the worktree before it's blown away is the whole
        // point of the .reviewing state.
        let cleanup = WorktreeCleanupInfo(
            sessionPath: sessionPath,
            isMultiRepo: isMultiRepo,
            repos: repos.map { WorktreeCleanupInfo.RepoRef(name: $0.name, repoPath: $0.repoPath) },
            slug: ref.pathSlug,
        )
        onCleanupReady?(cleanup)
        log("[lemon] ready for review — worktree at \(sessionPath). Click Cleanup to tear down.")
        return true
    }

    // MARK: - Comment builders

    private func buildLemonComment(
        ref: IssueRef,
        prUrl: String?,
        prNumber: String,
        branch: String,
        summary: String,
        repoPath: String,
    ) -> String {
        var md = "## 🍋 Lemon Report — \(ref.identifier)\n\n"
        if let url = prUrl {
            md += "**PR:** [#\(prNumber)](\(url))\n"
        }
        md += "**Branch:** `\(branch)`\n"
        if !summary.isEmpty {
            md += "\n### What was done\n\(summary)\n"
        }
        md += "\n---\n*Reply to this comment to ask Lemon to revise. Lemon will update the branch and PR.*\n\n"
        // No `comment:` field here on purpose. The Lemon Report comment is the
        // marker itself, so its ID is unknown until commentCreate returns.
        // LemonMarkerExtractor.parse falls back to the host comment's own ID
        // when the field is absent, which is exactly what we want for re-trigger.
        //
        // `source: github` is written on GitHub-source reports so the parser
        // can route re-triggers correctly post-upgrade. Linear stays
        // unlabelled (treated as the default by the extractor).
        let sourceLine = ref.source == .github ? "\nsource: github" : ""
        md += "<!-- lemon\nbranch: \(branch)\npr: \(prNumber)\nrepo: \(repoPath)\(sourceLine)\n-->"
        return md
    }

    private func buildReplyComment(prUrl: String?, summary: String) -> String {
        var md = "## 🍋 Lemon Update\n\n"
        if let url = prUrl { md += "**PR:** \(url)\n\n" }
        if !summary.isEmpty { md += summary }
        return md
    }

    // MARK: - PR detection

    private func detectPR(branch: String, repos: [(name: String, repoPath: String)]) async -> String? {
        // Sandbox has no GitHub for `gh pr list` to query, so the completion path
        // (#53 report, #54 auto-retire) could never be exercised. fake-claude
        // writes the "opened PR" URL to /tmp/lemon-pr-<slug> when it sets
        // 🍋 Complete; read it here so detection mirrors a real opened PR.
        if KeychainStore.isSandbox {
            let slug = branch.hasPrefix("lemon/") ? String(branch.dropFirst("lemon/".count)) : branch
            guard let raw = try? String(contentsOfFile: "/tmp/lemon-pr-\(slug)", encoding: .utf8) else { return nil }
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : url
        }
        for repo in repos {
            if let url = await detectPRInRepo(branch: branch, repoPath: repo.repoPath) {
                return url
            }
        }
        return nil
    }

    private func detectPRInRepo(branch: String, repoPath: String) async -> String? {
        guard let output = try? await shell(
            "cd \(q(repoPath)) && gh pr list --head \(branch) --json url --jq '.[0].url' 2>/dev/null",
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }

    /// True if the PR at `prUrl` is merged. Drives the #54 "ready to clean up"
    /// surface on a `.reviewing` session once its PR lands. `gh pr view` resolves
    /// a full PR URL on its own, but we run from the worktree (`cwd`) so gh's auth
    /// and host config resolve the same way `detectPR` does.
    func isPRMerged(prUrl: String, cwd: String?) async -> Bool {
        let prefix = cwd.map { "cd \(q($0)) && " } ?? "cd /tmp && "
        guard let output = try? await shell(
            "\(prefix)gh pr view \(q(prUrl)) --json state --jq '.state' 2>/dev/null",
        ) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "MERGED"
    }

    // MARK: - Shell helper

    /// Login shell for the same PATH reason as runSync above.
    @discardableResult
    private func shell(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: ShellError(command: command, output: output, code: proc.terminationStatus))
                }
            }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func log(_ line: String, level: OSLogType = .info) {
        Logger.worktree.log(level: level, "\(line)")
        onLogLine?(line)
    }

    private func q(_ s: String) -> String {
        "\"\(s)\""
    }
}

struct ShellError: Error, LocalizedError {
    let command: String
    let output: String
    let code: Int32
    var errorDescription: String? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "exit \(code)" : "exit \(code): \(out)"
    }
}
