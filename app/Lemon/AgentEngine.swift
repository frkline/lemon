import Foundation

protocol AgentEngine: Sendable {
    var kind: AgentEngineKind { get }
    func launch(request: WorktreeRunner.EngineLaunchRequest,
                runner: WorktreeRunner) -> WorktreeRunner.LaunchFailure?
    func readiness(config: WorkspaceEngineConfig) -> AgentEngineReadiness
}

struct AgentEngineReadiness: Sendable {
    struct Check: Identifiable, Sendable {
        enum Status: Sendable {
            case pass
            case fail
        }

        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    let checks: [Check]

    var isReady: Bool {
        checks.allSatisfy { $0.status == .pass }
    }
}

enum AgentEngineFactory {
    static func make(config: WorkspaceEngineConfig) -> any AgentEngine {
        switch config.kind {
        case .claudeCode:
            ClaudeCodeEngine()
        case .openCode:
            OpenCodeEngine(config: config)
        }
    }

    static func make(kind: AgentEngineKind) -> any AgentEngine {
        make(config: WorkspaceEngineConfig(kind: kind, openCode: nil))
    }
}

struct ClaudeCodeEngine: AgentEngine {
    let kind: AgentEngineKind = .claudeCode

    func launch(request: WorktreeRunner.EngineLaunchRequest,
                runner: WorktreeRunner) -> WorktreeRunner.LaunchFailure?
    {
        runner.launchTmux(
            sessionPath: request.sessionPath,
            slug: request.slug,
            sessionLabel: request.sessionLabel,
            sentinelPath: request.sentinelPath,
            mcpConfigPath: request.mcpConfigPath,
            planMode: request.planMode,
        )
    }

    func readiness(config _: WorkspaceEngineConfig) -> AgentEngineReadiness {
        let hasClaude = AgentEngineShell.commandExists("claude")
        let hasTmux = AgentEngineShell.commandExists("tmux")
        let hasGh = AgentEngineShell.commandExists("gh")
        let hasHf = AgentEngineShell.commandExists("hf")
        let account = hasClaude ? AgentEngineShell.firstLine(of: "claude whoami 2>/dev/null") : ""

        return AgentEngineReadiness(checks: [
            .init(
                id: "claude-bin",
                title: "Claude Code installed",
                detail: hasClaude ? "`claude` found on PATH." : "Install with `brew install claude-code`.",
                status: hasClaude ? .pass : .fail,
            ),
            .init(
                id: "claude-login",
                title: "Claude login",
                detail: account.isEmpty ? "Run `claude login` in Terminal." : "Signed in as \(account).",
                status: account.isEmpty ? .fail : .pass,
            ),
            .init(
                id: "tmux-bin",
                title: "tmux installed",
                detail: hasTmux ? "`tmux` found on PATH." : "Install with `brew install tmux`.",
                status: hasTmux ? .pass : .fail,
            ),
            .init(
                id: "gh-bin",
                title: "GitHub CLI installed",
                detail: hasGh ? "`gh` found on PATH." : "Install with `brew install gh`.",
                status: hasGh ? .pass : .fail,
            ),
            .init(
                id: "hf-bin",
                title: "Hugging Face CLI installed",
                detail: hasHf ? "`hf` found on PATH." : "Install with `brew install hf`.",
                status: hasHf ? .pass : .fail,
            ),
        ])
    }
}

struct OpenCodeEngine: AgentEngine {
    let kind: AgentEngineKind = .openCode
    private let config: WorkspaceEngineConfig

    init(config: WorkspaceEngineConfig = WorkspaceEngineConfig(kind: .openCode, openCode: nil)) {
        self.config = config
    }

    func launch(request _: WorktreeRunner.EngineLaunchRequest,
                runner _: WorktreeRunner) -> WorktreeRunner.LaunchFailure?
    {
        let readiness = readiness(config: config)
        if let firstFailure = readiness.checks.first(where: { $0.status == .fail }) {
            return .launchError("OpenCode not ready: \(firstFailure.title). \(firstFailure.detail)")
        }
        return .launchError("OpenCode selected, but execution pipeline is not wired yet (session/event loop integration pending)")
    }

    func readiness(config: WorkspaceEngineConfig) -> AgentEngineReadiness {
        let hasOpenCode = AgentEngineShell.commandExists("opencode")
        let version = hasOpenCode ? AgentEngineShell.firstLine(of: "opencode --version 2>/dev/null") : ""
        let authPath = NSHomeDirectory() + "/.local/share/opencode/auth.json"
        let hasAuth = FileManager.default.fileExists(atPath: authPath)
        let openCode = config.openCode ?? OpenCodeWorkspaceConfig()
        let hasModels = openCode.models.hasAllConfigured
        let daemonURL = "http://\(openCode.daemon.host):\(openCode.daemon.port)/doc"
        let daemonReachable = AgentEngineShell.httpReachable(url: daemonURL)

        return AgentEngineReadiness(checks: [
            .init(
                id: "opencode-runtime",
                title: "Execution pipeline",
                detail: "OpenCode run/poll lifecycle is still being wired in Lemon.",
                status: .fail,
            ),
            .init(
                id: "opencode-bin",
                title: "OpenCode installed",
                detail: hasOpenCode
                    ? (version.isEmpty ? "`opencode` found on PATH." : version)
                    : "Install with `brew install anomalyco/tap/opencode`.",
                status: hasOpenCode ? .pass : .fail,
            ),
            .init(
                id: "opencode-auth",
                title: "Provider auth",
                detail: hasAuth
                    ? "Found `~/.local/share/opencode/auth.json`."
                    : "Run `opencode auth login` to create auth.json.",
                status: hasAuth ? .pass : .fail,
            ),
            .init(
                id: "opencode-models",
                title: "Plan/Code/Review models",
                detail: hasModels ? "All three model slots are set." : "Set all three model slots (provider/model).",
                status: hasModels ? .pass : .fail,
            ),
            .init(
                id: "opencode-daemon",
                title: "Daemon health",
                detail: daemonReachable ? "`/doc` responded at \(daemonURL)." : "No `/doc` response at \(daemonURL).",
                status: daemonReachable ? .pass : .fail,
            ),
        ])
    }
}

enum AgentEngineShell {
    static func commandExists(_ binary: String) -> Bool {
        run("command -v \(shellQuote(binary)) >/dev/null 2>&1").ok
    }

    static func firstLine(of command: String) -> String {
        let result = run("\(command) | head -1")
        guard result.ok else { return "" }
        return result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func httpReachable(url: String) -> Bool {
        run("curl -fsS --max-time 2 \(shellQuote(url)) >/dev/null 2>&1").ok
    }

    static func run(_ command: String) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd /tmp && \(command)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (p.terminationStatus == 0, text)
        } catch {
            return (false, "")
        }
    }

    private static func shellQuote(_ input: String) -> String {
        "'\(input.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
