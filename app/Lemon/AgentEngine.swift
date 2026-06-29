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
        let malformed = openCode.models.malformedConfiguredModels
        guard malformed.isEmpty else {
            let joined = malformed.joined(separator: ", ")
            return .launchError("OpenCode model IDs must use provider/model format; invalid: \(joined)")
        }

        let authValidation = OpenCodeAuthInspector.validateProviderCredentials(
            requiredProviders: openCode.models.requiredProviders,
            authPath: authPath,
        )
        if case let .missing(providers) = authValidation {
            return .launchError("OpenCode auth is missing credentials for provider(s): \(providers.joined(separator: ", "))")
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
        let malformedModels = openCode.models.malformedConfiguredModels
        let requiredProviders = openCode.models.requiredProviders
        let providerAuth = OpenCodeAuthInspector.validateProviderCredentials(
            requiredProviders: requiredProviders,
            authPath: authPath,
        )
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
                detail: {
                    if !hasModels {
                        return "Set all three model slots (provider/model)."
                    }
                    if !malformedModels.isEmpty {
                        return "Invalid model format: \(malformedModels.joined(separator: ", "))."
                    }
                    return "All three model slots are set."
                }(),
                status: hasModels && malformedModels.isEmpty ? .pass : .fail,
            ),
            .init(
                id: "opencode-provider-auth",
                title: "Provider keys for selected models",
                detail: {
                    guard hasAuth else {
                        return "Run `opencode auth login` first."
                    }
                    guard hasModels, malformedModels.isEmpty else {
                        return "Set valid provider/model IDs to verify provider keys."
                    }
                    switch providerAuth {
                    case .allPresent:
                        return "Credentials found for: \(requiredProviders.joined(separator: ", "))."
                    case let .missing(providers):
                        return "Missing credentials for: \(providers.joined(separator: ", "))."
                    case let .unverifiable(reason):
                        return "Could not verify provider keys from auth.json (\(reason))."
                    }
                }(),
                status: {
                    guard hasAuth, hasModels, malformedModels.isEmpty else { return .fail }
                    switch providerAuth {
                    case .allPresent, .unverifiable:
                        return .pass
                    case .missing:
                        return .fail
                    }
                }(),
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

enum OpenCodeAuthValidation: Equatable {
    case allPresent
    case missing([String])
    case unverifiable(String)
}

enum OpenCodeAuthInspector {
    static func validateProviderCredentials(requiredProviders: [String], authPath: String) -> OpenCodeAuthValidation {
        guard !requiredProviders.isEmpty else { return .allPresent }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)) else {
            return .missing(requiredProviders)
        }
        return validateProviderCredentials(requiredProviders: requiredProviders, authData: data)
    }

    static func validateProviderCredentials(requiredProviders: [String], authData: Data) -> OpenCodeAuthValidation {
        guard !requiredProviders.isEmpty else { return .allPresent }
        guard let json = try? JSONSerialization.jsonObject(with: authData) else {
            return .unverifiable("invalid json")
        }

        let missing = requiredProviders.filter { !providerHasCredential($0, in: json, inProviderContext: false) }
        return missing.isEmpty ? .allPresent : .missing(missing)
    }

    private static let credentialKeyHints = [
        "api_key", "apikey", "token", "access_token", "key", "secret", "pat",
    ]

    private static func providerHasCredential(_ provider: String,
                                              in node: Any,
                                              inProviderContext: Bool) -> Bool
    {
        switch node {
        case let dict as [String: Any]:
            for (key, value) in dict {
                let lowered = key.lowercased()
                let keyMentionsProvider = lowered == provider || lowered.contains(provider)
                let providerContext = inProviderContext || keyMentionsProvider

                if providerContext,
                   isCredentialKey(lowered),
                   hasNonEmptyCredentialScalar(value)
                {
                    return true
                }

                if keyMentionsProvider,
                   isCredentialKey(lowered),
                   hasNonEmptyCredentialScalar(value)
                {
                    return true
                }

                if providerHasCredential(provider, in: value, inProviderContext: providerContext) {
                    return true
                }
            }
            return false

        case let array as [Any]:
            return array.contains { providerHasCredential(provider, in: $0, inProviderContext: inProviderContext) }

        default:
            return false
        }
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        credentialKeyHints.contains(where: { key.contains($0) })
    }

    private static func hasNonEmptyCredentialScalar(_ value: Any) -> Bool {
        if let text = value as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let number = value as? NSNumber {
            return number.doubleValue != 0
        }
        return false
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
