import ServiceManagement
import SwiftUI

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
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var aiTestState: AITestState = .idle

    // MCP server state — mirrors UserDefaults but lets the toggle drive
    // start/stop on change. The port text field is also a UserDefault.
    @AppStorage("lemon-mcp-enabled") private var mcpEnabled = false
    @AppStorage("lemon-mcp-port") private var mcpPort = Int(LemonMCPServer.defaultPort)
    @State private var mcpCopyHint: String?

    enum AITestState: Equatable {
        case idle
        case starting // launching SwiftLM subprocess + waiting for /health
        case classifying // server up, running classify()
        case passed(state: String, summary: String, elapsedSec: Int)
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
            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth)
            settingsFooter
        }
        // Fill the popover's capped height (set in PopoverView) so the ScrollView
        // gets a bounded frame and scrolls its content instead of forcing the
        // window taller than the screen. (Was minHeight: 780, which overflowed.)
        .frame(maxHeight: .infinity)
        .onAppear { load() }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("General")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    rowIconCell("power", on: launchAtLogin)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LD.textPrimary)
                            Spacer()
                        }
                        Text("Start Lemon automatically when you log in.")
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textTertiary)
                    }
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(LemonToggleStyle())
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
            .lemonGlass(.thick, cornerRadius: LD.r14)
        }
    }

    // MARK: - Identities panel (top-level credentials)

    @Environment(AppNavigation.self) private var nav

    private var allIdentities: [Identity] {
        KeychainStore.shared.identities
    }

    private var allWorkspaces: [Workspace] {
        KeychainStore.shared.workspaces
    }

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
                            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 56)
                        }
                    }
                }
                .lemonGlass(.thick, cornerRadius: LD.r14)
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
        .foregroundStyle(LD.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(LD.glassThinFill, in: Capsule())
        .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth))
    }

    private var identityCountChip: some View {
        Text("\(allIdentities.count)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(LD.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(LD.glassThinFill))
        .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth))
    }

    private var identitiesEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No identities connected.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LD.textSecondary)
            Text("Connect Linear, GitHub, or a GitHub Enterprise instance to start routing workspaces.")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonGlass(.thick, cornerRadius: LD.r14)
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
                            .foregroundStyle(LD.textPrimary)
                        if !ident.handle.isEmpty {
                            Text("@\(ident.handle)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LD.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LD.textQuaternary)
                    }
                    HStack(spacing: 6) {
                        if let host = ident.host, !host.isEmpty {
                            Text(host)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(LD.textTertiary)
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(LD.textQuaternary)
                        }
                        Text("\(ident.knownSurfaces.count) surface\(ident.knownSurfaces.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textSecondary)
                        if let fetched = ident.surfacesFetchedAt {
                            Text("· refreshed \(relative(fetched))")
                                .font(.system(size: 9))
                                .foregroundStyle(LD.textQuaternary)
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
                            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 56)
                        }
                    }
                }
                .lemonGlass(.thick, cornerRadius: LD.r14)
            }
        }
    }

    private var workspacesEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workspaces yet.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LD.textSecondary)
            Text("Add a folder + routing to start polling. Lemon needs at least one connected identity to route through.")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonGlass(.thick, cornerRadius: LD.r14)
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
                        .foregroundStyle(LD.textQuaternary)
                }
                .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName.isEmpty ? "Unnamed workspace" : displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LD.textPrimary)
                        if ws.allReposInFolder {
                            editorialChip("folder", tint: LD.textSecondary)
                        }
                        if ws.allReposInFolder, !ws.homeRepo.isEmpty {
                            editorialChip("→ \(ws.homeRepo)/", tint: LD.textSecondary, mono: true)
                        }
                        Spacer(minLength: 0)
                        workspaceLiveChip(status: status, ident: ident)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LD.textQuaternary)
                    }
                    HStack(spacing: 6) {
                        if let ident, let surface {
                            Text("\(ident.label) · \(surface.key)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LD.textTertiary)
                                .lineLimit(1)
                        } else if let ident {
                            HStack(spacing: 4) {
                                Text("\(ident.label) · \(ws.routing.surfaceId)")
                                    .font(.system(size: 10, design: .monospaced))
                                Text("· unknown surface")
                                    .font(.system(size: 9))
                                    .foregroundStyle(LD.coral)
                            }
                            .foregroundStyle(LD.textTertiary)
                        } else {
                            Text("Routing missing — identity deleted")
                                .font(.system(size: 10))
                                .foregroundStyle(LD.coral)
                        }
                    }
                    Text(ws.path.isEmpty ? "(no path set)" : ws.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let line = status?.subtitle {
                        Text(line)
                            .font(.system(size: 9))
                            .foregroundStyle(status?.error == nil ? AnyShapeStyle(LD.textQuaternary) : AnyShapeStyle(LD.coral))
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
                Circle().fill(LD.coral).frame(width: 5, height: 5)
                Text("orphan")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        } else if let status, status.error != nil {
            HStack(spacing: 3) {
                Circle().fill(LD.coral).frame(width: 5, height: 5)
                Text("err")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.coral)
            }
        } else if status?.lastPolledAt != nil {
            HStack(spacing: 3) {
                Circle().fill(LD.statusDone).frame(width: 5, height: 5)
                Text("live")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LD.statusDone)
            }
        } else {
            Text("idle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LD.textQuaternary)
        }
    }

    /// Tiny "N · 10" pair count, set in monospace for editorial restraint.
    private var pairCountChip: some View {
        HStack(spacing: 3) {
            Text("\(allWorkspaces.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(allWorkspaces.count >= KeychainStore.maxPairs ? LD.coral : LD.textSecondary)
            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(LD.textQuaternary)
            Text("\(KeychainStore.maxPairs)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(LD.textTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(LD.glassThinFill))
        .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth))
    }

    /// Editorial chip — kerned uppercase or monospace, hairline border for restraint.
    private func editorialChip(_ text: String, tint: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(.system(
                size: 9,
                weight: mono ? .medium : .semibold,
                design: mono ? .monospaced : .default,
            ))
            .kerning(mono ? 0 : 0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.5))
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
                eyebrowBadge("SwiftLM \(LocalAI.swiftLMBuild)")
            }

            VStack(spacing: 0) {
                aiRow(icon: "cpu", label: "Gemma model",
                      path: modelPath.isEmpty ? "Not configured" : modelPath,
                      ready: modelReady)
                Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 54)
                aiRow(icon: "terminal.fill", label: "SwiftLM runner",
                      path: swiftLMPath.isEmpty ? "Not configured" : swiftLMPath,
                      ready: swiftLMReady)
                if modelReady, swiftLMReady {
                    Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 54)
                    aiTestRow
                }
            }
            .lemonGlass(.thick, cornerRadius: LD.r14)
        }
    }

    // MARK: - MCP server section

    ///
    /// Opt-in HTTP+JSON-RPC server that exposes Lemon's session state and
    /// control surface to Claude Code (or any MCP-speaking client). Localhost
    /// bind only — anyone on this Mac who can reach loopback can hit it.
    /// Same threat model as Lemon's running process; we don't add a bearer
    /// token to keep setup friction at zero.
    private var mcpSection: some View {
        let running = LemonMCPServer.shared.isRunning
        let endpoint = "http://127.0.0.1:\(mcpPort)/mcp"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionLabel("MCP Server")
                Spacer()
                eyebrowBadge("Claude Code · recursive mode")
            }

            VStack(spacing: 0) {
                // Toggle row
                HStack(spacing: 12) {
                    rowIconCell("network", on: running)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Expose to Claude Code")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LD.textPrimary)
                            Spacer()
                            mcpRunningChip(running: running)
                        }
                        Text(running
                            ? endpoint
                            : "Flip on to let another Claude observe and steer Lemon sessions.")
                            .font(.system(size: 10, design: running ? .monospaced : .default))
                            .foregroundStyle(LD.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    Toggle("", isOn: $mcpEnabled)
                        .labelsHidden()
                        .toggleStyle(LemonToggleStyle())
                        .onChange(of: mcpEnabled) { _, enabled in
                            applyMcpToggle(enabled: enabled)
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)

                if mcpEnabled {
                    Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 56)

                    // Port row
                    HStack(spacing: 12) {
                        configGlyph("number", tint: LD.textSecondary.opacity(0.7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Port")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Default 8765 — toggle off/on to apply changes.")
                                .font(.system(size: 10))
                                .foregroundStyle(LD.textTertiary)
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
                                    .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: 0.5),
                            )
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)

                    Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth).padding(.leading, 56)

                    // Copy config row
                    HStack(spacing: 12) {
                        configGlyph("doc.on.clipboard", tint: LD.textSecondary.opacity(0.7))
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
                                    .foregroundStyle(LD.textTertiary)
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
            .lemonGlass(.thick, cornerRadius: LD.r14)
        }
    }

    private func applyMcpToggle(enabled: Bool) {
        let port = UInt16(exactly: max(1024, min(mcpPort, 65535))) ?? LemonMCPServer.defaultPort
        if enabled {
            do {
                try LemonMCPServer.shared.start(port: port)
                LemonMCPTools.registerAll(server: LemonMCPServer.shared, orchestrator: orchestrator)
            } catch {
                mcpEnabled = false // bind failed — reflect the actual state
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
                            .foregroundStyle(LD.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } else {
                    Text(aiTestDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
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
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var aiTestTint: Color {
        switch aiTestState {
        case .idle: LD.textSecondary
        case .starting, .classifying: LD.lemon
        case .passed: LD.statusDone
        case .failed: LD.coral
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
        case .idle: "Boot SwiftLM + run one classify() call. ~60-90 s for first run."
        case .starting: "Loading model into GPU — first launch can take 60-90 s."
        case .classifying: "Sent test prompt; waiting for Gemma to respond…"
        case let .passed(s, summary, secs): "state=\(s) · summary=\(summary) · \(secs) s"
        case let .failed(msg): msg
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
                let detail: String = switch LocalLLM.shared.state() {
                case let .failed(msg): msg
                case .starting: "Still loading after \(Int(Date().timeIntervalSince(startedAt))) s — Gemma 4 model may be unusually large or disk-bound."
                case .notConfigured: "Local AI isn't configured. Re-run setup to download the model + SwiftLM binary."
                case .ready: "Race: state went .ready but isReady() returned false. Re-run."
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
                scope: .linearTeam(id: "test"),
            )
            let logs = [
                "$ claude --permission-mode auto --remote-control",
                "Trust this MCP server (linear)? [y/N]",
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
                        .foregroundStyle(LD.textPrimary)
                    Spacer()
                    configStatusChip(ready: ready)
                }
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
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
                .foregroundStyle(LD.textQuaternary)
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
                .foregroundStyle(LD.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(LD.glassThinFill, in: Capsule())
                .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth))
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

    /// 26×26 leading icon cell — statusDone wash + statusDone glyph when active,
    /// dimmed warm text when off. Matches the identity-row icon cell in
    /// settings-panels.html (statusDone bg, 13px glyph, r7 continuous corner).
    private func rowIconCell(_ systemName: String, on: Bool = true) -> some View {
        let tint = on ? LD.statusDone : LD.textSecondary.opacity(0.6)
        return Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Small monospace eyebrow tag — a `.cap`-style warm pill. Neutral, not a
    /// lemon wash: the single yellow accent stays reserved for the Save CTA.
    private func eyebrowBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(LD.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(LD.glassThinFill, in: Capsule())
            .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(1.2)
            .foregroundStyle(LD.textTertiary)
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

}

// MARK: - Toggle style

/// The Lemon settings toggle — a 34×20 capsule track that fills `LD.statusDone`
/// when on, with a 16×16 white knob (2pt inset) that slides to the trailing
/// edge. Matches the launch-at-login / MCP toggle in settings-panels.html.
/// Off-state track is a hushed warm-text wash, never the cool system green.
struct LemonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? LD.statusDone : LD.textPrimary.opacity(0.16))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(LD.snappy, value: configuration.isOn)
    }
}
