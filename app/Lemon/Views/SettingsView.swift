import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let lemonRerunSetup = Notification.Name("com.lemon.rerunSetup")
}

struct SettingsView: View {
    @State private var linearApiKey = ""
    @State private var repos: [WorkspaceRepo] = []
    @State private var saved = false
    @State private var editingWorkspace = false
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var aiTestState: AITestState = .idle

    enum AITestState: Equatable {
        case idle
        case starting      // launching SwiftLM subprocess + waiting for /health
        case classifying   // server up, running classify()
        case passed(state: String, summary: String, elapsedSec: Int)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    generalSection
                    linearSection
                    workspaceSection
                    localAISection
                }
                .padding(24)
                .padding(.bottom, 4)
            }
            Divider()
            settingsFooter
        }
        .frame(minHeight: 680)
        .onAppear { load() }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("General")
            HStack(spacing: 12) {
                iconBox("arrow.up.circle.fill", tint: LD.statusDone)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at Login")
                        .font(.system(size: 13))
                    Text("Start Lemon automatically when you log in")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
            .padding(14)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
        }
    }

    private var linearSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Linear")
            HStack(alignment: .top, spacing: 12) {
                iconBox("key.horizontal.fill", tint: LD.lemon)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("API Key")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if !linearApiKey.isEmpty {
                            connectedBadge
                        }
                    }
                    SecureField("Paste from linear.app/settings → API", text: $linearApiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
                Spacer()
            }
            .padding(14)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Workspace")
                Spacer()
                Button("Edit") { editingWorkspace = true }
                    .buttonStyle(GhostButtonStyle())
            }
            if repos.isEmpty {
                HStack(spacing: 12) {
                    iconBox("folder.fill", tint: .secondary)
                    Text("No repos configured")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            } else {
                VStack(spacing: 0) {
                    ForEach(repos) { repo in
                        repoRow(repo)
                        if repo.id != repos.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
        .sheet(isPresented: $editingWorkspace) {
            WorkspaceEditorView(repos: $repos)
        }
    }

    private func repoRow(_ repo: WorkspaceRepo) -> some View {
        HStack(spacing: 12) {
            iconBox(repo.allReposInFolder ? "folder.fill.badge.plus" : "folder.fill", tint: LD.lemon)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.issuePrefix)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(LD.citrus)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LD.lemon.opacity(0.18), in: RoundedRectangle(cornerRadius: LD.r3))
                    if repo.allReposInFolder {
                        Text("folder")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.05), in: Capsule())
                    }
                    if repo.allReposInFolder && !repo.homeRepo.isEmpty {
                        Text("→ \(repo.homeRepo)/")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LD.lemon.opacity(0.10), in: Capsule())
                    }
                }
                Text(repo.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
        }
    }

    private var aiTestRow: some View {
        HStack(spacing: 12) {
            iconBox("wand.and.stars", tint: aiTestTint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Self-test").font(.system(size: 13))
                    aiTestBadge
                }
                Text(aiTestDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
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
                await MainActor.run {
                    aiTestState = .failed("SwiftLM didn't become healthy within 180 s — check Console.app under com.lemon.app/orchestrator for the launch error.")
                }
                return
            }
            await MainActor.run { aiTestState = .classifying }

            let fixture = LinearIssue(
                id: "test-id",
                identifier: "TEST-1",
                title: "Self-test",
                description: "Lemon settings self-test — verifies SwiftLM + Gemma respond correctly.",
                labelNames: [],
                teamId: "test"
            )
            let logs = [
                "$ claude --enable-auto-mode --remote-control",
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
            iconBox(icon, tint: ready ? LD.lemon : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: 13))
                    if ready {
                        readyBadge
                    } else {
                        missingBadge
                    }
                }
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Button("Re-run setup") {
                NotificationCenter.default.post(name: .lemonRerunSetup, object: nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

            Spacer()

            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LD.statusDone)
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
        repos = k.workspaceRepos
    }

    private func save() {
        let k = KeychainStore.shared
        if !linearApiKey.isEmpty { k.linearApiKey = linearApiKey }
        k.saveWorkspaceRepos(repos)
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { saved = false }
        }
    }
}

// MARK: - Workspace editor sheet

struct WorkspaceEditorView: View {
    @Binding var repos: [WorkspaceRepo]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace Repos")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(LemonButtonStyle())
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($repos) { $repo in
                        RepoRowView(repo: $repo) {
                            repos.removeAll { $0.id == repo.id }
                        }
                    }
                    Button {
                        repos.append(WorkspaceRepo(issuePrefix: "", path: ""))
                    } label: {
                        Label("Add Repo", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(GhostButtonStyle())
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 360)
        .background(.regularMaterial)
    }
}

struct RepoRowView: View {
    @Binding var repo: WorkspaceRepo
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Prefix")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    TextField("e.g. HRP", text: $repo.issuePrefix)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                }
                HStack(spacing: 8) {
                    Text(repo.allReposInFolder ? "Folder" : "Repo")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    TextField(repo.allReposInFolder ? "/path/to/projects" : "/path/to/repo", text: $repo.path)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 8) {
                    Spacer().frame(width: 52)
                    Toggle(isOn: $repo.allReposInFolder) {
                        Text("All repos in this folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                }

                if repo.allReposInFolder {
                    HStack(spacing: 8) {
                        Text("Home")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        TextField("e.g. memory", text: $repo.homeRepo)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                        Text("optional")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .help("Subdirectory where Claude launches. Create LEMON.md there with repo navigation instructions for this team.")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LD.coral)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }
}
