import Foundation
import SwiftUI

@Observable
final class SessionStore {
    var active: [Session] = []
    var recent: [Session] = []  // last 20 completed

    private let maxRecent = 20

    func add(_ session: Session) {
        active.append(session)
    }

    // Idempotent: called from both the runner's natural completion path and
    // Orchestrator.stopSession. Without the guard, a stop racing with a
    // natural finish duplicates the session in `recent`.
    func finish(_ session: Session) {
        let wasActive = active.contains { $0.id == session.id }
        active.removeAll { $0.id == session.id }
        guard wasActive || !recent.contains(where: { $0.id == session.id }) else { return }
        if session.endedAt == nil { session.endedAt = Date() }
        recent.insert(session, at: 0)
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
    }

    // Returns true if we're already tracking this issue (by IssueRef.id or
    // its source-namespaced tracking key — see isTrackingRef).
    // Failed sessions are excluded so users can retry by re-adding the 🍋 label.
    func isTracking(issueId: String) -> Bool {
        active.contains { $0.issue.id == issueId } ||
        recent.contains { $0.issue.id == issueId && $0.status != .failed }
    }

    // Preferred check post-multi-source — uses the source-namespaced key so
    // a Linear node id and a GitHub `owner/repo#n` can't collide.
    func isTracking(ref: IssueRef) -> Bool {
        let key = ref.trackingKey
        return active.contains { $0.issue.trackingKey == key } ||
               recent.contains { $0.issue.trackingKey == key && $0.status != .failed }
    }
}
