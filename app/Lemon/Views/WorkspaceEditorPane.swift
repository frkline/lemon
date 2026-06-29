import AppKit
import SwiftUI

/// Slide-in pane for adding or editing a single Workspace.
/// Pushed via `AppNavigation.editWorkspace(_:)` / `addWorkspace()`.
struct WorkspaceEditorPane: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav

    let target: AppNavigation.WorkspaceEditorTarget

    @State private var path: String = ""
    @State private var allReposInFolder: Bool = false
    @State private var homeRepo: String = ""
    @State private var lockdown: Bool = false
    @State private var engineKind: AgentEngineKind = .claudeCode
    @State private var openCodePlanModel: String = ""
    @State private var openCodeCodeModel: String = ""
    @State private var openCodeReviewModel: String = ""
    @State private var openCodeAutoOpenThreshold: OpenCodeAutoOpenThreshold = .highConfidenceOnly
    @State private var openCodeHost: String = "127.0.0.1"
    @State private var openCodePort: Int = 4096
    @State private var readiness: AgentEngineReadiness?
    @State private var readinessLoading = false
    @State private var readinessTask: Task<Void, Never>?
    @State private var modelChoicesTask: Task<Void, Never>?
    @State private var daemonModelChoices: [String] = []
    @State private var identityId: UUID? = nil
    @State private var surfaceId: String = ""
    @State private var deleteArmed = false
    @State private var deleteTask: Task<Void, Never>?
    @State private var existing: Workspace?
    @State private var suggestion: PathSuggestion? = nil
    @State private var typingCustomKey: Bool = false
    @State private var reseedState: ReseedState = .idle

    private static let defaultOpenCodeModels: [String] = [
        "openai/gpt-5.3-codex",
        "anthropic/claude-opus-4",
        "anthropic/claude-sonnet-4",
        "openai/gpt-4.1-mini",
    ]

    enum ReseedState: Equatable {
        case idle, working
        case success(Int)
        case failed(String)
    }

    struct PathSuggestion: Equatable {
        let identityId: UUID
        let surfaceKey: String
        let label: String
        let detail: String // e.g. "GitHub · frkline/lemon — detected from .git/config"
    }

    private var identities: [Identity] {
        KeychainStore.shared.identities
    }

    private var selectedIdentity: Identity? {
        guard let id = identityId else { return nil }
        return identities.first { $0.id == id }
    }

    private var surfaces: [Surface] {
        selectedIdentity?.knownSurfaces ?? []
    }

    private var isNew: Bool {
        if case .new = target { true } else { false }
    }

    private var canSave: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard identityId != nil else { return false }
        let trimmedSurface = surfaceId.trimmingCharacters(in: .whitespaces)
        return !trimmedSurface.isEmpty
    }

    var body: some View {
        // ScrollView so content scrolls within the popover's capped height
        // instead of overflowing and clipping top/bottom. The glaze "room"
        // stays fixed; only the content scrolls.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                eyebrowHeader
                if identities.isEmpty {
                    noIdentitiesCard
                } else {
                    pathSection
                    identitySection
                    surfaceSection
                    engineSection
                    folderOptions
                }
                actionsRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The "second room": a faint lemon glaze over the inherited window
        // glass, r14. Interior surfaces are resting thin glass.
        .lemonGlass(.thick, tint: LD.tintLemon, cornerRadius: LD.r14)
        .onAppear {
            hydrate()
            refreshReadiness()
            refreshDaemonModelChoices()
        }
        .onChange(of: engineKind) { _, _ in
            refreshReadiness()
            refreshDaemonModelChoices()
        }
        .onChange(of: openCodePlanModel) { _, _ in refreshReadiness() }
        .onChange(of: openCodeCodeModel) { _, _ in refreshReadiness() }
        .onChange(of: openCodeReviewModel) { _, _ in refreshReadiness() }
        .onChange(of: openCodeHost) { _, _ in
            refreshReadiness()
            refreshDaemonModelChoices()
        }
        .onChange(of: openCodePort) { _, _ in
            refreshReadiness()
            refreshDaemonModelChoices()
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ENGINE")
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(LD.textTertiary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(AgentEngineKind.allCases, id: \.self) { kind in
                        engineChoice(kind)
                    }
                }

                if engineKind == .openCode {
                    VStack(alignment: .leading, spacing: 8) {
                        openCodeModelField("Plan model", text: $openCodePlanModel)
                        openCodeModelField("Code model", text: $openCodeCodeModel)
                        openCodeModelField("Review model", text: $openCodeReviewModel)

                        HStack(spacing: 8) {
                            Text("Auto-open")
                                .font(.system(size: 10))
                                .foregroundStyle(LD.textSecondary)
                            Spacer()
                            Menu {
                                ForEach(OpenCodeAutoOpenThreshold.allCases, id: \.self) { threshold in
                                    Button(threshold.displayName) {
                                        openCodeAutoOpenThreshold = threshold
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(openCodeAutoOpenThreshold.displayName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LD.textPrimary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9))
                                        .foregroundStyle(LD.textTertiary)
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }

                        HStack(spacing: 8) {
                            labeledField("Host", text: $openCodeHost, placeholder: "127.0.0.1")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.system(size: 8, weight: .bold))
                                    .kerning(1.2)
                                    .foregroundStyle(LD.textTertiary)
                                HStack(spacing: 6) {
                                    Text("\(openCodePort)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LD.textPrimary)
                                    Stepper("", value: $openCodePort, in: 1 ... 65535)
                                        .labelsHidden()
                                }
                            }
                            .frame(width: 118, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }

                engineReadinessBlock
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lemonGlass(.thin, cornerRadius: LD.r10)
        }
    }

    private func engineChoice(_ kind: AgentEngineKind) -> some View {
        let selected = engineKind == kind
        return Button {
            withAnimation(LD.snappy) {
                engineKind = kind
            }
        } label: {
            HStack(spacing: 6) {
                Text(kind.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? LD.textPrimary : LD.textSecondary)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LD.statusDone)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .lemonGlass(selected ? .regular : .thin,
                        tint: selected ? LD.tintLemon : nil,
                        cornerRadius: LD.r10,
                        ring: selected ? LD.lemon.opacity(0.30) : nil)
        }
        .buttonStyle(.plain)
    }

    private func openCodeModelField(_ title: String, text: Binding<String>) -> some View {
        let choices = modelChoices(current: text.wrappedValue)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(LD.textTertiary)
            HStack(spacing: 8) {
                TextField("provider/model", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))

                Menu {
                    if choices.isEmpty {
                        Button("No model suggestions yet") {}
                            .disabled(true)
                    } else {
                        ForEach(choices, id: \.self) { choice in
                            Button(choice) {
                                text.wrappedValue = choice
                            }
                        }
                    }
                    Divider()
                    Button("Clear") {
                        text.wrappedValue = ""
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LD.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: LD.r6)
                                .fill(LD.textPrimary.opacity(0.08)),
                        )
                }
                .menuStyle(.borderlessButton)
                .help("Pick from recent or suggested model IDs")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: LD.r6)
                    .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth),
            )
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(LD.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: LD.r6)
                        .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth),
                )
        }
    }

    private var knownOpenCodeModelChoices: [String] {
        let saved: [String] = KeychainStore.shared.workspaces
            .flatMap { (workspace: Workspace) -> [String] in
                guard workspace.engine.kind == .openCode,
                      let models = workspace.engine.openCode?.models
                else { return [] }
                return [models.plan, models.code, models.review]
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let merged = daemonModelChoices + Self.defaultOpenCodeModels + saved
        var seen = Set<String>()
        var ordered: [String] = []
        for model in merged where seen.insert(model).inserted {
            ordered.append(model)
        }
        return ordered
    }

    private func refreshDaemonModelChoices() {
        modelChoicesTask?.cancel()
        guard engineKind == .openCode else {
            daemonModelChoices = []
            return
        }

        let host = openCodeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        let resolvedPort = max(1, min(openCodePort, 65535))

        modelChoicesTask = Task {
            let discovered = await OpenCodeClient(host: resolvedHost, port: resolvedPort).availableModelIDs()
            guard !Task.isCancelled else { return }
            daemonModelChoices = discovered
        }
    }

    private func modelChoices(current: String) -> [String] {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrent.isEmpty else { return knownOpenCodeModelChoices }
        if knownOpenCodeModelChoices.contains(trimmedCurrent) {
            return knownOpenCodeModelChoices
        }
        return [trimmedCurrent] + knownOpenCodeModelChoices
    }

    private var engineReadinessBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("READINESS")
                    .font(.system(size: 8, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(LD.textTertiary)
                if readinessLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let readiness {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(readiness.isReady ? LD.statusDone : LD.coral)
                            .frame(width: 5, height: 5)
                        Text(readiness.isReady ? "ready" : "setup needed")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(readiness.isReady ? LD.statusDone : LD.coral)
                    }
                }
            }

            if let readiness {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(readiness.checks) { check in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: check.status == .pass ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(check.status == .pass ? LD.statusDone : LD.coral)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LD.textPrimary)
                                Text(check.detail)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(LD.textTertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Header

    private var eyebrowHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isNew ? "NEW WORKSPACE" : "WORKSPACE")
                .font(.system(size: 9, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(LD.textSecondary)
            Text(isNew ? "Map a folder to a tracker" : (existing.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Edit"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(LD.textPrimary)
            Text("Pick where the work happens on disk, then route its issues through one of your connected identities.")
                .font(.system(size: 11))
                .foregroundStyle(LD.textSecondary)
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
                    .foregroundStyle(LD.textTertiary)
                Text("drop a folder or paste a path")
                    .font(.system(size: 9))
                    .foregroundStyle(LD.textQuaternary)
                Spacer()
            }
            HStack(spacing: 0) {
                TextField(allReposInFolder ? "/path/to/projects" : "/path/to/repo", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
            }
            .background(
                RoundedRectangle(cornerRadius: LD.r6)
                    .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth),
            )
            .onChange(of: path) { _, newValue in
                analyzePath(newValue)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url, url.hasDirectoryPath {
                            DispatchQueue.main.async { path = url.path }
                        }
                    }
                }
                return true
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
                    .foregroundStyle(LD.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LD.textPrimary)
                    Text(s.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textTertiary)
                }
                Spacer(minLength: 0)
                Text("Use")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LD.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .lemonGlass(.thin, cornerRadius: LD.r10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Identity picker

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROUTE THROUGH")
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(LD.textTertiary)

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
                    .foregroundStyle(LD.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: LD.r10, style: .continuous)
                            .strokeBorder(LD.hairlineRegular,
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])),
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func identityChoiceRow(_ ident: Identity) -> some View {
        let isSelected = identityId == ident.id
        let isGH = ident.kind == .github
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
                SourceFavicon(source: ident.kind.issueSource, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ident.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LD.textPrimary)
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
                    .foregroundStyle(LD.textTertiary)
                }
                Spacer(minLength: 0)
                // Selected → green connected ✓; otherwise an empty marker.
                // Source-tint carries the selection on the glass, not yellow.
                Image(systemName: isSelected ? "checkmark.seal.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? LD.statusDone : LD.textQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .lemonGlass(
                isSelected ? .regular : .thin,
                tint: isSelected ? (isGH ? LD.tintGithub : LD.tintLinear) : nil,
                cornerRadius: LD.r10,
                ring: isSelected ? (isGH ? LD.tintGithubRing : LD.tintLinearRing) : nil,
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
                        .foregroundStyle(LD.textTertiary)
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
                        .foregroundStyle(LD.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-fetch surfaces from \(ident.kind.displayName)")
                }
                if ident.knownSurfaces.isEmpty {
                    surfaceFreeText
                    Text("No surfaces cached yet. Re-verify the identity to fetch them, or type a key here.")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textQuaternary)
                } else if typingCustomKey {
                    surfaceFreeText
                    Button {
                        withAnimation(LD.snappy) { typingCustomKey = false }
                    } label: {
                        Text("← Pick from \(ident.knownSurfaces.count) known surface\(ident.knownSurfaces.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LD.textSecondary)
                    }
                    .buttonStyle(.plain)
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
                                .foregroundStyle(LD.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(LD.textTertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .lemonGlass(.thin, cornerRadius: LD.r10)
                    }
                    .menuStyle(.borderlessButton)
                    Button {
                        withAnimation(LD.snappy) { typingCustomKey = true }
                    } label: {
                        Text("Type a custom key →")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LD.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                reseedRow
            }
        }
    }

    // MARK: - Re-seed 🍋 labels

    @ViewBuilder
    private var reseedRow: some View {
        // Lives inside surfaceSection so it sits where the routing is
        // already in mind. Only meaningful once the user has both an
        // identity and a surface selected — disable otherwise.
        let canReseed = identityId != nil
            && !surfaceId.trimmingCharacters(in: .whitespaces).isEmpty
            && reseedState != .working
        HStack(spacing: 8) {
            Button { performReseed() } label: {
                HStack(spacing: 4) {
                    if reseedState == .working {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                    }
                    Text(reseedState == .working ? "Re-seeding…" : "Re-seed 🍋 labels")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(canReseed ? LD.textSecondary : LD.textQuaternary)
            }
            .buttonStyle(.plain)
            .disabled(!canReseed)
            .help("Re-create the four 🍋 state labels (Tag · In Progress · Waiting · Complete) on this tracker. Safe to repeat.")

            reseedStatusChip
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var reseedStatusChip: some View {
        switch reseedState {
        case let .success(n):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.statusDone)
                Text("\(n) labels seeded")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LD.statusDone)
            }
        case let .failed(msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                    .lineLimit(1).truncationMode(.tail)
            }
        case .idle, .working:
            EmptyView()
        }
    }

    private func performReseed() {
        guard let id = identityId,
              !surfaceId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        reseedState = .working
        let surface = surfaceId
        Task {
            do {
                let count = try await orchestrator.reseedLabels(identityId: id, surfaceId: surface)
                await MainActor.run { reseedState = .success(count) }
            } catch {
                await MainActor.run { reseedState = .failed(error.localizedDescription) }
            }
        }
    }

    private var surfaceFreeText: some View {
        TextField(
            selectedIdentity?.kind == .github ? "owner/repo" : "Team key (e.g. HRP)",
            text: $surfaceId,
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: LD.r6)
                .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth),
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

    //
    // The multi-repo toggle + the home-subdir field belong together — they
    // describe the same thing (how the workspace's filesystem is laid out
    // underneath the path you chose). Group them in one card so they read
    // as one decision instead of two loose controls.

    private var folderOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FOLDER LAYOUT")
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(LD.textTertiary)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $allReposInFolder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All repos in this folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LD.textPrimary)
                        Text(allReposInFolder
                            ? "Lemon discovers every git repo inside and worktrees them as siblings."
                            : "Treat the path as a single repo.")
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)

                if allReposInFolder {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("HOME SUBDIR")
                                .font(.system(size: 8, weight: .bold))
                                .kerning(1.4)
                                .foregroundStyle(LD.textTertiary)
                            Text("optional")
                                .font(.system(size: 9))
                                .foregroundStyle(LD.textQuaternary)
                            Spacer()
                        }
                        TextField("e.g. memory", text: $homeRepo)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .background(
                                RoundedRectangle(cornerRadius: LD.r6)
                                    .strokeBorder(LD.textPrimary.opacity(0.12), lineWidth: LD.hairlineWidth),
                            )
                        Text("Where Claude launches inside the folder. Put a LEMON.md there with team-specific guidance.")
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().overlay(LD.hairlineDivider)

                // Trust boundary (#13). Recommended for public repos.
                Toggle(isOn: $lockdown) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lockdown — trusted author only")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LD.textPrimary)
                        Text(lockdown
                            ? "Only issues YOU opened trigger, and only your replies re-trigger. Other people's content is kept out of the AI's context entirely. Recommended for public repos."
                            : "Anyone's assigned issue can trigger; others' content is shown to the AI but wrapped as untrusted data.")
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lemonGlass(.thin, cornerRadius: LD.r10)
        }
        .animation(LD.smooth, value: allReposInFolder)
    }

    // MARK: - No identities yet

    private var noIdentitiesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(LD.textSecondary)
                Text("No identities connected yet.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LD.textPrimary)
            }
            Text("Connect a tracker first — Lemon needs to know where this workspace's issues live before it can route them.")
                .font(.system(size: 11))
                .foregroundStyle(LD.textSecondary)
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
                    .background(LD.linearMark.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(LD.linearMark.opacity(0.40), lineWidth: LD.hairlineWidth))
                    .foregroundStyle(LD.linearMark)
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
                    .overlay(Capsule().strokeBorder(LD.statusDone.opacity(0.40), lineWidth: LD.hairlineWidth))
                    .foregroundStyle(LD.statusDone)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonGlass(.thin, cornerRadius: LD.r10)
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
                // Default lockdown ON for GitHub (often public/community repos);
                // OFF for Linear (closed, vetted workspace). User can flip it.
                lockdown = firstIdentity.kind == .github
            }
        case let .existing(id):
            if let ws = KeychainStore.shared.workspaces.first(where: { $0.id == id }) {
                existing = ws
                path = ws.path
                allReposInFolder = ws.allReposInFolder
                homeRepo = ws.homeRepo
                identityId = ws.routing.identityId
                surfaceId = ws.routing.surfaceId
                lockdown = ws.lockdown
                engineKind = ws.engine.kind
                let openCode = ws.engine.openCode
                openCodePlanModel = openCode?.models.plan ?? ""
                openCodeCodeModel = openCode?.models.code ?? ""
                openCodeReviewModel = openCode?.models.review ?? ""
                openCodeAutoOpenThreshold = openCode?.autoOpenThreshold ?? .highConfidenceOnly
                openCodeHost = openCode?.daemon.host ?? "127.0.0.1"
                openCodePort = openCode?.daemon.port ?? 4096
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
            identities: identities,
        )
    }

    private func refreshReadiness() {
        readinessTask?.cancel()
        let engineConfig = WorkspaceEngineConfig(
            kind: engineKind,
            openCode: engineKind == .openCode
                ? OpenCodeWorkspaceConfig(
                    models: OpenCodeModelConfig(
                        plan: openCodePlanModel,
                        code: openCodeCodeModel,
                        review: openCodeReviewModel,
                    ),
                    autoOpenThreshold: openCodeAutoOpenThreshold,
                    daemon: OpenCodeDaemonConfig(
                        host: openCodeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : openCodeHost,
                        port: max(1, min(openCodePort, 65535)),
                    ),
                )
                : nil,
        )

        readinessLoading = true
        readinessTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                AgentEngineFactory.make(kind: engineConfig.kind).readiness(config: engineConfig)
            }.value
            guard !Task.isCancelled else { return }
            readiness = snapshot
            readinessLoading = false
        }
    }

    private func save() {
        let keychain = KeychainStore.shared
        guard let identityId else { return }
        let trimmedSurface = surfaceId.trimmingCharacters(in: .whitespaces)

        var working: Workspace = if let existing {
            existing
        } else {
            Workspace(
                path: "", allReposInFolder: false, homeRepo: "",
                routing: Routing(identityId: identityId, surfaceId: trimmedSurface),
            )
        }
        working.path = path.trimmingCharacters(in: .whitespaces)
        working.allReposInFolder = allReposInFolder
        working.homeRepo = homeRepo.trimmingCharacters(in: .whitespaces)
        working.routing = Routing(identityId: identityId, surfaceId: trimmedSurface)
        working.lockdown = lockdown
        let daemonHost = openCodeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let openCodeConfig = OpenCodeWorkspaceConfig(
            models: OpenCodeModelConfig(
                plan: openCodePlanModel.trimmingCharacters(in: .whitespacesAndNewlines),
                code: openCodeCodeModel.trimmingCharacters(in: .whitespacesAndNewlines),
                review: openCodeReviewModel.trimmingCharacters(in: .whitespacesAndNewlines),
            ),
            autoOpenThreshold: openCodeAutoOpenThreshold,
            daemon: OpenCodeDaemonConfig(host: daemonHost.isEmpty ? "127.0.0.1" : daemonHost,
                                         port: max(1, min(openCodePort, 65535))),
        )
        working.engine = WorkspaceEngineConfig(
            kind: engineKind,
            openCode: engineKind == .openCode ? openCodeConfig : nil,
        )

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
