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
    /// In-app sessions parked at `.queued` (over the concurrency limit, #46).
    var queuedCount: Int = 0
    var error: String?

    /// One-line settings subtitle: "polled 12s ago · 2 triggered · 1 complete"
    /// (+ " · 1 queued" when the concurrency limit is holding work back).
    /// Returns nil pre-first-poll so the row stays editorial-quiet.
    var subtitle: String? {
        guard let t = lastPolledAt else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let rel = f.localizedString(for: t, relativeTo: Date())
        if let err = error {
            return "polled \(rel) · \(err.prefix(80))"
        }
        let queuedPart = queuedCount > 0 ? " · \(queuedCount) queued" : ""
        return "polled \(rel) · \(triggerCount) triggered\(queuedPart) · \(completeCount) complete"
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

    /// Aggregate state for the menu-bar status glyph. Priority reflects what most
    /// needs the user's eye: a session awaiting human input (plan/result gate or
    /// a mid-build question) wins, then active work, then the most recent
    /// outcome (error/done), else idle. Disabled when nothing is configured.
    var menuBarGlyph: MenuBarGlyph {
        MenuBarGlyph.aggregate(
            activeStatuses: sessions.active.map(\.status),
            lastRecentStatus: sessions.recent.first?.status,
            lastRecentEndedAt: sessions.recent.first?.endedAt,
            now: Date(),
            configured: KeychainStore.shared.isConfigured,
        )
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
        Task { _ = await LocalLLM.shared.ensureReady() }
        Task { @MainActor [weak self] in
            await self?.restoreSessions()
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

    /// On launch, reconcile in-flight sessions against reality (issue #35).
    /// First the persisted index (the authoritative record): each entry's tmux
    /// session is liveness-checked (debounced), and
    ///   • alive            → reattach (resume the lifecycle, no relaunch),
    ///   • dead + reviewing → restore the cleanup-ready card (pending review),
    ///   • dead otherwise   → GC the worktree (died mid-run; drop the entry).
    /// Then a fallback `/tmp/lemon-*` scan picks up pre-upgrade orphans that
    /// predate the index. Finally the index is rewritten to match what survived.
    @MainActor
    private func restoreSessions() async {
        let keychain = KeychainStore.shared
        let workspaces = keychain.workspaces
        let byId = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let probe = WorktreeRunner() // tmux liveness helpers only — never run()
        var restoredSlugs = Set<String>()

        for p in keychain.sessionIndex {
            // Already tracking this issue this process (shouldn't happen on a
            // fresh launch, but guards a double-restore).
            if sessions.isTracking(ref: p.issue) { restoredSlugs.insert(p.slug); continue }

            // Queued pre-relaunch (#46): no tmux/worktree to probe — re-adopt as
            // queued; promoteQueued() launches it when a slot frees. An
            // unrunnable one (workspace gone) is failed there, not here.
            if p.status == .queued {
                let s = Session(issue: p.issue)
                s.status = .queued
                s.workspaceId = p.workspaceId
                s.branch = p.branch
                s.retrigger = p.retrigger
                s.worktreePath = "/tmp/lemon-\(p.slug)"
                sessions.add(s)
                restoredSlugs.insert(p.slug)
                continue
            }

            // Workspace or credentials gone → can't manage it; leave the worktree
            // for the GC sweep and drop the entry (it won't be re-persisted).
            guard let ws = byId[p.workspaceId],
                  let identity = keychain.identity(for: ws),
                  let auth = keychain.authFor(identity: identity)
            else {
                Logger.orchestrator.info("restore: workspace/credentials gone for \(p.issue.identifier) — dropping")
                continue
            }

            let cli = client(for: identity)
            let alive = await !(probe.tmuxSessionDead(slug: p.slug))
            let sessionPath = "/tmp/lemon-\(p.slug)"
            let worktreeExists = isDirectory(sessionPath)

            if alive {
                restoreLiveSession(persisted: p, workspace: ws, identity: identity,
                                   client: cli, auth: auth)
                restoredSlugs.insert(p.slug)
                // Heal any straggler labels left by the crash (the #31 trifecta).
                await reconcileLabels(ref: p.issue, building: p.status == .executing,
                                      client: cli, auth: auth)
            } else if p.status == .reviewing, worktreeExists {
                // Completed pre-crash, awaiting the user's Cleanup click.
                let info = p.cleanupInfo ?? makeCleanupInfo(slug: p.slug, sessionPath: sessionPath, workspace: ws)
                let session = Session(issue: p.issue)
                session.status = .reviewing
                session.workspaceId = ws.id
                session.worktreePath = sessionPath
                session.cleanupInfo = info
                session.appendLog("[lemon] restored ready-for-review session — worktree at \(sessionPath)")
                sessions.add(session)
                restoredSlugs.insert(p.slug)
                await reconcileLabels(ref: p.issue, client: cli, auth: auth)
                Logger.orchestrator.info("restore: \(p.issue.identifier) ready for review (tmux dead)")
            } else if worktreeExists {
                // Died mid-run (tmux gone before 🍋 Complete). GC the worktree so
                // a retry's `git worktree add` succeeds; user re-adds 🍋 to retry.
                Logger.orchestrator.info("restore: \(p.issue.identifier) died mid-run — GC'ing worktree")
                await gcWorktree(slug: p.slug, sessionPath: sessionPath, workspace: ws, probe: probe)
            }
            // dead + no worktree → nothing to restore or GC; entry simply drops.
        }

        // Fallback: pre-upgrade orphans with no index entry.
        await reconstructUnindexedWorktrees(workspaces: workspaces, probe: probe,
                                            skip: restoredSlugs)

        // #55: GC stale worktree registrations + un-adoptable orphan tmux that
        // nothing tracks (incl. leftovers from Failed sessions, which drop out of
        // the index). Runs last so everything we restored above is protected.
        await reconcileOrphans(workspaces: workspaces, probe: probe, keepSlugs: restoredSlugs)

        // Rewrite the index to reflect exactly what we restored into `active`.
        sessions.persist()
    }

    /// Startup leak GC (#55). Two leaks: (1) stale `git worktree list`
    /// registrations for terminal/Failed sessions that break a later
    /// `git worktree add` for the same slug; (2) orphan `-L lemon` tmux sessions
    /// nothing tracks. We prune dead+untracked worktree registrations (+ their
    /// branch) and kill un-adoptable orphan tmux, while LEAVING live worktrees a
    /// re-trigger could still adopt (#38). Clean-quit policy is deliberately
    /// no-teardown (guaranteed re-adopt suits the unattended Mac-mini); this
    /// startup sweep is what bounds the leak.
    @MainActor
    private func reconcileOrphans(workspaces: [Workspace], probe: WorktreeRunner,
                                  keepSlugs: Set<String>) async
    {
        // Protect everything currently tracked, not just index-restored slugs:
        // reconstructed .reviewing sessions live in `active` but aren't in
        // restoredSlugs, and pruning their worktree would delete work awaiting
        // the user's review.
        var keep = keepSlugs
        for s in sessions.active {
            keep.insert(s.issue.pathSlug)
            if let cs = s.cleanupInfo?.slug { keep.insert(cs) }
        }

        var repoPaths: [String] = []
        for ws in workspaces {
            if ws.allReposInFolder {
                repoPaths.append(contentsOf: probe.discoverRepoPaths(in: ws.path))
            } else {
                repoPaths.append(ws.path)
            }
        }
        let pruned = await probe.gcStaleWorktrees(repoPaths: Array(Set(repoPaths)), keepSlugs: keep)
        if !pruned.isEmpty {
            Logger.orchestrator.info("[gc] pruned stale worktrees: \(pruned.joined(separator: ", "))")
        }

        // Orphan tmux: a live -L lemon session nothing tracks. Un-adoptable
        // (slug matches no configured workspace) → kill so a live claude can't
        // run forever detached; matchable → leave for a re-trigger to adopt.
        let liveSlugs = await probe.lemonTmuxSlugs()
        for slug in liveSlugs where !keep.contains(slug) {
            if matchSlugToWorkspace(slug: slug, sessionPath: "/tmp/lemon-\(slug)", workspaces: workspaces) == nil {
                Logger.orchestrator.info("[gc] killing un-adoptable orphan tmux \(slug)")
                probe.killTmuxSession(slug: slug)
            } else {
                Logger.orchestrator.info("[gc] live orphan tmux \(slug) matches a workspace — leaving for re-adopt")
            }
        }
    }

    /// Restore a still-alive session: rebuild its pair, wire the same callbacks
    /// `startSession` uses, and reattach (no worktree setup, no relaunch).
    @MainActor
    private func restoreLiveSession(persisted p: PersistedSession, workspace: Workspace,
                                    identity: Identity, client: any IssueSourceClient,
                                    auth: SourceAuth)
    {
        let session = Session(issue: p.issue)
        session.workspaceId = workspace.id
        session.branch = p.branch
        session.retrigger = p.retrigger
        session.status = p.status
        session.worktreePath = "/tmp/lemon-\(p.slug)"
        session.terminalWindowName = "Lemon · \(p.issue.identifier)"
        session.cleanupInfo = p.cleanupInfo
        session.appendLog("[lemon] reattached on launch (\(p.status.displayLabel))")
        sessions.add(session)

        let runner = WorktreeRunner()
        runners[session.id] = runner
        wire(runner, to: session)

        let pair = makePair(workspace: workspace, identity: identity)
        Task.detached(priority: .background) {
            await runner.reattach(persisted: p, pair: pair, client: client, auth: auth)
        }
        Logger.orchestrator.info("restore: reattached \(p.issue.identifier) at \(p.status.displayLabel)")
    }

    /// Best-effort GC of one dead worktree + its tmux/sentinels. Uses the
    /// workspace to drive a clean `git worktree remove` (proper repoPath).
    @MainActor
    private func gcWorktree(slug: String, sessionPath: String, workspace: Workspace,
                            probe: WorktreeRunner) async
    {
        let info = makeCleanupInfo(slug: slug, sessionPath: sessionPath, workspace: workspace)
        await probe.cleanupWorktrees(
            repos: info.repos.map { (name: $0.name, repoPath: $0.repoPath) },
            sessionPath: sessionPath, isMultiRepo: info.isMultiRepo, slug: slug,
        )
    }

    /// Fallback `/tmp/lemon-*` scan for worktrees with no index entry (pre-upgrade
    /// orphans). Live ones are LEFT ALONE — we have no IssueRef to manage them and
    /// must never synthesize a cleanup card for a live session (the footgun this
    /// issue fixes). Dead ones that match a workspace become cleanup-ready cards.
    @MainActor
    private func reconstructUnindexedWorktrees(workspaces: [Workspace],
                                               probe: WorktreeRunner,
                                               skip: Set<String>) async
    {
        guard !workspaces.isEmpty else { return }
        let fm = FileManager.default
        guard let tmpEntries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }

        for dirName in tmpEntries where dirName.hasPrefix("lemon-") {
            let slug = String(dirName.dropFirst("lemon-".count))
            if skip.contains(slug) { continue }
            let sessionPath = "/tmp/\(dirName)"
            guard isDirectory(sessionPath) else { continue } // skip log/sentinel files
            if sessions.active.contains(where: { $0.cleanupInfo?.slug == slug }) { continue }
            if sessions.recent.contains(where: { $0.cleanupInfo?.slug == slug }) { continue }

            // Live but un-indexed: an orphan from before this build. We can't
            // reattach (no IssueRef) — leave it running rather than risk killing it.
            if await !(probe.tmuxSessionDead(slug: slug)) {
                Logger.orchestrator.info("restore: live un-indexed worktree \(slug) — leaving untracked")
                continue
            }

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

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
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
            // Reclaim ~5 GB by unloading SwiftLM after it's been idle (#70);
            // never while a session is active. Snapshot state *after* so the UI
            // reflects .idle the same tick. Reloads lazily on the next classify.
            LocalLLM.shared.unloadIfIdle(hasActiveSessions: !sessions.active.isEmpty)
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

        // Promote queued sessions into freed slots (#46). Runs after all
        // workspaces poll so freshly-completed sessions release their slots first.
        await promoteQueued()
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
                // Belt-and-suspenders trigger (#31): require BOTH "this is me"
                // signals — assignee == you (already enforced by the source's
                // fetchTriggerQueue) AND the 🍋-labeler == you. The labeler check
                // (M2, #13) is now ALWAYS on, not gated by lockdown:
                //  - GitHub exposes the labeler via the events API, so it's
                //    authoritative — must be you, lockdown or not.
                //  - Linear can't cheaply query the labeler (nil) → fail-open: the
                //    assignee/userId queue stays the gate. Lockdown then adds the
                //    author-trust fallback as a stricter extra for that case.
                // Lockdown otherwise governs only M3 (re-trigger) and M4 (content).
                let labeler = try? await client.triggerLabelActor(ref: ref, auth: auth)
                if let labeler {
                    if !TrustPolicy.isTrusted(author: labeler, trustedAuthor: identity.handle) {
                        Logger.orchestrator.info("Skip \(ref.identifier) — 🍋-labeler \(labeler) != \(identity.handle)")
                        continue
                    }
                } else if workspace.lockdown {
                    if isKnownOutsider(ref.authorLogin, identity: identity) {
                        Logger.orchestrator.info("Lockdown: skip \(ref.identifier) — labeler undeterminable, author=\(ref.authorLogin ?? "?") not trusted (\(identity.handle))")
                        continue
                    }
                }
                guard runningCount < maxConcurrent else {
                    // #46: don't silently drop the overflow — enqueue it as a
                    // tracked .queued session (visible in the popover, FIFO) and
                    // keep scanning so ALL over-limit triggers get queued, not
                    // just up to the first. promoteQueued() launches them as
                    // slots free. isTracking suppresses re-queue next poll.
                    enqueueSession(ref: ref, workspace: workspace, retrigger: nil)
                    continue
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
                // Lockdown (#13, M3): re-trigger only on the USER's own reply.
                // An outsider commenting on a public 🍋 Complete issue must not
                // be able to drive a new Claude run.
                if workspace.lockdown {
                    let trusted = await (try? hasTrustedReply(ref: ref, after: marker.commentId,
                                                              identity: identity, client: client, auth: auth)) ?? false
                    if !trusted {
                        Logger.orchestrator.info("Lockdown: skip retrigger \(ref.identifier) — newest replies not authored by \(identity.handle)")
                        continue
                    }
                }
                guard runningCount < maxConcurrent else {
                    // #46: re-triggers respect the concurrency limit too (they
                    // didn't before) — queue the overflow instead of bypassing it.
                    enqueueSession(ref: ref, workspace: workspace, retrigger: marker)
                    continue
                }
                Logger.orchestrator.info("Re-triggering \(ref.identifier) from reply")
                await startSession(ref: ref, workspace: workspace, identity: identity,
                                   client: client, auth: auth, retrigger: marker)
            }

            // 3. Reconcile 🍋* labels for this workspace's active sessions. A
            // crash mid-clearState can leave stragglers — issue #31 saw 🍋 In
            // Progress + 🍋 Waiting + 🍋 Complete all set at once. Lemon is the
            // sole writer of state labels, so we converge them every poll (#35).
            // Skip .queued sessions: they haven't started, still carry their 🍋
            // trigger label, and must keep it so the issue stays in the trigger
            // queue until promoteQueued() launches it (#46).
            for session in sessions.active
                where session.workspaceId == workspace.id && session.status != .queued
            {
                await reconcileLabels(ref: session.issue, building: session.status == .executing,
                                      client: client, auth: auth)
            }
            status.queuedCount = sessions.active.count(where: {
                $0.workspaceId == workspace.id && $0.status == .queued
            })

            // 4. Auto-retire reviewing sessions whose work has truly landed (#54).
            // The runner has already returned by .reviewing, so the poll loop is
            // what notices the PR merged (primary signal) or the issue closed
            // (secondary). On either, auto-tear-down: a merged PR means the work
            // is done, and the unattended "Mac mini on your desk" goal wants a
            // real terminal state without a human click. `prMerged` doubles as the
            // "cleanup already kicked off" guard so we don't re-fire mid-teardown.
            for session in sessions.active
                where session.workspaceId == workspace.id
                && session.status == .reviewing && !session.prMerged
            {
                let merged = await {
                    guard let url = session.prUrl else { return false }
                    let runner = runnerOrThrowaway(sessionId: session.id)
                    return await runner.isPRMerged(prUrl: url, cwd: session.worktreePath)
                }()
                let closed = await merged ? false : ((try? client.isIssueClosed(ref: session.issue, auth: auth)) ?? false)
                guard merged || closed else { continue }
                session.prMerged = true
                session.aiSummary = merged ? "PR merged — cleaning up" : "Issue closed — cleaning up"
                Logger.orchestrator.info("reviewing \(session.issue.identifier): \(merged ? "PR merged" : "issue closed") — auto-cleanup")
                cleanupSession(session)
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

    /// Converge an issue's 🍋* state labels toward a single consistent state,
    /// healing the stragglers a crashed `clearState` leaves behind (issue #35 /
    /// the #31 trifecta). Two rules, both of which only ever CLEAR a redundant
    /// label and never erase the meaningful "needs attention" / "complete"
    /// signal — so this is race-safe against Claude still setting 🍋 Waiting as a
    /// triage signal (migrating that to a sentinel is deferred, out of scope here):
    ///   1. 🍋 Complete present → the work is done, so 🍋 (trigger) / In Progress /
    ///      Waiting are necessarily stale; clear them.
    ///   2. In Progress AND Waiting both present → a session can't be building and
    ///      parked at once. Which one wins depends on what the session is actually
    ///      doing: a just-approved gate is BUILDING, so In Progress wins and the
    ///      stale 🍋 Waiting is cleared (#51 — otherwise this janitor kept clearing
    ///      In Progress every poll and pinned a building session to "Waiting").
    ///      Otherwise the session is genuinely parked, so Waiting (attention) wins.
    /// Idempotent: a no-op when labels are already consistent.
    @MainActor
    private func reconcileLabels(ref: IssueRef, building: Bool = false,
                                 client: any IssueSourceClient,
                                 auth: SourceAuth) async
    {
        guard let labels = try? await client.fetchIssueLabels(ref: ref, auth: auth) else { return }
        let present = Set(labels)
        func has(_ s: LemonState) -> Bool {
            present.contains(s.labelName)
        }
        func clear(_ s: LemonState, _ why: String) async {
            try? await client.clearState(ref: ref, state: s, auth: auth)
            Logger.orchestrator.info("reconcile \(ref.identifier): cleared \(s.labelName) — \(why)")
        }

        if has(.complete) {
            if has(.trigger) { await clear(.trigger, "stale alongside 🍋 Complete") }
            if has(.inProgress) { await clear(.inProgress, "stale alongside 🍋 Complete") }
            if has(.waiting) { await clear(.waiting, "stale alongside 🍋 Complete") }
        } else if has(.inProgress), has(.waiting) {
            if building {
                await clear(.waiting, "session is building (gate approved) — keeping 🍋 In Progress")
            } else {
                await clear(.inProgress, "can't build and wait at once — keeping 🍋 Waiting")
            }
        }
    }

    // MARK: - Lockdown trust helpers (#13)

    private func authoredByUser(_ author: String?, identity: Identity) -> Bool {
        TrustPolicy.isTrusted(author: author, trustedAuthor: identity.handle)
    }

    private func isKnownOutsider(_ author: String?, identity: Identity) -> Bool {
        TrustPolicy.isKnownOutsider(author: author, me: identity.handle)
    }

    /// True if any comment AFTER the marker was authored by the user — the
    /// trusted-commenter gate for re-trigger in lockdown (M3).
    private func hasTrustedReply(ref: IssueRef, after commentId: String, identity: Identity,
                                 client: any IssueSourceClient, auth: SourceAuth) async throws -> Bool
    {
        let comments = try await client.fetchComments(ref: ref, auth: auth)
        guard let idx = comments.firstIndex(where: { $0.id == commentId }) else { return false }
        let after = comments[comments.index(after: idx)...]
        return after.contains { authoredByUser($0.author, identity: identity) }
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

    /// Concurrency ceiling (#46). User-configurable in Settings; defaults to 2,
    /// clamped ≥ 1 so the runner can never be starved to zero.
    private var maxConcurrent: Int {
        max(1, KeychainStore.shared.maxConcurrentSessions)
    }

    /// Sessions actually running (or setting up) — everything except `.queued`.
    /// The capacity check counts THIS, not `active.count`: counting queued
    /// sessions as occupied slots would deadlock the queue (#46).
    private var runningCount: Int {
        sessions.active.count(where: { $0.status != .queued })
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
        let session = makeSession(ref: ref, workspace: workspace, retrigger: retrigger)
        sessions.add(session)
        launchSession(session: session, ref: ref, workspace: workspace, identity: identity,
                      client: client, auth: auth, retrigger: retrigger)
    }

    /// Build a Session with the fields the persisted index (issue #35) needs to
    /// reattach — stamped BEFORE add() so the first persist captures them. Shared
    /// by the run path and the queue path; the worktree/branch are just strings
    /// here (no git work happens until launchSession).
    @MainActor
    private func makeSession(ref: IssueRef, workspace: Workspace,
                             retrigger: LemonMarker?) -> Session
    {
        let session = Session(issue: ref)
        session.worktreePath = "/tmp/lemon-\(ref.pathSlug)"
        session.terminalWindowName = "Lemon · \(ref.identifier)"
        session.workspaceId = workspace.id
        session.branch = retrigger?.branch ?? "lemon/\(ref.pathSlug)"
        session.retrigger = retrigger
        return session
    }

    /// Enqueue an over-limit trigger as a tracked `.queued` session (#46).
    /// Visible in the popover; promoted FIFO by `promoteQueued()` when a slot
    /// frees. No worktree/runner is created here.
    @MainActor
    private func enqueueSession(ref: IssueRef, workspace: Workspace, retrigger: LemonMarker?) {
        let session = makeSession(ref: ref, workspace: workspace, retrigger: retrigger)
        session.status = .queued
        sessions.add(session)
        Logger.orchestrator.info("Queued \(ref.identifier) — at max concurrent (\(self.runningCount)/\(self.maxConcurrent))")
    }

    /// Spin up the runner for a session (the launch tail shared by startSession
    /// and queue promotion). Flips the session out of `.queued` into `.planning`.
    @MainActor
    private func launchSession(session: Session, ref: IssueRef, workspace: Workspace,
                               identity: Identity, client: any IssueSourceClient,
                               auth: SourceAuth, retrigger: LemonMarker?)
    {
        session.status = .planning
        let runner = WorktreeRunner()
        runners[session.id] = runner
        wire(runner, to: session)

        let pair = makePair(workspace: workspace, identity: identity)
        let lockdown = workspace.lockdown
        let trustedAuthor = identity.handle
        Task.detached(priority: .background) {
            await runner.run(ref: ref, pair: pair, client: client, auth: auth, retrigger: retrigger,
                             lockdown: lockdown, trustedAuthor: trustedAuthor)
        }
    }

    /// Promote queued sessions into freed slots, oldest first (FIFO by
    /// startedAt) (#46). A session whose workspace/credentials vanished while it
    /// waited is failed rather than left to wedge the queue.
    @MainActor
    private func promoteQueued() async {
        let keychain = KeychainStore.shared
        let byId = Dictionary(keychain.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        while runningCount < maxConcurrent,
              let next = sessions.active
              .filter({ $0.status == .queued })
              .min(by: { $0.startedAt < $1.startedAt })
        {
            guard let wsId = next.workspaceId, let ws = byId[wsId],
                  let identity = keychain.identity(for: ws),
                  let auth = keychain.authFor(identity: identity)
            else {
                Logger.orchestrator.info("promoteQueued: \(next.issue.identifier) unrunnable (workspace/credentials gone) — failing")
                next.status = .failed
                sessions.finish(next)
                continue
            }
            Logger.orchestrator.info("Promoting queued \(next.issue.identifier) — slot free (\(self.runningCount)/\(self.maxConcurrent))")
            launchSession(session: next, ref: next.issue, workspace: ws, identity: identity,
                          client: client(for: identity), auth: auth, retrigger: next.retrigger)
        }
        sessions.persist()
    }

    /// Wire a runner's callbacks to a Session. Shared by `startSession` and the
    /// reattach path (issue #35) so both keep identical UI + persistence hooks.
    @MainActor
    private func wire(_ runner: WorktreeRunner, to session: Session) {
        runner.onLogLine = { [weak session] line in
            DispatchQueue.main.async { session?.appendLog(line) }
        }
        runner.onStatusChange = { [weak self, weak session] status in
            DispatchQueue.main.async {
                session?.status = status
                if status.isTerminal {
                    if let s = session { self?.sessions.finish(s) }
                    self?.runners.removeValue(forKey: session?.id ?? UUID())
                } else {
                    // Persist the new status so a relaunch reattaches at the
                    // right point in the lifecycle (issue #35).
                    self?.sessions.persist()
                }
            }
        }
        runner.onPRUrl = { [weak session] url in
            DispatchQueue.main.async { session?.prUrl = url }
        }
        runner.onPlanReady = { [weak session] plan in
            DispatchQueue.main.async { session?.planMarkdown = plan }
        }
        runner.onResultReady = { [weak session] summary in
            DispatchQueue.main.async {
                session?.aiSummary = summary.split(separator: "\n").first.map(String.init) ?? "Ready for review"
            }
        }
        runner.onAiSummary = { [weak session] summary in
            DispatchQueue.main.async { session?.aiSummary = summary }
        }
        runner.onPendingAction = { [weak session] msg in
            DispatchQueue.main.async { session?.pendingAction = msg }
        }
        runner.onCleanupReady = { [weak self, weak session] info in
            DispatchQueue.main.async {
                session?.cleanupInfo = info
                // Capture cleanupInfo in the index so a relaunch can drive
                // cleanup of a dead-but-worktree-exists session (issue #35).
                self?.sessions.persist()
            }
        }
        runner.onGemmaTiming = { [weak session] lastActivityAt, lastGemmaAt in
            DispatchQueue.main.async {
                session?.lastPaneActivityAt = lastActivityAt
                session?.lastGemmaClassifyAt = lastGemmaAt
            }
        }
    }

    /// Build the WorkspacePair the runner consumes from a workspace + identity.
    /// Shared by `startSession` and the reattach path (issue #35).
    private func makePair(workspace: Workspace, identity: Identity) -> WorkspacePair {
        WorkspacePair(
            id: workspace.id,
            source: sourceConfig(identity: identity, surfaceId: workspace.routing.surfaceId),
            workspace: WorkspaceMapping(
                matchKey: workspace.routing.surfaceId,
                path: workspace.path,
                allReposInFolder: workspace.allReposInFolder,
                homeRepo: workspace.homeRepo,
            ),
        )
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

    // MARK: - Gates (plan / result human approval)

    enum GateDecision: String { case approve, requestChanges }

    /// Resolve a human gate (plan review or result review). Backs both the
    /// popover buttons and the `approve_gate` MCP tool, so approval reaches a
    /// session whether the user is at the desk or remote. The keystroke maps to
    /// the live `claude` picker: at the plan gate, ExitPlanMode's "1. Yes, and
    /// use auto mode" / "4. Tell Claude what to change"; at the result gate, the
    /// AskUserQuestion picker claude raises per LEMON_CONTEXT — "1. Approve —
    /// open the PR now" / "2. Request changes". No-ops with a log if the session
    /// isn't actually parked at a gate.
    func resolveGate(session: Session, decision: GateDecision, notes: String? = nil) {
        let gate = session.status
        guard gate.isGate else {
            Logger.orchestrator.info("resolveGate \(session.issue.identifier): not at a gate (\(String(describing: gate)))")
            return
        }
        let sessionName = "lemon-\(session.issue.pathSlug)"
        // The runner's planGatePhase parks on this sentinel; it's the cross-task
        // signal that the human resolved the gate (the keystroke drives claude).
        let gateSentinel = "/tmp/lemon-gate-\(session.issue.pathSlug)"
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (gate, decision) {
        case (.planReview, .approve):
            sendTmuxKeys(to: sessionName, keys: "1") // "Yes, and use auto mode"
            try? "approve".write(toFile: gateSentinel, atomically: true, encoding: .utf8)
            session.planMarkdown = nil
            session.aiSummary = "Plan approved — building"
            session.status = .executing
        case (.planReview, .requestChanges):
            sendTmuxKeys(to: sessionName, keys: "4") // "Tell Claude what to change"
            try? "changes".write(toFile: gateSentinel, atomically: true, encoding: .utf8)
            injectGateNotes(to: sessionName, notes: trimmedNotes) // #57
        case (.resultReview, .approve):
            sendTmuxKeys(to: sessionName, keys: "1") // "Approve — open the PR now"
            try? "approve".write(toFile: gateSentinel, atomically: true, encoding: .utf8)
            session.status = .executing
        case (.resultReview, .requestChanges):
            sendTmuxKeys(to: sessionName, keys: "2") // "Request changes"
            try? "changes".write(toFile: gateSentinel, atomically: true, encoding: .utf8)
            injectGateNotes(to: sessionName, notes: trimmedNotes) // #57
            session.status = .executing
        default:
            break
        }
        // Persist the post-gate status so a relaunch resumes correctly (issue #35).
        sessions.persist()
        Logger.orchestrator.info("resolveGate \(session.issue.identifier) \(gate.displayLabel) -> \(decision.rawValue)\(trimmedNotes?.isEmpty == false ? " (+notes)" : "")")
    }

    /// After selecting "request changes" in claude's picker, type the human's
    /// feedback as text + a SEPARATE Enter (never combined — the same two-step
    /// pattern the session-limit resume uses). A short delay lets claude's picker
    /// present its free-text input before we type. No-op without notes (#57).
    private func injectGateNotes(to sessionName: String, notes: String?) {
        guard let notes, !notes.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.sendTmuxText(to: sessionName, text: notes)
        }
    }

    /// Free-form "talk to claude" path (#57): type a message into the live
    /// session + a separate Enter, without resolving a gate. Drives the gate
    /// card's chat composer. No-op on empty input.
    func sendMessage(session: Session, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sendTmuxText(to: "lemon-\(session.issue.pathSlug)", text: t)
        Logger.orchestrator.info("sendMessage \(session.issue.identifier): \(t.count) chars to session")
    }

    /// Send free text then a separate Enter (two send-keys calls). Splitting the
    /// Enter is load-bearing: a combined `'<text>' Enter` can race claude's input
    /// box and drop the newline, leaving the text typed but unsent.
    private func sendTmuxText(to sessionName: String, text: String) {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        _ = runShellCommand("\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' '\(escaped)'")
        _ = runShellCommand("\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' Enter")
    }

    /// Resolve a gate by issue id/identifier — the path the MCP `approve_gate`
    /// tool and remote/comment approvals take. Returns false if no session at a gate.
    @discardableResult
    func resolveGate(idOrIdentifier: String, decision: GateDecision) -> Bool {
        let all = sessions.active + sessions.recent
        guard let session = all.first(where: {
            $0.issue.id == idOrIdentifier || $0.issue.identifier == idOrIdentifier
        }), session.status.isGate else { return false }
        resolveGate(session: session, decision: decision)
        return true
    }

    private func sendTmuxKeys(to sessionName: String, keys: String) {
        _ = runShellCommand("\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' '\(keys)' Enter")
    }

    @discardableResult
    private func runShellCommand(_ command: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", command]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
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
            // Pane quiet ~95s → the Gemma idle countdown shows "checks in 0:25" (#50).
            active1.lastPaneActivityAt = now.addingTimeInterval(-95)
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

            // Reviewing — the tall detail state: ready-for-review card + AI
            // summary + console + footer all present at once. This is the layout
            // that clipped its footer before the console was made flexible.
            let reviewing = Session(issue: IssueRef(
                id: "mock-4", identifier: "sandbox/demo#1",
                // Deliberately long → wraps to two lines, the tallest realistic
                // title. This is the case that clipped the footer in the field
                // (a 2-line title pushes the ready-for-review state past the cap).
                title: "Result/plan gate: present the review decision as a selectable A/B (+ notes, + chat) in the popover",
                description: "Add hello(name) and a test.",
                labelNames: ["🍋 Complete"], scope: .githubRepo(owner: "sandbox", repo: "demo", number: 1),
            ), startedAt: now.addingTimeInterval(-900))
            reviewing.status = .reviewing
            reviewing.prUrl = "https://github.com/sandbox/demo/pull/1"
            reviewing.aiSummary = "Session appears to be idling after completing PR #66."
            reviewing.cleanupInfo = WorktreeCleanupInfo(
                sessionPath: "/tmp/lemon-sandbox-demo-1",
                isMultiRepo: false,
                repos: [.init(name: "demo", repoPath: "/tmp/lemon-sandbox/workspace")],
                slug: "sandbox-demo-1",
            )
            for line in [
                "[lemon] starting session for sandbox/demo#1",
                "[lemon] tmux session started — join: tmux -L lemon attach -t lemon-sandbox-demo-1",
                "[lemon] 🍋 Complete detected for sandbox/demo#1",
                "[gemma] Starting work on sandbox/demo#1",
                "[lemon] posted Lemon comment c1",
                "[lemon] ready for review — worktree at /tmp/lemon-sandbox-demo-1. Click Cleanup to tear down.",
            ] {
                reviewing.appendLog(line)
            }

            // Plan gate — a proposed plan awaiting approval (the keystone state).
            let planGate = Session(issue: IssueRef(
                id: "mock-5", identifier: "sandbox/demo#2",
                title: "Add CSV export to the reports page",
                description: "Users want to export the reports table as CSV.",
                labelNames: ["🍋 Waiting"], scope: .githubRepo(owner: "sandbox", repo: "demo", number: 2),
            ), startedAt: now.addingTimeInterval(-90))
            planGate.status = .planReview
            planGate.planMarkdown = """
            # Plan: CSV export for the reports page

            ## Context
            ReportsView renders a table but offers no export. Add an "Export CSV"
            action that serializes the current rows and writes via a save panel.

            ## Changes
            1. CSVEncoder.swift (new) — encode [ReportRow] → RFC-4180 CSV
            2. ReportsView.swift — toolbar "Export CSV" button → NSSavePanel
            3. ReportsViewModel.swift — expose `rows` for the encoder

            ## Verification
            - Unit-test CSVEncoder against a known fixture (commas, quotes, newlines)
            - Manual: export, open in Numbers, confirm column alignment
            """
            planGate.aiSummary = "Plan ready — awaiting your approval"
            for line in [
                "[lemon] starting session for sandbox/demo#2",
                "[lemon] launched in plan mode — tmux: lemon-sandbox-demo-2",
                "[gemma] plan ready — holding for human approval",
                "[lemon] posted plan to sandbox/demo#2, label → 🍋 Waiting",
            ] {
                planGate.appendLog(line)
            }

            // Result gate — build done, awaiting approval to open the PR.
            let resultGate = Session(issue: IssueRef(
                id: "mock-6", identifier: "sandbox/demo#3",
                title: "Cache avatar images on the profile page",
                description: "Avatars re-fetch on every render.",
                labelNames: ["🍋 Waiting"], scope: .githubRepo(owner: "sandbox", repo: "demo", number: 3),
            ), startedAt: now.addingTimeInterval(-300))
            resultGate.status = .resultReview
            resultGate.aiSummary = "Built — 3 files changed, tests green. Ready to open the PR."
            resultGate.cleanupInfo = WorktreeCleanupInfo(
                sessionPath: "/tmp/lemon-sandbox-demo-3", isMultiRepo: false,
                repos: [.init(name: "demo", repoPath: "/tmp/lemon-sandbox/workspace")],
                slug: "sandbox-demo-3",
            )
            for line in [
                "[lemon] plan approved — building",
                "[gemma] implementing avatar cache",
                "✓ tests passed",
                "[lemon] build ready for review — awaiting approval to open PR",
            ] {
                resultGate.appendLog(line)
            }

            // Queued — triggered but over the concurrency limit, awaiting a free
            // slot (#46). Renders a "Queued" row in the list.
            let queued = Session(issue: IssueRef(
                id: "mock-7", identifier: "sandbox/demo#4",
                title: "Add keyboard shortcuts to the command palette",
                description: "Power users want hotkeys for the palette.",
                labelNames: ["🍋 Lemon"], scope: .githubRepo(owner: "sandbox", repo: "demo", number: 4),
            ), startedAt: now.addingTimeInterval(-30))
            queued.status = .queued
            queued.aiSummary = "Queued — waiting for a free slot"

            sessions.add(active1)
            sessions.add(active2)
            sessions.add(planGate)
            sessions.add(resultGate)
            sessions.add(queued)
            sessions.add(reviewing)
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
