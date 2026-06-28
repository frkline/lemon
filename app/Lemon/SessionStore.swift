import Foundation
import SwiftUI

@Observable
final class SessionStore {
    var active: [Session] = []
    var recent: [Session] = [] // last 20 completed

    private let maxRecent = 20

    func add(_ session: Session) {
        active.append(session)
        persist()
    }

    // Idempotent: called from both the runner's natural completion path and
    // Orchestrator.stopSession. Without the guard, a stop racing with a
    // natural finish duplicates the session in `recent`.
    func finish(_ session: Session) {
        let wasActive = active.contains { $0.id == session.id }
        active.removeAll { $0.id == session.id }
        guard wasActive || !recent.contains(where: { $0.id == session.id }) else {
            persist()
            return
        }
        if session.endedAt == nil { session.endedAt = Date() }
        recent.insert(session, at: 0)
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
        persist()
    }

    /// The value-type projection of the active sessions for the persisted index
    /// (issue #35). Only non-terminal sessions carrying a `workspaceId` are
    /// included (reattach needs it to rebuild the WorkspacePair); terminal and
    /// mock/smoke sessions are dropped. Pure — unit-testable without the Keychain.
    func snapshot() -> [PersistedSession] {
        active.compactMap { s in
            guard let wsId = s.workspaceId, !s.status.isTerminal else { return nil }
            let slug = s.issue.pathSlug
            return PersistedSession(
                issue: s.issue,
                workspaceId: wsId,
                slug: slug,
                branch: s.branch ?? "lemon/\(slug)",
                status: s.status,
                retrigger: s.retrigger,
                startedAt: s.startedAt,
                cleanupInfo: s.cleanupInfo,
            )
        }
    }

    /// Write `snapshot()` to the persisted index so a relaunch can reattach to
    /// still-running tmux sessions. Idempotent — safe to call after any mutation.
    func persist() {
        KeychainStore.shared.sessionIndex = snapshot()
    }

    /// Returns true if we're already tracking this issue (by IssueRef.id or
    /// its source-namespaced tracking key — see isTrackingRef).
    /// Failed sessions are excluded so users can retry by re-adding the 🍋 label.
    func isTracking(issueId: String) -> Bool {
        active.contains { $0.issue.id == issueId } ||
            recent.contains { $0.issue.id == issueId && $0.status != .failed }
    }

    /// Preferred check post-multi-source — uses the source-namespaced key so
    /// a Linear node id and a GitHub `owner/repo#n` can't collide.
    func isTracking(ref: IssueRef) -> Bool {
        let key = ref.trackingKey
        return active.contains { $0.issue.trackingKey == key } ||
            recent.contains { $0.issue.trackingKey == key && $0.status != .failed }
    }
}
