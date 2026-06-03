import SwiftUI
import os

// MARK: - Step enum

private enum OnboardingStep: Int, CaseIterable {
    case linear = 0
    case workspace
    case lemonMd
    case localAI
    case ready
}

// MARK: - Wizard host

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var step: OnboardingStep = .linear
    @State private var direction: Int = 1

    // Linear step state — pre-load from store so restarts don't wipe progress
    @State private var linearApiKey = KeychainStore.shared.linearApiKey
    @State private var linearUserId = KeychainStore.shared.linearUserId
    @State private var linearUserName = ""  // display only, re-fetched on verify

    // Workspace step state
    @State private var repos: [WorkspaceRepo] = {
        let saved = KeychainStore.shared.workspaceRepos
        return saved.isEmpty ? [WorkspaceRepo(issuePrefix: "", path: "")] : saved
    }()


    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                LD.lemon
                    .frame(width: geo.size.width * progress)
                    .frame(height: 2)
                    .animation(LD.slide, value: step)
            }
            .frame(height: 2)
            .zIndex(10)

            stepView
                .transition(slideTransition)
                .id(step.rawValue)
                .animation(LD.slide, value: step)
        }
        .frame(width: 520, height: 580)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: LD.r14))
    }

    private var progress: Double {
        let total = Double(OnboardingStep.allCases.count - 1)
        return Double(step.rawValue) / total
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .linear:
            LinearStep(
                apiKey: $linearApiKey,
                userId: $linearUserId,
                userName: $linearUserName,
                onNext: { advance() }
            )
        case .workspace:
            WorkspaceStep(
                apiKey: linearApiKey,
                repos: $repos,
                onNext: { advance() },
                onBack: { back() }
            )
        case .lemonMd:
            LemonMdStep(
                repos: repos,
                onNext: { advance() },
                onBack: { back() }
            )
        case .localAI:
            LocalAIStep(
                onNext: { advance() },
                onBack: { back() }
            )
        case .ready:
            ReadyStep(
                apiKey: linearApiKey,
                onFinish: { finish() },
                onBack: { back() }
            )
        }
    }

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
            removal:   .move(edge: direction > 0 ? .leading  : .trailing).combined(with: .opacity)
        )
    }

    private func advance() {
        // Persist progress for the step we're leaving
        let k = KeychainStore.shared
        switch step {
        case .linear:
            if !linearApiKey.isEmpty { k.linearApiKey = linearApiKey }
            if !linearUserId.isEmpty { k.linearUserId = linearUserId }
        case .workspace:
            let valid = repos.filter { !$0.path.isEmpty && !$0.issuePrefix.isEmpty }
            if !valid.isEmpty { k.saveWorkspaceRepos(valid) }
        default:
            break
        }

        direction = 1
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            withAnimation(LD.slide) { step = next }
        } else {
            finish()
        }
    }

    private func back() {
        direction = -1
        if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
            withAnimation(LD.slide) { step = prev }
        }
    }

    private func finish() {
        let k = KeychainStore.shared
        k.linearApiKey  = linearApiKey
        k.linearUserId  = linearUserId
        k.saveWorkspaceRepos(repos.filter { !$0.path.isEmpty && !$0.issuePrefix.isEmpty })
        withAnimation(LD.smooth) { isComplete = true }
    }
}

#if DEBUG
extension OnboardingView {
    // stepIndex: 0=linear, 1=workspace, 2=lemonMd, 3=localAI, 4=ready
    init(isComplete: Binding<Bool>, forcedStep stepIndex: Int) {
        self._isComplete = isComplete
        self._step = State(initialValue: OnboardingStep(rawValue: stepIndex) ?? .linear)
        self._direction = State(initialValue: 1)
        self._linearApiKey = State(initialValue: "lin_api_smoke_key")
        self._linearUserId = State(initialValue: "u_smoke")
        self._linearUserName = State(initialValue: "")
        self._repos = State(initialValue: [WorkspaceRepo(issuePrefix: "LEM", path: "/Users/frank/Projects/lemon")])
    }
}
#endif

// MARK: - Shared shell

private struct StepShell<Content: View>: View {
    let emoji: String
    let title: String
    let subtitle: String
    var backAction: (() -> Void)? = nil
    var nextLabel: String = "Continue"
    var nextEnabled: Bool = true
    var nextAction: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 44)

            VStack(spacing: 10) {
                Text(emoji)
                    .font(.system(size: 44))
                    .shadow(color: LD.lemon.opacity(0.4), radius: 16, y: 4)
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer().frame(height: 24)

            ScrollView(showsIndicators: false) {
                content
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }

            HStack(spacing: 10) {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle())
                if let back = backAction {
                    Button("Back", action: back)
                        .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button(nextLabel, action: nextAction)
                    .buttonStyle(LemonButtonStyle())
                    .disabled(!nextEnabled)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Step 1: Linear

private struct LinearStep: View {
    @Binding var apiKey: String
    @Binding var userId: String
    @Binding var userName: String
    let onNext: () -> Void

    @State private var isVerifying = false
    @State private var verifyError: String?

    private var canContinue: Bool { !userId.isEmpty }

    var body: some View {
        StepShell(
            emoji: "🍋",
            title: "Connect Linear",
            subtitle: "Lemon polls your Linear queue for issues tagged 🍋\nand works on them automatically.",
            nextEnabled: canContinue,
            nextAction: onNext
        ) {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Linear API Key")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Link("↗", destination: URL(string: "https://linear.app/settings/api")!)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    SecureField("lin_api_...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: apiKey) { _, _ in
                            userId = ""; userName = ""; verifyError = nil
                        }
                }

                Button {
                    verify()
                } label: {
                    HStack(spacing: 8) {
                        if isVerifying { ProgressView().scaleEffect(0.65) }
                        else { Image(systemName: "bolt.fill") }
                        Text(isVerifying ? "Verifying…" : "Verify API Key")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LemonButtonStyle())
                .disabled(apiKey.isEmpty || isVerifying)

                if !userName.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LD.statusDone)
                        Text("Connected as \(userName)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(12)
                    .background(LD.statusDone.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
                }

                if let err = verifyError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(LD.coral)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func verify() {
        isVerifying = true
        verifyError = nil
        let key = apiKey
        Task.detached {
            Logger.onboarding.info("Verifying Linear API key")
            let client = LinearClient()
            do {
                let viewer = try await client.fetchViewer(apiKey: key)
                Logger.onboarding.info("Verified as \(viewer.name) (\(viewer.email))")
                await MainActor.run {
                    userId = viewer.id
                    userName = viewer.name
                    isVerifying = false
                }
            } catch {
                Logger.onboarding.error("Linear verify failed: \(error)")
                await MainActor.run {
                    verifyError = error.localizedDescription
                    isVerifying = false
                }
            }
        }
    }
}

// MARK: - Step 2: Workspace

private struct WorkspaceStep: View {
    let apiKey: String
    @Binding var repos: [WorkspaceRepo]
    let onNext: () -> Void
    let onBack: () -> Void

    @State private var teams: [LinearClient.LinearTeam] = []
    @State private var teamsLoading = true
    @State private var toolStatus: [String: ToolCheck] = [:]
    @State private var checkTimer: Timer?

    struct ToolCheck {
        let present: Bool
        let hint: String?   // non-nil only when not present or needs attention
    }

    private let requiredTools: [(name: String, installHint: String)] = [
        ("git",    "Included with Xcode Command Line Tools"),
        ("gh",     "brew install gh  →  gh auth login"),
        ("claude", "Install from claude.ai/code"),
    ]

    private var reposValid: Bool {
        repos.contains { !$0.path.isEmpty && !$0.issuePrefix.isEmpty }
    }

    private var toolsOK: Bool {
        requiredTools.allSatisfy { toolStatus[$0.name]?.present == true }
    }

    private var canContinue: Bool { reposValid && toolsOK }

    var body: some View {
        StepShell(
            emoji: "🗂️",
            title: "Your Workspace",
            subtitle: "Map your Linear teams to local repos.",
            backAction: onBack,
            nextEnabled: canContinue,
            nextAction: onNext
        ) {
            VStack(spacing: 14) {
                prereqBar
                repoList
            }
        }
        .onAppear {
            loadTeams()
            runToolChecks()
            checkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in runToolChecks() }
            }
        }
        .onDisappear { checkTimer?.invalidate() }
    }

    // MARK: - Prereq bar (compact horizontal pills)

    private var prereqBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREREQUISITES")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                ForEach(requiredTools, id: \.name) { tool in
                    let check = toolStatus[tool.name]
                    HStack(spacing: 5) {
                        if check == nil {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        } else if check!.present {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LD.statusDone)
                                .font(.system(size: 11))
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LD.coral)
                                .font(.system(size: 11))
                        }
                        Text(tool.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.primary.opacity(0.05), in: Capsule())
                    .help(check?.hint ?? (check?.present == false ? tool.installHint : ""))
                }
                Spacer()
            }

            // Show hint for first failing tool
            if let failing = requiredTools.first(where: { toolStatus[$0.name]?.present == false }) {
                Text(toolStatus[failing.name]?.hint ?? failing.installHint)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Repo list

    private var repoList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REPOS")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            ForEach($repos) { $repo in
                OnboardingRepoRow(repo: $repo, teams: teams, teamsLoading: teamsLoading) {
                    if repos.count > 1 { repos.removeAll { $0.id == repo.id } }
                }
            }

            Button {
                repos.append(WorkspaceRepo(issuePrefix: "", path: ""))
            } label: {
                Label("Add another repo", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: - Load teams from Linear

    private func loadTeams() {
        guard !apiKey.isEmpty else { teamsLoading = false; return }
        Task.detached {
            let client = LinearClient()
            let fetched = (try? await client.fetchTeams(apiKey: apiKey)) ?? []
            Logger.onboarding.info("Fetched \(fetched.count) Linear teams")
            await MainActor.run {
                teams = fetched
                teamsLoading = false
                // Pre-fill prefix if we only have one team and one row
                if fetched.count == 1, repos.count == 1, repos[0].issuePrefix.isEmpty {
                    repos[0].issuePrefix = fetched[0].key
                }
            }
        }
    }

    // MARK: - Tool checks (login shell so PATH includes brew/npm/etc.)

    private func runToolChecks() {
        for tool in requiredTools {
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "cd /tmp && which \(tool.name)"]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                try? p.run(); p.waitUntilExit()
                var present = p.terminationStatus == 0

                var hint: String? = nil
                if present && tool.name == "gh" {
                    let auth = Process()
                    auth.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    auth.arguments = ["-l", "-c", "cd /tmp && gh auth status"]
                    auth.standardOutput = Pipe()
                    auth.standardError = Pipe()
                    try? auth.run(); auth.waitUntilExit()
                    if auth.terminationStatus != 0 {
                        present = false
                        hint = "gh found but not authenticated — run: gh auth login"
                    }
                }

                Logger.onboarding.debug("Tool check \(tool.name): present=\(present)")
                await MainActor.run {
                    toolStatus[tool.name] = ToolCheck(present: present, hint: hint)
                }
            }
        }
    }
}

// MARK: - Onboarding repo row

private struct OnboardingRepoRow: View {
    @Binding var repo: WorkspaceRepo
    let teams: [LinearClient.LinearTeam]
    let teamsLoading: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                // Team / prefix row
                HStack(spacing: 8) {
                    Text("Team")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    if teamsLoading {
                        ProgressView().scaleEffect(0.6)
                    } else if teams.isEmpty {
                        TextField("e.g. HRP", text: $repo.issuePrefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90)
                    } else {
                        Picker("", selection: $repo.issuePrefix) {
                            Text("Select…").tag("")
                            ForEach(teams) { team in
                                Text("\(team.key) — \(team.name)").tag(team.key)
                            }
                        }
                        .labelsHidden()
                        Spacer()
                    }
                }

                // Path row
                HStack(spacing: 8) {
                    Text(repo.allReposInFolder ? "Folder" : "Repo")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    TextField(repo.allReposInFolder ? "/path/to/projects" : "/path/to/repo", text: $repo.path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                // "All repos in folder" toggle
                HStack(spacing: 8) {
                    Spacer().frame(width: 44)
                    Toggle(isOn: $repo.allReposInFolder) {
                        Text("All repos in this folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                }

                // Home repo (only relevant in multi-repo mode)
                if repo.allReposInFolder {
                    HStack(spacing: 8) {
                        Text("Home")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        TextField("e.g. memory", text: $repo.homeRepo)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("optional")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .help("Subdirectory where Claude launches. Create LEMON.md there with repo navigation instructions for this team.")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LD.coral.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }
}

// MARK: - Step 4: Local AI

private struct LocalAIStep: View {
    let onNext: () -> Void
    let onBack: () -> Void

    // Prereq checks
    @State private var toolStatus: [String: Bool] = [:]
    @State private var hfLoginStatus: HFLoginStatus = .unknown
    @State private var checkTimer: Timer?

    // Model download
    @State private var downloadState: DownloadState = .idle
    @State private var downloadProcess: Process?
    @State private var downloadedMB: Int64 = 0
    @State private var downloadTimer: Timer?

    // SwiftLM binary path (user-provided)
    @State private var swiftLMPath = KeychainStore.shared.swiftLMPath

    enum HFLoginStatus { case unknown, loggedIn(String), notLoggedIn }
    enum DownloadState: Equatable { case idle, running, done, failed(String) }

    private var modelDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lemon/Models/gemma-4-e4b")
            .path
    }

    private var tmuxOK: Bool { toolStatus["tmux"] == true }
    private var hfOK: Bool { toolStatus["huggingface-cli"] == true }
    private var modelReady: Bool {
        if case .done = downloadState { return true }
        return FileManager.default.fileExists(atPath: modelDir + "/config.json")
    }
    private var canEnable: Bool { tmuxOK && modelReady && !swiftLMPath.isEmpty }

    var body: some View {
        StepShell(
            emoji: "🤖",
            title: "Local AI (optional)",
            subtitle: "Gemma 4B watches sessions and resolves obvious\nprompts — like accepting MCP servers — without interrupting you.",
            backAction: onBack,
            nextLabel: canEnable ? "Enable AI" : "Skip for now",
            nextEnabled: true,
            nextAction: { save(); onNext() }
        ) {
            VStack(spacing: 14) {
                prereqBar
                modelSection
                swiftLMSection
            }
        }
        .onAppear {
            if modelReady { downloadState = .done }
            runChecks()
            checkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in runChecks() }
            }
        }
        .onDisappear {
            checkTimer?.invalidate()
            downloadTimer?.invalidate()
        }
    }

    // MARK: - Prereq bar

    private var prereqBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREREQUISITES")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                prereqPill("tmux", present: toolStatus["tmux"], hint: "brew install tmux")
                prereqPill("huggingface-cli", present: toolStatus["huggingface-cli"], hint: "pip install huggingface_hub")
                Spacer()
            }

            // HF login advisory — not blocking
            switch hfLoginStatus {
            case .unknown:
                EmptyView()
            case .loggedIn(let user):
                HStack(spacing: 5) {
                    Image(systemName: "person.circle.fill").foregroundStyle(LD.statusDone).font(.system(size: 11))
                    Text("HuggingFace: \(user)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            case .notLoggedIn:
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).font(.system(size: 11))
                    Text("Not logged in to HuggingFace — run `huggingface-cli login` if model access requires it")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            // Show hint for first missing required tool
            if let hint = missingHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    private var missingHint: String? {
        if toolStatus["tmux"] == false { return "Install tmux: brew install tmux" }
        if toolStatus["huggingface-cli"] == false { return "Install HuggingFace CLI: pip install huggingface_hub" }
        return nil
    }

    private func prereqPill(_ name: String, present: Bool?, hint: String) -> some View {
        HStack(spacing: 5) {
            if present == nil {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
            } else if present == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LD.statusDone).font(.system(size: 11))
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(LD.coral).font(.system(size: 11))
            }
            Text(name).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
        .help(present == false ? hint : "")
    }

    // MARK: - Model download section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GEMMA 4B MODEL")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            switch downloadState {
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    Text("mlx-community/gemma-4-e4b-it-OptiQ-4bit  (~2.5 GB)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button {
                        startDownload()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Gemma 4B")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LemonButtonStyle())
                    .disabled(!hfOK)
                }

            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.75)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloading…").font(.system(size: 12, weight: .semibold))
                            Text("\(downloadedMB) MB of ~2,500 MB")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { cancelDownload() }
                            .buttonStyle(GhostButtonStyle())
                    }
                    ProgressView(value: Double(downloadedMB), total: 2500)
                        .tint(LD.lemon)
                }
                .padding(12)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))

            case .done:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(LD.statusDone).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model ready").font(.system(size: 11, weight: .semibold))
                        Text(modelDir)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(12)
                .background(LD.statusDone.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))

            case .failed(let err):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral)
                        Text("Download failed").font(.system(size: 12, weight: .semibold))
                    }
                    Text(err).font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Try Again") { startDownload() }.buttonStyle(GhostButtonStyle())
                }
                .padding(12)
                .background(LD.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - SwiftLM section

    private var swiftLMSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SWIFTLM BINARY")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                TextField("/path/to/swiftlm", text: $swiftLMPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.title = "Select SwiftLM binary"
                    if panel.runModal() == .OK, let url = panel.url {
                        swiftLMPath = url.path
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(GhostButtonStyle())
            }

            Text("Build SwiftLM from github.com/jkrukowski/SwiftLM (swift build -c release). Point here to the binary.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Actions

    private func runChecks() {
        for tool in ["tmux", "huggingface-cli"] {
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "cd /tmp && which \(tool)"]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                try? p.run(); p.waitUntilExit()
                let present = p.terminationStatus == 0
                await MainActor.run { toolStatus[tool] = present }
            }
        }

        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", "cd /tmp && huggingface-cli whoami 2>/dev/null | head -1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status: HFLoginStatus = raw.isEmpty ? .notLoggedIn : .loggedIn(raw)
            await MainActor.run { hfLoginStatus = status }
        }
    }

    private func startDownload() {
        downloadState = .running

        let dir = modelDir
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c",
            "cd /tmp && huggingface-cli download mlx-community/gemma-4-e4b-it-OptiQ-4bit" +
            " --local-dir '\(dir)'"
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        downloadProcess = p

        // Poll directory size every 2s for progress
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                downloadedMB = dirSizeMB(dir)
                if modelReady && downloadState == .running {
                    downloadState = .done
                    downloadTimer?.invalidate()
                }
            }
        }

        Task.detached {
            do {
                try p.run()
                p.waitUntilExit()
                await MainActor.run {
                    downloadTimer?.invalidate()
                    if p.terminationStatus == 0 {
                        downloadState = .done
                    } else {
                        downloadState = .failed("huggingface-cli exited \(p.terminationStatus) — check that it's installed and the model is accessible")
                    }
                }
            } catch {
                await MainActor.run {
                    downloadTimer?.invalidate()
                    downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func cancelDownload() {
        downloadProcess?.terminate()
        downloadProcess = nil
        downloadTimer?.invalidate()
        downloadState = .idle
        downloadedMB = 0
    }

    private func dirSizeMB(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let file as String in enumerator {
            let full = (path as NSString).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total / 1_048_576
    }

    private func save() {
        guard canEnable else { return }
        let k = KeychainStore.shared
        k.modelPath = modelDir
        k.swiftLMPath = swiftLMPath
        k.aiEnabled = true
    }
}

// MARK: - Step 3: Ready

private struct ReadyStep: View {
    let apiKey: String
    let onFinish: () -> Void
    let onBack: () -> Void

    @State private var claudeAccount: String? = nil
    @State private var claudeChecked = false

    enum LabelState { case pending, creating, done(Int), failed(String) }
    @State private var labelState: LabelState = .pending

    private var canStart: Bool {
        guard claudeChecked else { return false }
        switch labelState {
        case .pending, .creating: return false
        default: return true
        }
    }

    private var labelsReady: Bool {
        if case .done = labelState { return true }
        return false
    }

    var body: some View {
        StepShell(
            emoji: "✅",
            title: "You're all set",
            subtitle: "Lemon is ready. Label any Linear issue with 🍋\nand Lemon will pick it up within 60 seconds.",
            backAction: onBack,
            nextLabel: "Start Lemon",
            nextEnabled: canStart,
            nextAction: onFinish
        ) {
            VStack(spacing: 12) {
                // Claude auth status
                statusRow(
                    checked: claudeChecked,
                    pendingText: "Detecting Claude Code auth…",
                    successIcon: "checkmark.circle.fill",
                    successTitle: claudeAccount.map { "Using Claude Code as \($0)" } ?? "Using Claude Code",
                    successColor: LD.statusDone,
                    warningTitle: "Claude Code not authenticated",
                    warningDetail: "Run `claude login` in Terminal, then come back."
                )

                // Linear labels + workflow education
                linearLabelsRow
            }
        }
        .onAppear {
            detectClaudeAuth()
            createLinearLabels()
        }
    }

    // MARK: - Label creation + workflow education

    private var linearLabelsRow: some View {
        VStack(spacing: 0) {
            // Status header
            HStack(spacing: 8) {
                switch labelState {
                case .pending:
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Connecting to Linear…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .creating:
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Creating Lemon labels…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .done(let count):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LD.statusDone).font(.system(size: 13))
                    Text("Labels ready in \(count) team\(count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LD.coral).font(.system(size: 13))
                    Text("Labels will be created on first start")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 8)

            // Workflow pipeline — teaches lifecycle even while loading
            VStack(spacing: 0) {
                workflowRow("🍋", nil, "Tag it", "Add to any issue to queue it for Lemon", LD.lemon, false)
                workflowRow("🍋", "In Progress", "Working", "Claude opens Terminal and gets to work", LD.statusPlanning, false)
                workflowRow("🍋", "Waiting", "Needs you", "Claude paused — phone notification sent", LD.statusWaiting, false)
                workflowRow("🍋", "Complete", "PR open", "Reply to the Lemon comment to request changes", LD.statusDone, true)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .opacity(labelsReady ? 1.0 : 0.45)
            .animation(LD.smooth, value: labelsReady)
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    @ViewBuilder
    private func workflowRow(_ emoji: String, _ name: String?, _ action: String, _ detail: String, _ color: Color, _ isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 14)
                if !isLast {
                    Rectangle()
                        .fill(.primary.opacity(0.1))
                        .frame(width: 1, height: 16)
                }
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    HStack(spacing: 2) {
                        Text(emoji).font(.system(size: 9))
                        if let n = name {
                            Text(n).font(.system(size: 9, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())

                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Text(action)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }

    // MARK: - Generic status row

    private func statusRow(
        checked: Bool,
        pendingText: String,
        successIcon: String,
        successTitle: String,
        successColor: Color,
        warningTitle: String,
        warningDetail: String
    ) -> some View {
        Group {
            if !checked {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text(pendingText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            } else if claudeAccount != nil {
                HStack(spacing: 10) {
                    Image(systemName: successIcon).foregroundStyle(successColor).font(.system(size: 16))
                    Text(successTitle).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(14)
                .background(successColor.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warningTitle).font(.system(size: 12, weight: .semibold))
                        Text(warningDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(LD.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
    }

    // MARK: - Label creation

    private func createLinearLabels() {
        labelState = .creating
        let key = apiKey
        Task.detached {
            let client = LinearClient()
            do {
                let teams = try await client.fetchTeams(apiKey: key)
                Logger.onboarding.info("Creating Lemon labels for \(teams.count) team(s)")
                for team in teams {
                    for label in [LinearClient.labelTrigger, LinearClient.labelInProgress,
                                  LinearClient.labelWaiting, LinearClient.labelComplete] {
                        _ = try await client.ensureLabelId(name: label, teamId: team.id, apiKey: key)
                    }
                }
                await MainActor.run { labelState = .done(teams.count) }
            } catch {
                Logger.onboarding.error("Label creation failed: \(error)")
                await MainActor.run { labelState = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Claude auth

    private func detectClaudeAuth() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", "cd /tmp && claude whoami 2>/dev/null | head -1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()

            var account: String? = nil
            if p.terminationStatus == 0 {
                let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if let raw, !raw.isEmpty { account = raw }
            }

            await MainActor.run {
                claudeAccount = account
                claudeChecked = true
            }
        }
    }
}

// MARK: - Step 3: LEMON.md Proposal

private struct LemonMdStep: View {
    let repos: [WorkspaceRepo]
    let onNext: () -> Void
    let onBack: () -> Void

    enum ProposalState { case idle, analyzing, ready, failed(String) }

    @State private var proposalState: ProposalState = .idle
    @State private var editedContent = ""
    @State private var saved = false

    private var primaryRepo: WorkspaceRepo? {
        repos.first { !$0.path.isEmpty }
    }

    private var lemonMdPath: String? {
        guard let repo = primaryRepo else { return nil }
        if repo.allReposInFolder && !repo.homeRepo.isEmpty {
            return "\(repo.path)/\(repo.homeRepo)/LEMON.md"
        }
        return "\(repo.path)/LEMON.md"
    }

    var body: some View {
        StepShell(
            emoji: "📋",
            title: "Team Instructions",
            subtitle: "LEMON.md tells Lemon how your codebase works.\nClaude will draft one — edit before saving.",
            backAction: onBack,
            nextLabel: saved ? "Continue" : "Skip for now",
            nextEnabled: true,
            nextAction: onNext
        ) {
            VStack(spacing: 14) {
                switch proposalState {
                case .idle:
                    idleView
                case .analyzing:
                    analyzingView
                case .ready:
                    editorView
                case .failed(let err):
                    failedView(err)
                }

                if saved, let path = lemonMdPath {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LD.statusDone).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved").font(.system(size: 11, weight: .semibold))
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(LD.statusDone.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
                }
            }
        }
        .onAppear { checkExisting() }
    }

    // MARK: - State views

    private var idleView: some View {
        VStack(spacing: 12) {
            if let path = lemonMdPath {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11)).foregroundStyle(LD.lemon)
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            }

            Button {
                analyze()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Propose LEMON.md with Claude")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LemonButtonStyle())
            .disabled(primaryRepo == nil)

            Text("Claude reviews your repo structure and writes\noperating instructions Lemon reads before each task.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var analyzingView: some View {
        HStack(spacing: 12) {
            ProgressView().scaleEffect(0.75)
            VStack(alignment: .leading, spacing: 3) {
                Text("Analyzing your codebase…")
                    .font(.system(size: 12, weight: .semibold))
                Text("Reviewing structure, README, and recent commits")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LEMON.md")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(LemonButtonStyle())
            }
            TextEditor(text: $editedContent)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 200, maxHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
                .overlay(RoundedRectangle(cornerRadius: LD.r10).stroke(.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func failedView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral)
                Text("Analysis failed").font(.system(size: 12, weight: .semibold))
            }
            Text(err).font(.system(size: 10)).foregroundStyle(.secondary)
            Button("Try Again") { analyze() }.buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .background(LD.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Actions

    private func checkExisting() {
        guard let path = lemonMdPath,
              let existing = try? String(contentsOfFile: path, encoding: .utf8),
              !existing.isEmpty else { return }
        editedContent = existing
        proposalState = .ready
    }

    private func analyze() {
        guard let repo = primaryRepo else { return }
        proposalState = .analyzing

        let repoPath = repo.allReposInFolder && !repo.homeRepo.isEmpty
            ? "\(repo.path)/\(repo.homeRepo)"
            : repo.path

        let addDirs = repos
            .filter { !$0.path.isEmpty }
            .map { "--add-dir '\($0.path)'" }
            .joined(separator: " ")

        Task.detached {
            let promptContent = """
            Analyze the repository at: \(repoPath)

            Look at the file structure, README, and recent git history.
            Write a LEMON.md file (under 400 words) that helps an AI coding assistant understand this codebase.

            Include:
            1. What this project is and does (2-3 sentences)
            2. Key directories and their purposes
            3. How to start the dev server and run tests
            4. Deployment process and branch rules
            5. Important conventions or constraints

            IMPORTANT: Print the markdown to stdout only. Do NOT write or create any files.
            Start the output with # LEMON.md
            """

            let ts = Int(Date().timeIntervalSince1970)
            let promptPath = "/tmp/lemon-lemonmd-prompt-\(ts).txt"

            do {
                try promptContent.write(toFile: promptPath, atomically: true, encoding: .utf8)

                // Build --add-dir flags as separate arguments to avoid quoting issues
                let args = ["-l", "-c", "cd /tmp && claude -p \(addDirs) < '\(promptPath)'"]

                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                try p.run()
                p.waitUntilExit()

                let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                try? FileManager.default.removeItem(atPath: promptPath)

                Logger.onboarding.info("LEMON.md claude exit \(p.terminationStatus), out=\(trimmed.count) chars, err=\(errOutput.prefix(200))")

                await MainActor.run {
                    if p.terminationStatus == 0 && !trimmed.isEmpty {
                        editedContent = trimmed
                        proposalState = .ready
                    } else {
                        let detail = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let msg = detail.isEmpty
                            ? "Exit \(p.terminationStatus) — check Console.app (lemon) for details"
                            : String(detail.prefix(300))
                        proposalState = .failed(msg)
                    }
                }
            } catch {
                await MainActor.run { proposalState = .failed(error.localizedDescription) }
            }
        }
    }

    private func save() {
        guard let path = lemonMdPath, !editedContent.isEmpty else { return }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try editedContent.write(toFile: path, atomically: true, encoding: .utf8)
            Logger.onboarding.info("Saved LEMON.md to \(path)")
            withAnimation(LD.smooth) { saved = true }
        } catch {
            Logger.onboarding.error("Failed to save LEMON.md: \(error)")
        }
    }
}
