import Foundation

@Observable
@MainActor
final class AppNavigation {
    var selectedSession: Session?
    var showingSettings = false

    /// Editor stack — focused single-thing edit panes pushed on top of
    /// Settings. `editingIdentity` / `editingWorkspace` hold a UUID for an
    /// existing record, or `IdentityDraft` / `WorkspaceDraft` for an unsaved
    /// new one. The PopoverView checks these in dispatch order.
    var editingIdentity: IdentityEditorTarget?
    var editingWorkspace: WorkspaceEditorTarget?

    /// Back-compat — older callers can still flip this; PopoverView treats
    /// it as a synonym for "show the workspace list in Settings".
    var showingWorkspaceEditor: Bool {
        get { editingWorkspace != nil }
        set { if !newValue { editingWorkspace = nil } }
    }

    enum IdentityEditorTarget: Hashable {
        case existing(UUID)
        case new(IdentityKind)
    }

    enum WorkspaceEditorTarget: Hashable {
        case existing(UUID)
        case new
    }

    func showDetail(_ session: Session) {
        selectedSession = session
        showingSettings = false
        editingIdentity = nil
        editingWorkspace = nil
    }

    func showSettings() {
        showingSettings = true
        editingIdentity = nil
        editingWorkspace = nil
        selectedSession = nil
    }

    func editIdentity(_ id: UUID) {
        showingSettings = true // editor is nested in Settings — Back returns there
        selectedSession = nil
        editingWorkspace = nil
        editingIdentity = .existing(id)
    }

    func addIdentity(kind: IdentityKind) {
        showingSettings = true
        selectedSession = nil
        editingWorkspace = nil
        editingIdentity = .new(kind)
    }

    func editWorkspace(_ id: UUID) {
        showingSettings = true
        selectedSession = nil
        editingIdentity = nil
        editingWorkspace = .existing(id)
    }

    func addWorkspace() {
        showingSettings = true
        selectedSession = nil
        editingIdentity = nil
        editingWorkspace = .new
    }

    /// Pop one editor level — returns to Settings if any editor was open;
    /// from Settings, Back goes to the list.
    func popEditor() {
        if editingIdentity != nil { editingIdentity = nil; return }
        if editingWorkspace != nil { editingWorkspace = nil; return }
    }

    /// Back-compat for the existing call sites; keep the same semantics.
    func showWorkspaceEditor() {
        addWorkspace()
    }

    func dismissWorkspaceEditor() {
        editingWorkspace = nil
    }

    func showList() {
        selectedSession = nil
        showingSettings = false
        editingIdentity = nil
        editingWorkspace = nil
    }
}
