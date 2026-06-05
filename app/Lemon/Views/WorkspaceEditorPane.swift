import SwiftUI
import AppKit

/// Slide-in pane for adding or editing a single Workspace.
/// Pushed via `AppNavigation.editWorkspace(_:)` / `addWorkspace()`.
struct WorkspaceEditorPane: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav

    let target: AppNavigation.WorkspaceEditorTarget

    @State private var path: String = ""
    @State private var allReposInFolder: Bool = false
    @State private var homeRepo: String = ""
    @State private var identityId: UUID? = nil
    @State private var surfaceId: String = ""
    @State private var deleteArmed = false
    @State private var deleteTask: Task<Void, Never>?
    @State private var existing: Workspace?
    @State private var suggestion: PathSuggestion? = nil

    struct PathSuggestion: Equatable {
        let identityId: UUID
        let surfaceKey: String
        let label: String
        let detail: String   // e.g. "GitHub · frkline/lemon — detected from .git/config"
    }

    private var identities: [Identity] { KeychainStore.shared.identities }

    private var selectedIdentity: Identity? {
        guard let id = identityId else { return nil }
        return identities.first { $0.id == id }
    }

    private var surfaces: [Surface] { selectedIdentity?.knownSurfaces ?? [] }

    private var isNew: Bool {
        if case .new = target { return true } else { return false }
    }

    private var canSave: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard identityId != nil else { return false }
        let trimmedSurface = surfaceId.trimmingCharacters(in: .whitespaces)
        return !trimmedSurface.isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                eyebrowHeader
                if identities.isEmpty {
                    noIdentitiesCard
                } else {
                    pathSection
                    identitySection
                    surfaceSection
                    folderOptions
                }
                Spacer(minLength: 4)
                actionsRow
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(LD.consoleBackground.opacity(0.02))
        .onAppear { hydrate() }
    }

    // MARK: - Header

    private var eyebrowHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isNew ? "NEW WORKSPACE" : "WORKSPACE")
                .font(.system(size: 9, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(LD.lemon)
            Text(isNew ? "Map a folder to a tracker" : (existing.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Edit"))
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            Text("Pick where the work happens on disk, then route its issues through one of your connected identities.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Path

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("LOCAL PATH")
                    .font(.system(size: 8, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    pickFolder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("Browse…")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                TextField(allReposInFolder ? "/path/to/projects" : "/path/to/repo", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .onChange(of: path) { _, newValue in
                analyzePath(newValue)
            }
            if let suggestion {
                suggestionChip(suggestion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func suggestionChip(_ s: PathSuggestion) -> some View {
        Button {
            withAnimation(LD.snappy) {
                identityId = s.identityId
                surfaceId = s.surfaceKey
                suggestion = nil
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.lemon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(s.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("Use")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LD.lemon)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: LD.r10)
                    .fill(LD.lemon.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LD.r10)
                    .strokeBorder(LD.lemon.opacity(0.28), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Identity picker

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROUTE THROUGH")
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                ForEach(identities) { ident in
                    identityChoiceRow(ident)
                }
                Button {
                    nav.addIdentity(kind: .linear)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Connect another identity")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(LD.lemon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: LD.r10)
                            .strokeBorder(LD.lemon.opacity(0.30),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func identityChoiceRow(_ ident: Identity) -> some View {
        let isSelected = identityId == ident.id
        return Button {
            withAnimation(LD.snappy) {
                identityId = ident.id
                // Reset surface if the previous selection isn't available here.
                if !ident.knownSurfaces.contains(where: { $0.id == surfaceId }) {
                    surfaceId = ""
                }
            }
        } label: {
            HStack(spacing: 10) {
                SourceGlyph(source: ident.kind.issueSource, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ident.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        if !ident.handle.isEmpty {
                            Text("@\(ident.handle)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if let host = ident.host, !host.isEmpty {
                            Text("· \(host)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        Text("· \(ident.knownSurfaces.count) surface\(ident.knownSurfaces.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? AnyShapeStyle(LD.lemon) : AnyShapeStyle(.quaternary))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LD.r10)
                    .fill(isSelected ? LD.lemon.opacity(0.07) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LD.r10)
                    .strokeBorder(isSelected ? LD.lemon.opacity(0.30) : Color.primary.opacity(0.08),
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Surface picker

    @ViewBuilder
    private var surfaceSection: some View {
        if let ident = selectedIdentity {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(ident.kind == .linear ? "TEAM" : "REPO")
                        .font(.system(size: 8, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await orchestrator.refreshSurfaces(identityId: ident.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                            Text("Refresh")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-fetch surfaces from \(ident.kind.displayName)")
                }
                if ident.knownSurfaces.isEmpty {
                    surfaceFreeText
                    Text("No surfaces cached yet. Re-verify the identity to fetch them, or type a key here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                } else {
                    Menu {
                        ForEach(ident.knownSurfaces) { s in
                            Button(action: { surfaceId = s.id }) {
                                Text(surfaceMenuLabel(for: s))
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(surfaceLabelText(for: ident))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: LD.r10)
                                .fill(.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LD.r10)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    Text("Pick from \(ident.knownSurfaces.count) known surface\(ident.knownSurfaces.count == 1 ? "" : "s") — or type a custom key below.")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    surfaceFreeText
                }
            }
        } else {
            EmptyView()
        }
    }

    private var surfaceFreeText: some View {
        TextField(
            selectedIdentity?.kind == .github ? "owner/repo" : "Team key (e.g. HRP)",
            text: $surfaceId
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func surfaceLabelText(for ident: Identity) -> String {
        if let s = ident.knownSurfaces.first(where: { $0.id == surfaceId }) {
            return surfaceMenuLabel(for: s)
        }
        if !surfaceId.isEmpty {
            return surfaceId
        }
        return ident.kind == .github ? "Pick a repo…" : "Pick a team…"
    }

    /// When a surface's key and displayName are the same string (Linear teams
    /// whose key matches the team name; GitHub repos where id == owner/repo),
    /// render once. Otherwise "KEY — Name".
    private func surfaceMenuLabel(for s: Surface) -> String {
        let same = s.key.caseInsensitiveCompare(s.displayName) == .orderedSame
        return same ? s.displayName : "\(s.key) — \(s.displayName)"
    }

    // MARK: - Folder options

    private var folderOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $allReposInFolder) {
                Text("All repos in this folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            if allReposInFolder {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOME SUBDIR")
                        .font(.system(size: 8, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(.tertiary)
                    TextField("e.g. memory", text: $homeRepo)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                    Text("Optional — where Claude launches inside the folder. Put a LEMON.md there with team-specific guidance.")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(LD.smooth, value: allReposInFolder)
    }

    // MARK: - No identities yet

    private var noIdentitiesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(LD.lemon)
                Text("No identities connected yet.")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Connect a tracker first — Lemon needs to know where this workspace's issues live before it can route them.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    nav.addIdentity(kind: .linear)
                } label: {
                    HStack(spacing: 5) {
                        SourceGlyph(source: .linear, size: 8)
                        Text("Connect Linear")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(LD.lemon, in: Capsule())
                    .foregroundStyle(LD.citrus)
                }
                .buttonStyle(.plain)
                Button {
                    nav.addIdentity(kind: .github)
                } label: {
                    HStack(spacing: 5) {
                        SourceGlyph(source: .github, size: 8)
                        Text("Connect GitHub")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(LD.statusDone.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(LD.statusDone.opacity(0.40), lineWidth: 0.5))
                    .foregroundStyle(LD.statusDone)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button("Cancel") { nav.popEditor() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            if !isNew {
                Button { handleDelete() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: deleteArmed ? "trash.fill" : "trash")
                            .font(.system(size: 11))
                        Text(deleteArmed ? "Confirm delete" : "Delete workspace")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(deleteArmed ? .white : LD.coral)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(deleteArmed ? LD.coral : LD.coral.opacity(0.12)))
                    .animation(LD.snappy, value: deleteArmed)
                }
                .buttonStyle(.plain)
            }
            Button("Save") {
                save()
                nav.popEditor()
            }
            .buttonStyle(LemonButtonStyle())
            .disabled(!canSave)
        }
    }

    // MARK: - Behaviors

    private func hydrate() {
        switch target {
        case .new:
            if let firstIdentity = identities.first {
                identityId = firstIdentity.id
            }
        case .existing(let id):
            if let ws = KeychainStore.shared.workspaces.first(where: { $0.id == id }) {
                existing = ws
                path = ws.path
                allReposInFolder = ws.allReposInFolder
                homeRepo = ws.homeRepo
                identityId = ws.routing.identityId
                surfaceId = ws.routing.surfaceId
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Choose workspace folder"
        let cwd: URL = path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
            : URL(fileURLWithPath: path)
        panel.directoryURL = cwd
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func analyzePath(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            withAnimation(LD.smooth) { suggestion = nil }
            return
        }
        suggestion = WorkspaceAnalyzer.suggest(
            for: trimmed,
            identities: identities
        )
    }

    private func save() {
        let keychain = KeychainStore.shared
        guard let identityId else { return }
        let trimmedSurface = surfaceId.trimmingCharacters(in: .whitespaces)

        var working: Workspace
        if let existing {
            working = existing
        } else {
            working = Workspace(
                path: "", allReposInFolder: false, homeRepo: "",
                routing: Routing(identityId: identityId, surfaceId: trimmedSurface)
            )
        }
        working.path = path.trimmingCharacters(in: .whitespaces)
        working.allReposInFolder = allReposInFolder
        working.homeRepo = homeRepo.trimmingCharacters(in: .whitespaces)
        working.routing = Routing(identityId: identityId, surfaceId: trimmedSurface)

        var all = keychain.workspaces
        if let idx = all.firstIndex(where: { $0.id == working.id }) {
            all[idx] = working
        } else {
            all.append(working)
        }
        keychain.workspaces = all
    }

    private func handleDelete() {
        if deleteArmed {
            deleteTask?.cancel()
            performDelete()
            return
        }
        deleteArmed = true
        deleteTask?.cancel()
        deleteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                withAnimation(LD.smooth) { deleteArmed = false }
            }
        }
    }

    private func performDelete() {
        guard let ws = existing else { return }
        let keychain = KeychainStore.shared
        keychain.workspaces = keychain.workspaces.filter { $0.id != ws.id }
        nav.popEditor()
    }
}
