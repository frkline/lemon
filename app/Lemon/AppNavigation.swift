import Foundation

@Observable
@MainActor
final class AppNavigation {
    var selectedSession: Session?
    var showingSettings = false
    var showingWorkspaceEditor = false

    func showDetail(_ session: Session) {
        selectedSession = session
        showingSettings = false
        showingWorkspaceEditor = false
    }
    func showSettings() {
        showingSettings = true
        showingWorkspaceEditor = false
        selectedSession = nil
    }
    func showWorkspaceEditor() {
        // Logically nested in Settings — keep showingSettings true so Back
        // returns to Settings, not the list.
        showingSettings = true
        showingWorkspaceEditor = true
        selectedSession = nil
    }
    func dismissWorkspaceEditor() {
        showingWorkspaceEditor = false
    }
    func showList() {
        selectedSession = nil
        showingSettings = false
        showingWorkspaceEditor = false
    }
}
