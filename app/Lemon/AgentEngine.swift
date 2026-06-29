import Foundation
import os

protocol AgentEngine: Sendable {
    var kind: AgentEngineKind { get }
    func launch(request: WorktreeRunner.EngineLaunchRequest,
                runner: WorktreeRunner) async -> WorktreeRunner.LaunchFailure?
    func executionHealthy(slug: String) async -> Bool
    func readiness(config: WorkspaceEngineConfig) -> AgentEngineReadiness
}

struct AgentEngineReadiness {
    struct Check: Identifiable {
        enum Status {
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
                runner: WorktreeRunner) async -> WorktreeRunner.LaunchFailure?
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

    func executionHealthy(slug _: String) async -> Bool {
        true
    }
}

struct OpenCodeEngine: AgentEngine {
    let kind: AgentEngineKind = .openCode
    private let config: WorkspaceEngineConfig

    init(config: WorkspaceEngineConfig = WorkspaceEngineConfig(kind: .openCode, openCode: nil)) {
        self.config = config
    }

    func launch(request: WorktreeRunner.EngineLaunchRequest,
                runner _: WorktreeRunner) async -> WorktreeRunner.LaunchFailure?
    {
        let openCode = config.openCode ?? OpenCodeWorkspaceConfig()
        guard AgentEngineShell.commandExists("opencode") else {
            return .binaryMissing("opencode")
        }
        let authPath = NSHomeDirectory() + "/.local/share/opencode/auth.json"
        guard FileManager.default.fileExists(atPath: authPath) else {
            return .launchError("OpenCode auth missing at ~/.local/share/opencode/auth.json (run `opencode auth login`)")
        }
        guard openCode.models.hasAllConfigured else {
            return .launchError("OpenCode model slots are incomplete (set plan/code/review models)")
        }

        let daemon = OpenCodeDaemonManager.shared
        let ensure = await daemon.ensureRunning(config: openCode.daemon)
        switch ensure {
        case .ready:
            break
        case .notInstalled:
            return .binaryMissing("opencode")
        case let .startFailed(msg):
            return .launchError("OpenCode daemon failed to start: \(msg)")
        case .unhealthy:
            return .launchError("OpenCode daemon is running but unhealthy (/doc unavailable)")
        }

        let planPath = "/tmp/lemon-plan-\(request.slug).md"
        let gatePath = "/tmp/lemon-gate-\(request.slug)"
        let kickoffPrompt = WorktreeRunner.kickoffPrompt(planMode: false, planPath: planPath, gatePath: gatePath)

        let client = OpenCodeClient(host: openCode.daemon.host, port: openCode.daemon.port)
        do {
            let created = try await client.createSession(.init(
                model: openCode.models.code,
                dir: request.sessionPath,
                agent: nil,
            ))
            try await client.sendMessage(
                sessionID: created.id,
                body: .init(content: kickoffPrompt, prompt_async: true),
            )
            try? created.id.write(toFile: WorktreeRunner.openCodeSessionPath(slug: request.slug),
                                  atomically: true,
                                  encoding: .utf8)
            Logger.opencode.info("[opencode] launched session \(created.id, privacy: .public) for \(request.slug, privacy: .public)")
            return nil
        } catch {
            Logger.opencode.error("[opencode] launch failed for \(request.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .launchError("OpenCode launch failed: \(error.localizedDescription)")
        }
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
            .init(
                id: "opencode-launch",
                title: "Lemon launch bridge",
                detail: "Lemon can launch OpenCode sessions via daemon API.",
                status: .pass,
            ),
        ])
    }

    func executionHealthy(slug: String) async -> Bool {
        let openCode = config.openCode ?? OpenCodeWorkspaceConfig()
        let client = OpenCodeClient(host: openCode.daemon.host, port: openCode.daemon.port)
        guard await client.docReachable() else { return false }

        let sessionPath = WorktreeRunner.openCodeSessionPath(slug: slug)
        guard let sessionID = try? String(contentsOfFile: sessionPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionID.isEmpty
        else { return true }

        let liveness = await client.sessionLiveness(sessionID: sessionID)
        switch liveness {
        case .active:
            return true
        case .unknown:
            // Schema drift-safe default: if /session responds but we cannot infer
            // a terminal state, keep the run alive and let label/terminal-state
            // signals resolve completion.
            return true
        case .terminal:
            return false
        }
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
