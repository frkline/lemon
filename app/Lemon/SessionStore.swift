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

    func finish(_ session: Session) {
        active.removeAll { $0.id == session.id }
        session.endedAt = Date()
        recent.insert(session, at: 0)
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
    }

    // Returns true if we're already tracking this Linear issue ID.
    // Failed sessions are excluded so users can retry by re-adding the 🍋 label.
    func isTracking(issueId: String) -> Bool {
        active.contains { $0.issue.id == issueId } ||
        recent.contains { $0.issue.id == issueId && $0.status != .failed }
    }
}
