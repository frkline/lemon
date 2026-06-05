import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let lemonRerunSetup = Notification.Name("com.lemon.rerunSetup")
}

struct SettingsView: View {
    @Environment(Orchestrator.self) private var orchestrator

    @State private var linearApiKey = ""
    @State private var githubToken = ""
    @State private var githubUser = ""
    @State private var pairs: [WorkspacePair] = []
    @State private var saved = false
    @State private var editingWorkspace = false
    @State private var ghVerifyState: VerifyState = .idle
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var aiTestState: AITestState = .idle

    // MCP server state — mirrors UserDefaults but lets the toggle drive
    // start/stop on change. The port text field is also a UserDefault.
    @AppStorage("lemon-mcp-enabled") private var mcpEnabled = false
    @AppStorage("lemon-mcp-port")    private var mcpPort   = Int(LemonMCPServer.defaultPort)
    @State private var mcpCopyHint: String?

    enum AITestState: Equatable {
        case idle
        case starting      // launching SwiftLM subprocess + waiting for /health
        case classifying   // server up, running classify()
        case passed(state: String, summary: String, elapsedSec: Int)
        case failed(String)
    }

    enum VerifyState: Equatable {
        case idle
        case verifying
        case ok(login: String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    generalSection
                    identitiesPanel
                    workspacesPanel
                    localAISection
                    mcpSection
                }
                .padding(24)
                .padding(.bottom, 4)
            }
            Divider()
            settingsFooter
        }
        .frame(minHeight: 780)
        .onAppear { load() }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("General")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    configGlyph("power", tint: launchAtLogin ? LD.statusDone : .secondary.opacity(0.6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        Text("Start Lemon automatically when you log in.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                            }
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            .lemonGlass(.resting)
        }
    }

    // MARK: - Identities panel (top-level credentials)

    @Environment(AppNavigation.self) private var nav

    private var allIdentities: [Identity] { KeychainStore.shared.identities }
    private var allWorkspaces: [Workspace] { KeychainStore.shared.workspaces }

    @State private var addIdentityPickerShown: Bool = false

    private var identitiesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("Identities")
                identityCountChip
                Spacer()
                // Button + popover instead of Menu so the addAffordance
                // capsule background renders exactly the same as the
                // Workspaces "+ Add" — Menu.borderlessButton was
                // stripping the .background() modifier and the two pills
                // read inconsistent. Same affordance, same chrome.
                Button {
                    addIdentityPickerShown = true
                } label: {
                    addAffordance
                }
                .buttonStyle(.plain)
                .popover(isPresented: $addIdentityPickerShown, arrowEdge: .top) {
                    addIdentityPopoverContent
                }
            }
            if allIdentities.isEmpty {
                identitiesEmptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(allIdentities) { ident in
                        identityRow(ident)
                        if ident.id != allIdentities.last?.id {
                            Divider().padding(.leading, 56).opacity(0.6)
                        }
                    }
                }
                .lemonGlass(.resting)
            }
        }
    }

    /// Tiny popover surface for "Add identity" — one button per source.
    /// Lives behind the Identities section's "+ Add" chip.
    private var addIdentityPopoverContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            popoverRow(label: "Linear", systemImage: "circle.hexagongrid.fill") {
                addIdentityPickerShown = false
                nav.addIdentity(kind: .linear)
            }
            popoverRow(label: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                addIdentityPickerShown = false
                nav.addIdentity(kind: .github)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
    }

    private func popoverRow(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Editorial Add chip — shared by Identities and Workspaces section
    /// headers so the affordance reads as the same control regardless of
    /// whether it's a menu or a button underneath.
    private var addAffordance: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
            Text("Add")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .lemonGlassCapsule(.resting)
    }

    private var identityCountChip: some View {
        Text("\(allIdentities.count)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.primary.opacity(0.05)))
    }

    private var identitiesEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No identities connected.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Connect Linear, GitHub, or a GitHub Enterprise instance to start routing workspaces.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonGlass(.resting)
    }

    private func identityRow(_ ident: Identity) -> some View {
        Button {
            nav.editIdentity(ident.id)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    SourceGlyph(source: ident.kind.issueSource, size: 9)
                }
                .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ident.label.isEmpty ? ident.kind.displayName : ident.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !ident.handle.isEmpty {
                            Text("@\(ident.handle)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.quaternary)
                    }
                    HStack(spacing: 6) {
                        if let host = ident.host, !host.isEmpty {
                            Text(host)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                        }
                        Text("\(ident.knownSurfaces.count) surface\(ident.knownSurfaces.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if let fetched = ident.surfacesFetchedAt {
                            Text("· refreshed \(relative(fetched))")
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Workspaces panel (new design)

    private var workspacesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("Workspaces")
                pairCountChip
                Spacer()
                Button {
                    nav.addWorkspace()
                } label: {
                    addAffordance
                }
                .buttonStyle(.plain)
            }
            if allWorkspaces.isEmpty {
                workspacesEmptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(allWorkspaces) { ws in
                        workspaceListRow(ws)
                        if ws.id != allWorkspaces.last?.id {
                            Divider().padding(.leading, 56).opacity(0.6)
                        }
                    }
                }
                .lemonGlass(.resting)
            }
        }
    }

    private var workspacesEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workspaces yet.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add a folder + routing to start polling. Lemon needs at least one connected identity to route through.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonGlass(.resting)
    }

    private func workspaceListRow(_ ws: Workspace) -> some View {
        let keychain = KeychainStore.shared
        let ident = keychain.identity(for: ws)
        let surface = keychain.surface(for: ws)
        let status = orchestrator.workspaceStatus(for: ws.id)
        let displayName = URL(fileURLWithPath: ws.path).lastPathComponent
        return Button {
            nav.editWorkspace(ws.id)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    if let kind = ident?.kind {
                        SourceGlyph(source: kind.issueSource, size: 9)
                    } else {
                        Text("?")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(LD.coral)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(LD.coral.opacity(0.10)))
                            .overlay(Capsule().strokeBorder(LD.coral.opacity(0.30), lineWidth: 0.5))
                    }
                    Image(systemName: ws.allReposInFolder ? "folder.fill.badge.plus" : "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName.isEmpty ? "Unnamed workspace" : displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        if ws.allReposInFolder {
                            editorialChip("folder", tint: .secondary)
                        }
                        if ws.allReposInFolder && !ws.homeRepo.isEmpty {
                            editorialChip("→ \(ws.homeRepo)/", tint: LD.lemon, mono: true)
                        }
                        Spacer(minLength: 0)
                        workspaceLiveChip(status: status, ident: ident)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.quaternary)
                    }
                    HStack(spacing: 6) {
                        if let ident, let surface {
                            Text("\(ident.label) · \(surface.key)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        } else if let ident {
                            HStack(spacing: 4) {
                                Text("\(ident.label) · \(ws.routing.surfaceId)")
                                    .font(.system(size: 10, design: .monospaced))
                                Text("· unknown surface")
                                    .font(.system(size: 9))
                                    .foregroundStyle(LD.coral)
                            }
                            .foregroundStyle(.tertiary)
                        } else {
                            Text("Routing missing — identity deleted")
                                .font(.system(size: 10))
                                .foregroundStyle(LD.coral)
                        }
                    }
                    Text(ws.path.isEmpty ? "(no path set)" : ws.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let line = status?.subtitle {
                        Text(line)
                            .font(.system(size: 9))
                            .foregroundStyle(status?.error == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(LD.coral))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func workspaceLiveChip(status: WorkspaceStatus?, ident: Identity?) -> some View {
        if ident == nil {
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 4, height: 4)
                Text("orphan")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        } else if let status, status.error != nil {
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 4, height: 4)
                Text("err")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        } else if status?.lastPolledAt != nil {
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 4, height: 4)
                Text("live")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.statusDone)
            }
        } else {
            Text("idle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }

    private var githubSection: some View {
        let connectedDetail: String? = {
            if case .ok(let login) = ghVerifyState { return "@\(login)" }
            if !githubUser.isEmpty { return "@\(githubUser)" }
            return nil
        }()
        return sourceCredentialSection(
            source: .github,
            heading: "GitHub",
            subhead: "Personal Access Token",
            placeholder: "ghp_… (scope: repo)",
            connected: !githubToken.isEmpty,
            connectedDetail: connectedDetail,
            keyBinding: $githubToken,
            verifyAction: { Task { await verifyGitHubToken() } },
            verifyState: ghVerifyState
        )
    }

    // Shared editorial credential card. Eyebrow + serif-leaning subhead,
    // monospace token field, optional Verify action with inline state.
    private func sourceCredentialSection(
        source: IssueSource,
        heading: String,
        subhead: String,
        placeholder: String,
        connected: Bool,
        connectedDetail: String?,
        keyBinding: Binding<String>,
        verifyAction: (() -> Void)?,
        verifyState: VerifyState?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(heading.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.tertiary)
                SourceGlyph(source: source, size: 8)
                Spacer()
                if connected { connectedBadge }
                if let detail = connectedDetail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(subhead)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField(placeholder, text: keyBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                if let verifyAction {
                    HStack(spacing: 8) {
                        Button("Verify") { verifyAction() }
                            .buttonStyle(GhostButtonStyle())
                            .disabled(keyBinding.wrappedValue.isEmpty || verifyState == .verifying)
                        verifyStateRow(verifyState)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .lemonGlass(.resting)
            .overlay(
                RoundedRectangle(cornerRadius: LD.r10)
                    .strokeBorder(source.accent.opacity(connected ? 0.20 : 0.08), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func verifyStateRow(_ state: VerifyState?) -> some View {
        switch state {
        case .verifying:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("verifying…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        case .ok(let login):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.statusDone)
                Text("@\(login)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LD.statusDone)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("Workspace pairs")
                pairCountChip
                Spacer()
                Button("Edit") { editingWorkspace = true }
                    .buttonStyle(GhostButtonStyle())
            }
            if pairs.isEmpty {
                HStack(spacing: 12) {
                    iconBox("folder.fill", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No pairs configured")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Text("Add one in the editor — Linear team or GitHub owner/repo.")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lemonGlass(.resting)
            } else {
                VStack(spacing: 0) {
                    ForEach(pairs) { pair in
                        pairRow(pair)
                        if pair.id != pairs.last?.id {
                            Divider().padding(.leading, 56).opacity(0.6)
                        }
                    }
                }
                .lemonGlass(.resting)
            }
        }
        .sheet(isPresented: $editingWorkspace) {
            WorkspaceEditorView(pairs: $pairs, onDone: { editingWorkspace = false })
        }
    }

    // Tiny "N · 10" pair count, set in monospace for editorial restraint.
    private var pairCountChip: some View {
        HStack(spacing: 3) {
            Text("\(pairs.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(pairs.count >= KeychainStore.maxPairs ? LD.coral : .secondary)
            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
            Text("\(KeychainStore.maxPairs)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.primary.opacity(0.05)))
    }

    private func pairRow(_ pair: WorkspacePair) -> some View {
        let pairStatus = orchestrator.pairStatus(for: pair.id)
        return HStack(spacing: 12) {
            // Source ornament: a hairline-bordered glyph stack. The folder
            // glyph below it whispers "this lives on disk" without competing
            // with the source identity.
            VStack(spacing: 4) {
                SourceGlyph(source: pair.source.source, size: 9)
                Image(systemName: pair.workspace.allReposInFolder
                                    ? "folder.fill.badge.plus"
                                    : "folder.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pair.workspace.matchKey.isEmpty ? "—" : pair.workspace.matchKey)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    if pair.workspace.allReposInFolder {
                        editorialChip("folder", tint: .secondary)
                    }
                    if pair.workspace.allReposInFolder && !pair.workspace.homeRepo.isEmpty {
                        editorialChip("→ \(pair.workspace.homeRepo)/", tint: LD.lemon, mono: true)
                    }
                    Spacer()
                    pairConnectionChip(pair: pair, status: pairStatus)
                }
                Text(pair.workspace.path.isEmpty ? "(no path set)" : pair.workspace.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = pairStatus?.subtitle {
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(pairStatus?.error == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(LD.coral))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // Editorial chip — kerned uppercase or monospace, hairline border for restraint.
    private func editorialChip(_ text: String, tint: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(.system(
                size: 9,
                weight: mono ? .medium : .semibold,
                design: mono ? .monospaced : .default
            ))
            .kerning(mono ? 0 : 0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.5))
    }

    @ViewBuilder
    private func pairConnectionChip(pair: WorkspacePair, status: PairStatus?) -> some View {
        if let status, status.error != nil {
            // Coral dot — error state needs attention.
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 4, height: 4)
                Text("err")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        } else if status?.lastPolledAt != nil {
            // Quiet green dot — last poll succeeded.
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 4, height: 4)
                Text("live")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.statusDone)
            }
        } else {
            // Pre-first-poll: hush.
            Text("idle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Local AI

    private var localAISection: some View {
        let k = KeychainStore.shared
        let modelPath = k.modelPath
        let swiftLMPath = k.swiftLMPath
        let modelReady = !modelPath.isEmpty &&
            FileManager.default.fileExists(atPath: modelPath + "/config.json")
        let swiftLMReady = !swiftLMPath.isEmpty &&
            FileManager.default.isExecutableFile(atPath: swiftLMPath)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("Local AI")
                Spacer()
                Text("SwiftLM \(LocalAI.swiftLMBuild)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LD.citrus)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(LD.lemon.opacity(0.18), in: RoundedRectangle(cornerRadius: LD.r3))
            }

            VStack(spacing: 0) {
                aiRow(icon: "cpu", label: "Gemma model",
                      path: modelPath.isEmpty ? "Not configured" : modelPath,
                      ready: modelReady)
                Divider().padding(.leading, 54)
                aiRow(icon: "terminal.fill", label: "SwiftLM runner",
                      path: swiftLMPath.isEmpty ? "Not configured" : swiftLMPath,
                      ready: swiftLMReady)
                if modelReady && swiftLMReady {
                    Divider().padding(.leading, 54)
                    aiTestRow
                }
            }
            .lemonGlass(.resting)
        }
    }

    // MARK: - MCP server section
    //
    // Opt-in HTTP+JSON-RPC server that exposes Lemon's session state and
    // control surface to Claude Code (or any MCP-speaking client). Localhost
    // bind only — anyone on this Mac who can reach loopback can hit it.
    // Same threat model as Lemon's running process; we don't add a bearer
    // token to keep setup friction at zero.
    private var mcpSection: some View {
        let running = LemonMCPServer.shared.isRunning
        let endpoint = "http://127.0.0.1:\(mcpPort)/mcp"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("MCP Server")
                Spacer()
                Text("Claude Code · recursive mode")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LD.citrus)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(LD.lemon.opacity(0.18), in: RoundedRectangle(cornerRadius: LD.r3))
            }

            VStack(spacing: 0) {
                // Toggle row
                HStack(spacing: 12) {
                    configGlyph("network", tint: running ? LD.statusDone : .secondary.opacity(0.6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Expose to Claude Code")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            mcpRunningChip(running: running)
                        }
                        Text(running
                             ? endpoint
                             : "Flip on to let another Claude observe and steer Lemon sessions.")
                            .font(.system(size: 10, design: running ? .monospaced : .default))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    Toggle("", isOn: $mcpEnabled)
                        .labelsHidden()
                        .onChange(of: mcpEnabled) { _, enabled in
                            applyMcpToggle(enabled: enabled)
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)

                if mcpEnabled {
                    Divider().padding(.leading, 56).opacity(0.6)

                    // Port row
                    HStack(spacing: 12) {
                        configGlyph("number", tint: .secondary.opacity(0.7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Port")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Default 8765 — toggle off/on to apply changes.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        TextField("8765", value: $mcpPort, format: .number.grouping(.never))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)

                    Divider().padding(.leading, 56).opacity(0.6)

                    // Copy config row
                    HStack(spacing: 12) {
                        configGlyph("doc.on.clipboard", tint: .secondary.opacity(0.7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Add to Claude Code")
                                .font(.system(size: 12, weight: .semibold))
                            if let hint = mcpCopyHint {
                                Text(hint)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(LD.statusDone)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else {
                                Text("Copies a JSON snippet for ~/.claude.json")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Copy", action: copyMcpConfig)
                            .buttonStyle(GhostButtonStyle())
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .lemonGlass(.resting)
        }
    }

    private func applyMcpToggle(enabled: Bool) {
        let port = UInt16(exactly: max(1024, min(mcpPort, 65535))) ?? LemonMCPServer.defaultPort
        if enabled {
            do {
                try LemonMCPServer.shared.start(port: port)
                LemonMCPTools.registerAll(server: LemonMCPServer.shared, orchestrator: orchestrator)
            } catch {
                mcpEnabled = false  // bind failed — reflect the actual state
                mcpCopyHint = "Failed to start: \(error.localizedDescription)"
            }
        } else {
            LemonMCPServer.shared.stop()
            mcpCopyHint = nil
        }
    }

    private func copyMcpConfig() {
        let snippet = """
        {
          "mcpServers": {
            "lemon": {
              "type": "http",
              "url": "http://127.0.0.1:\(mcpPort)/mcp"
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        mcpCopyHint = "Copied — paste into ~/.claude.json"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if mcpCopyHint == "Copied — paste into ~/.claude.json" { mcpCopyHint = nil }
        }
    }

    private var aiTestRow: some View {
        HStack(spacing: 12) {
            configGlyph("wand.and.stars", tint: aiTestTint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Self-test")
                        .font(.system(size: 12, weight: .semibold))
                    aiTestBadge
                }
                // Failed states often carry a multi-line SwiftLM log tail —
                // give them more vertical room and let the user scroll inside.
                if case .failed = aiTestState {
                    ScrollView {
                        Text(aiTestDetail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } else {
                    Text(aiTestDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            switch aiTestState {
            case .starting, .classifying:
                ProgressView().scaleEffect(0.6).frame(width: 18, height: 18)
            default:
                Button("Run", action: runAITest)
                    .buttonStyle(LemonButtonStyle())
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var aiTestTint: Color {
        switch aiTestState {
        case .idle:                return .secondary
        case .starting, .classifying: return LD.lemon
        case .passed:              return LD.statusDone
        case .failed:              return LD.coral
        }
    }

    @ViewBuilder
    private var aiTestBadge: some View {
        switch aiTestState {
        case .idle: EmptyView()
        case .starting:
            Text("BOOTING SWIFTLM").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.lemon)
        case .classifying:
            Text("CLASSIFYING").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.lemon)
        case .passed:
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 5, height: 5)
                Text("Passed").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.statusDone)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(LD.statusDone.opacity(0.10), in: Capsule())
        case .failed:
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 5, height: 5)
                Text("Failed").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.coral)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(LD.coral.opacity(0.10), in: Capsule())
        }
    }

    private var aiTestDetail: String {
        switch aiTestState {
        case .idle: return "Boot SwiftLM + run one classify() call. ~60-90 s for first run."
        case .starting: return "Loading model into GPU — first launch can take 60-90 s."
        case .classifying: return "Sent test prompt; waiting for Gemma to respond…"
        case .passed(let s, let summary, let secs): return "state=\(s) · summary=\(summary) · \(secs) s"
        case .failed(let msg): return msg
        }
    }

    private func runAITest() {
        aiTestState = .starting
        let startedAt = Date()
        Task {
            await LocalLLM.shared.start()
            guard LocalLLM.shared.isReady() else {
                // Surface the actual failure reason from LocalLLM.AIState rather
                // than the generic timeout message. SwiftLM commonly dies in
                // ~2 s when the model files are missing or incompatible —
                // saying "didn't become healthy within 180 s" lies about both
                // the time elapsed and the actual cause.
                let detail: String
                switch LocalLLM.shared.state() {
                case .failed(let msg):  detail = msg
                case .starting:         detail = "Still loading after \(Int(Date().timeIntervalSince(startedAt))) s — Gemma 4 model may be unusually large or disk-bound."
                case .notConfigured:    detail = "Local AI isn't configured. Re-run setup to download the model + SwiftLM binary."
                case .ready:            detail = "Race: state went .ready but isReady() returned false. Re-run."
                }
                await MainActor.run { aiTestState = .failed(detail) }
                return
            }
            await MainActor.run { aiTestState = .classifying }

            let fixture = IssueRef(
                id: "test-id",
                identifier: "TEST-1",
                title: "Self-test",
                description: "Lemon settings self-test — verifies SwiftLM + Gemma respond correctly.",
                labelNames: [],
                scope: .linearTeam(id: "test")
            )
            let logs = [
                "$ claude --permission-mode auto --remote-control",
                "Trust this MCP server (linear)? [y/N]"
            ]
            do {
                let resp = try await LocalLLM.shared.classify(issue: fixture, logLines: logs)
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                await MainActor.run {
                    aiTestState = .passed(state: resp.state, summary: resp.summary, elapsedSec: elapsed)
                }
            } catch {
                await MainActor.run {
                    aiTestState = .failed("classify error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func aiRow(icon: String, label: String, path: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            // Editorial: a small mono SF Symbol in a hairline-bordered chip,
            // matching the SourceGlyph weight rather than the old colored
            // iconBox tile.
            configGlyph(icon, tint: ready ? LD.statusDone : LD.coral.opacity(0.55))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    configStatusChip(ready: ready)
                }
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Editorial config glyph — same hairline-border treatment as `SourceGlyph`,
    /// just using an SF Symbol instead of a typographic mark. Used by the
    /// Local AI + MCP rows so they read in the same language as the rest
    /// of the Settings pane.
    private func configGlyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 22, height: 18)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }

    /// Live / off / missing chip matching `workspaceLiveChip` in shape.
    @ViewBuilder
    private func configStatusChip(ready: Bool) -> some View {
        if ready {
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 4, height: 4)
                Text("ready")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.statusDone)
            }
        } else {
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 4, height: 4)
                Text("missing")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        }
    }

    @ViewBuilder
    private func mcpRunningChip(running: Bool) -> some View {
        if running {
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 4, height: 4)
                Text("running")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.statusDone)
            }
        } else {
            Text("off")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }

    private var readyBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(LD.statusDone).frame(width: 5, height: 5)
            Text("Ready").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.statusDone)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(LD.statusDone.opacity(0.10), in: Capsule())
    }

    private var missingBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(LD.coral).frame(width: 5, height: 5)
            Text("Missing").font(.system(size: 9, weight: .semibold)).foregroundStyle(LD.coral)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(LD.coral.opacity(0.10), in: Capsule())
    }

    // MARK: - Footer

    private var settingsFooter: some View {
        HStack(spacing: 12) {
            Button {
                NotificationCenter.default.post(name: .lemonRerunSetup, object: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Re-run setup")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .lemonGlassCapsule(.resting)
            }
            .buttonStyle(.plain)

            Spacer()

            if saved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.statusDone)
                    Text("Saved")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LD.statusDone)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Button("Save", action: save)
                .buttonStyle(LemonButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
        }
        .animation(LD.smooth, value: saved)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private func iconBox(_ systemName: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: LD.r6)
                .fill(tint.opacity(0.12))
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(LD.statusDone)
                .frame(width: 5, height: 5)
            Text("Connected")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LD.statusDone)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(LD.statusDone.opacity(0.10), in: Capsule())
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(1.2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Load / save

    private func load() {
        let k = KeychainStore.shared
        linearApiKey = k.linearApiKey
        githubToken = k.githubToken
        githubUser = k.githubUser
        pairs = k.pairs
    }

    private func save() {
        let k = KeychainStore.shared
        if !linearApiKey.isEmpty { k.linearApiKey = linearApiKey }
        if !githubToken.isEmpty { k.githubToken = githubToken }
        if !githubUser.isEmpty { k.githubUser = githubUser }
        k.pairs = pairs
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { saved = false }
        }
    }

    private func verifyGitHubToken() async {
        await MainActor.run { ghVerifyState = .verifying }
        do {
            let identity = try await GitHubClient().verifyCredential(token: githubToken)
            // The login (used as the assignee filter) lives in displayName when
            // the user hasn't set a name on GH; CredentialIdentity stores both
            // sides of that fallback in displayName, so re-derive login from id
            // shape isn't reliable. Persist a best-effort login = displayName.
            await MainActor.run {
                ghVerifyState = .ok(login: identity.displayName)
                githubUser = identity.displayName
            }
        } catch {
            await MainActor.run {
                ghVerifyState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Workspace editor sheet
//
// Editorial polish: eyebrow + dateline-style metadata, generous whitespace,
// one primary action (Done) in lemon-yellow, restrained typography. Each
// pair row reveals its source-shaped fields (Linear → prefix, GitHub →
// owner/repo), with inline validation hints.

struct WorkspaceEditorView: View {
    @Binding var pairs: [WorkspacePair]
    let onDone: () -> Void

    @State private var confirmingDeleteId: UUID? = nil
    @State private var deleteTask: Task<Void, Never>?

    private var atCap: Bool { pairs.count >= KeychainStore.maxPairs }
    private var duplicateMatchKeys: Set<String> {
        // Helps surface "you've got two LEM rows pointing at different paths".
        // Case-insensitive within the same source.
        let perSource = Dictionary(grouping: pairs) { "\($0.source.source.rawValue):\($0.workspace.matchKey.lowercased())" }
        return Set(perSource.filter { $0.value.count > 1 }.keys)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Eyebrow + heading + dateline metadata row, lemon.living-style.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WORKSPACE")
                            .font(.system(size: 9, weight: .bold))
                            .kerning(1.6)
                            .foregroundStyle(LD.lemon)
                        Text("Pairs")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Button("Done") { onDone() }
                        .buttonStyle(LemonButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 10) {
                    metaItem(label: "Configured", value: "\(pairs.count) of \(KeychainStore.maxPairs)")
                    metaDivider
                    metaItem(label: "Linear", value: "\(pairs.filter { $0.source.source == .linear }.count)")
                    metaDivider
                    metaItem(label: "GitHub", value: "\(pairs.filter { $0.source.source == .github }.count)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            // Pair list
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach($pairs) { $pair in
                        PairRowView(
                            pair: $pair,
                            isDuplicate: duplicateMatchKeys.contains(
                                "\(pair.source.source.rawValue):\(pair.workspace.matchKey.lowercased())"
                            ) && !pair.workspace.matchKey.isEmpty,
                            confirmingDelete: confirmingDeleteId == pair.id,
                            onDelete: { handleDelete(pair.id) }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            )
                        )
                    }

                    addPairButton

                    if atCap {
                        Text("Soft cap. Bump it in KeychainStore.maxPairs if you genuinely need more — the limit's there to keep per-poll fan-out bounded.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .animation(LD.snappy, value: pairs.count)
                .animation(LD.snappy, value: confirmingDeleteId)
            }
        }
        .frame(width: 560, height: 620)
        .background(.regularMaterial)
    }

    private var addPairButton: some View {
        Button {
            addLinearPair()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(atCap ? "10-pair limit reached" : "Add pair")
                    .font(.system(size: 12, weight: .semibold))
                if !atCap {
                    Text("Linear by default — toggle the source in the row.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LD.r10)
                    .strokeBorder(
                        atCap ? Color.secondary.opacity(0.15) : LD.lemon.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .foregroundStyle(atCap ? AnyShapeStyle(.tertiary) : AnyShapeStyle(LD.lemon))
        }
        .buttonStyle(.plain)
        .disabled(atCap)
        .opacity(atCap ? 0.55 : 1)
    }

    private func addLinearPair() {
        withAnimation(LD.snappy) {
            pairs.append(WorkspacePair(
                source: SourceConfig(source: .linear, displayName: "Linear", linearTeamKeys: [""]),
                workspace: WorkspaceMapping(matchKey: "", path: "")
            ))
        }
    }

    private func handleDelete(_ id: UUID) {
        if confirmingDeleteId == id {
            deleteTask?.cancel()
            confirmingDeleteId = nil
            withAnimation(LD.snappy) {
                pairs.removeAll { $0.id == id }
            }
        } else {
            confirmingDeleteId = id
            deleteTask?.cancel()
            deleteTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled {
                    withAnimation(LD.smooth) { confirmingDeleteId = nil }
                }
            }
        }
    }

    private func metaItem(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var metaDivider: some View {
        Text("·")
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
    }
}

struct PairRowView: View {
    @Binding var pair: WorkspacePair
    let isDuplicate: Bool
    let confirmingDelete: Bool
    let onDelete: () -> Void

    @State private var hovered = false

    private var validation: ValidationState {
        if pair.workspace.matchKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingKey
        }
        if pair.workspace.path.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingPath
        }
        if pair.source.source == .github && !pair.workspace.matchKey.contains("/") {
            return .ghShape
        }
        if isDuplicate {
            return .duplicate
        }
        return .ok
    }

    enum ValidationState {
        case ok, missingKey, missingPath, ghShape, duplicate

        var hint: String? {
            switch self {
            case .ok:           return nil
            case .missingKey:   return "Add a Linear team prefix or owner/repo."
            case .missingPath:  return "Point this pair at a local repo or folder."
            case .ghShape:      return "GitHub matchKey should be owner/repo (e.g. acme/widgets)."
            case .duplicate:    return "Another row already claims this key."
            }
        }
        var color: Color? {
            switch self {
            case .ok:                                          return nil
            case .missingKey, .missingPath, .duplicate, .ghShape: return LD.coral
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top: source picker + delete (delete morphs into "Remove?" when armed).
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { pair.source.source },
                    set: { syncSource($0) }
                )) {
                    Label("Linear", systemImage: "circle.hexagongrid.fill").tag(IssueSource.linear)
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right").tag(IssueSource.github)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                SourceGlyph(source: pair.source.source)
                    .help(pair.source.source.displayName)

                Spacer()

                Button(action: onDelete) {
                    HStack(spacing: 4) {
                        Image(systemName: confirmingDelete ? "trash.fill" : "trash")
                            .font(.system(size: 11, weight: .medium))
                        if confirmingDelete {
                            Text("Remove?")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(confirmingDelete ? .white : LD.coral)
                    .padding(.horizontal, confirmingDelete ? 8 : 6)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(confirmingDelete ? LD.coral : LD.coral.opacity(0.10))
                    )
                    .animation(LD.snappy, value: confirmingDelete)
                }
                .buttonStyle(.plain)
                .help(confirmingDelete ? "Click again to confirm" : "Remove this pair")
            }

            // Identifier field (source-aware label + placeholder).
            field(
                label: pair.source.source == .github ? "REPO" : "TEAM",
                placeholder: pair.source.source == .github ? "owner/repo" : "e.g. HRP",
                text: $pair.workspace.matchKey
            )
            .onChange(of: pair.workspace.matchKey) { _, newKey in
                // Keep SourceConfig allowlist in sync with matchKey.
                syncMatchKey(newKey)
            }

            // Path field — "PATH" for single repo, "FOLDER" for multi-repo.
            // Distinct from the matchKey label above so GitHub's REPO / local
            // PATH don't collide.
            field(
                label: pair.workspace.allReposInFolder ? "FOLDER" : "PATH",
                placeholder: pair.workspace.allReposInFolder ? "/path/to/projects" : "/path/to/repo",
                text: $pair.workspace.path
            )

            // Multi-repo toggle + (conditional) home subdir
            HStack(spacing: 10) {
                Toggle(isOn: $pair.workspace.allReposInFolder) {
                    Text("All repos in this folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }

            if pair.workspace.allReposInFolder {
                field(
                    label: "HOME",
                    placeholder: "e.g. memory",
                    text: $pair.workspace.homeRepo,
                    helper: "Optional — subdirectory where Claude launches. Put a LEMON.md there with team-specific guidance."
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Validation chip
            if let hint = validation.hint, let color = validation.color {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .lemonGlass(
            hovered ? .hover : .resting,
            tint: validation.color.map { $0.opacity(0.05) }
        )
        .onHover { hovered = $0 }
        .animation(LD.smooth, value: hovered)
        .animation(LD.smooth, value: pair.workspace.allReposInFolder)
    }

    // Editorial form field: eyebrow label, monospace input, optional helper line.
    private func field(label: String, placeholder: String, text: Binding<String>, helper: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            if let helper {
                Text(helper)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func syncSource(_ newSource: IssueSource) {
        pair.source = SourceConfig(
            id: pair.source.id,
            source: newSource,
            displayName: newSource.displayName,
            linearTeamKeys: newSource == .linear ? [pair.workspace.matchKey] : nil,
            githubRepos: newSource == .github ? [pair.workspace.matchKey] : nil
        )
    }

    private func syncMatchKey(_ newKey: String) {
        if pair.source.source == .linear {
            pair.source = SourceConfig(
                id: pair.source.id, source: .linear,
                displayName: "Linear",
                linearTeamKeys: [newKey], githubRepos: nil
            )
        } else {
            pair.source = SourceConfig(
                id: pair.source.id, source: .github,
                displayName: "GitHub",
                linearTeamKeys: nil, githubRepos: [newKey]
            )
        }
    }
}
