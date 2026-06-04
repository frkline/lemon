import Foundation
import os

// Manages git worktrees and a claude --auto --remote-control session for one Linear issue.
// Supports single-repo and multi-repo (all git repos in a folder) modes.
final class WorktreeRunner: @unchecked Sendable {
    private let linear = LinearClient()
    private var pollTask: Task<Void, Never>?
    private var stopped = false
    private var pendingActionTask: Task<Void, Never>?

    var onStatusChange: ((SessionStatus) -> Void)?
    var onLogLine: ((String) -> Void)?
    var onPRUrl: ((String) -> Void)?
    var onAiSummary: ((String) -> Void)?
    var onPendingAction: ((String?) -> Void)?

    func cancelPendingAction() {
        pendingActionTask?.cancel()
        pendingActionTask = nil
        onPendingAction?(nil)
    }

    // MARK: - Entry point

    func run(issue: LinearIssue, workspace: WorkspaceRepo, retrigger: LemonMarker? = nil) async {
        let apiKey = KeychainStore.shared.linearApiKey
        let identifier = issue.identifier
        let branch = retrigger?.branch ?? "lemon/\(identifier.lowercased())"
        let sessionPath = "/tmp/lemon-\(identifier.lowercased())"
        let homeRepo = workspace.homeRepo.trimmingCharacters(in: .whitespacesAndNewlines)

        log("[lemon] starting session for \(identifier)")
        onStatusChange?(.planning)

        // Resolve label IDs, creating any that don't exist yet.
        var labelIds: [String: String] = [:]
        for labelName in [LinearClient.labelTrigger, LinearClient.labelInProgress,
                          LinearClient.labelWaiting, LinearClient.labelComplete] {
            if let lid = try? await linear.ensureLabelId(name: labelName, teamId: issue.teamId, apiKey: apiKey) {
                labelIds[labelName] = lid
            }
        }

        // Discover repos to include in this session.
        let repos: [(name: String, repoPath: String)]
        if workspace.allReposInFolder {
            repos = discoverRepos(in: workspace.path)
            guard !repos.isEmpty else {
                log("[lemon] no git repos found in \(workspace.path)", level: .error)
                onStatusChange?(.failed)
                return
            }
            log("[lemon] found repos: \(repos.map { $0.name }.joined(separator: ", "))")
        } else {
            let name = URL(fileURLWithPath: workspace.path).lastPathComponent
            repos = [(name: name, repoPath: workspace.path)]
        }

        // Set up worktrees.
        do {
            try await setupWorktrees(
                repos: repos,
                sessionPath: sessionPath,
                isMultiRepo: workspace.allReposInFolder,
                branch: branch,
                isRetrigger: retrigger != nil
            )
        } catch {
            let msg = error.localizedDescription
            log("[lemon] worktree setup failed: \(msg)", level: .error)
            // Clean up Linear so the issue is in a neutral state.
            // User can retry by re-adding the 🍋 label.
            if let triggerId = labelIds[LinearClient.labelTrigger] {
                try? await linear.removeLabel(issueId: issue.id, labelId: triggerId, apiKey: apiKey)
            }
            if let inProgressId = labelIds[LinearClient.labelInProgress] {
                try? await linear.removeLabel(issueId: issue.id, labelId: inProgressId, apiKey: apiKey)
            }
            _ = try? await linear.postComment(
                issueId: issue.id,
                body: "🍋 Session failed to start: \(msg)\n\nRe-add the 🍋 label to retry.",
                apiKey: apiKey
            )
            onStatusChange?(.failed)
            return
        }

        // Write issue context for Claude. Team instructions from {homeRepo}/LEMON.md come first.
        let lemonMdPath = homeRepo.isEmpty ? nil : "\(workspace.path)/\(homeRepo)/LEMON.md"
        let devPort = Self.devPort(for: identifier)
        writeContext(
            to: sessionPath,
            issue: issue,
            repos: workspace.allReposInFolder ? repos : [],
            lemonMdPath: lemonMdPath,
            devPort: devPort
        )

        // Update Linear labels.
        if let triggerId = labelIds[LinearClient.labelTrigger] {
            try? await linear.removeLabel(issueId: issue.id, labelId: triggerId, apiKey: apiKey)
        }
        if retrigger != nil, let completeId = labelIds[LinearClient.labelComplete] {
            try? await linear.removeLabel(issueId: issue.id, labelId: completeId, apiKey: apiKey)
        }
        if let inProgressId = labelIds[LinearClient.labelInProgress] {
            try? await linear.addLabel(issueId: issue.id, labelId: inProgressId, apiKey: apiKey)
        }

        // Launch Claude inside a tmux session, starting in homeRepo if configured.
        let launchPath = homeRepo.isEmpty ? sessionPath : "\(sessionPath)/\(homeRepo)"
        let sentinelPath = "/tmp/lemon-exit-\(identifier.lowercased())"
        // Remove any leftover sentinel and log from a prior run.
        try? FileManager.default.removeItem(atPath: sentinelPath)
        try? FileManager.default.removeItem(atPath: logPath(identifier))

        // Pre-merge .mcp.json files so Claude skips the interactive MCP discovery prompt.
        let mcpConfigPath = prepareMcpConfig(sessionPath: sessionPath, repos: repos,
                                             isMultiRepo: workspace.allReposInFolder,
                                             identifier: identifier)

        guard launchTmux(sessionPath: launchPath, identifier: identifier,
                         sentinelPath: sentinelPath, mcpConfigPath: mcpConfigPath) else {
            log("[lemon] tmux launch failed — session aborted", level: .error)
            if let triggerId = labelIds[LinearClient.labelTrigger] {
                try? await linear.removeLabel(issueId: issue.id, labelId: triggerId, apiKey: apiKey)
            }
            if let inProgressId = labelIds[LinearClient.labelInProgress] {
                try? await linear.removeLabel(issueId: issue.id, labelId: inProgressId, apiKey: apiKey)
            }
            _ = try? await linear.postComment(
                issueId: issue.id,
                body: "🍋 Failed to launch tmux session. Ensure tmux is installed (`brew install tmux`) and re-add the 🍋 label to retry.",
                apiKey: apiKey
            )
            onStatusChange?(.failed)
            return
        }
        onStatusChange?(.executing)
        log("[lemon] tmux session started — join: tmux attach -t \(tmuxSessionName(identifier))")

        await pollUntilDone(
            issue: issue,
            sessionPath: sessionPath,
            repos: repos,
            isMultiRepo: workspace.allReposInFolder,
            branch: branch,
            labelIds: labelIds,
            retrigger: retrigger,
            apiKey: apiKey,
            workspacePath: workspace.path,
            sentinelPath: sentinelPath
        )
    }

    func stop() {
        stopped = true
        pollTask?.cancel()
    }

    // MARK: - Repo discovery

    private func discoverRepos(in folderPath: String) -> [(name: String, repoPath: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }
        return contents.compactMap { name -> (name: String, repoPath: String)? in
            let repoPath = "\(folderPath)/\(name)"
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: "\(repoPath)/.git", isDirectory: &isDir) else { return nil }
            return (name: name, repoPath: repoPath)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Worktree setup

    private func setupWorktrees(
        repos: [(name: String, repoPath: String)],
        sessionPath: String,
        isMultiRepo: Bool,
        branch: String,
        isRetrigger: Bool
    ) async throws {
        if isMultiRepo {
            // Create the session root directory (not a worktree itself).
            try FileManager.default.createDirectory(atPath: sessionPath, withIntermediateDirectories: true)
            for repo in repos {
                let worktreePath = "\(sessionPath)/\(repo.name)"
                try await setupSingleWorktree(repoPath: repo.repoPath, worktreePath: worktreePath, branch: branch, isRetrigger: isRetrigger)
            }
        } else {
            // Single repo: worktree IS the session path.
            try await setupSingleWorktree(repoPath: repos[0].repoPath, worktreePath: sessionPath, branch: branch, isRetrigger: isRetrigger)
        }
    }

    private func setupSingleWorktree(
        repoPath: String,
        worktreePath: String,
        branch: String,
        isRetrigger: Bool
    ) async throws {
        // Remove any leftover worktree and orphaned branch from a previous failed run.
        _ = try? await shell("git -C \(q(repoPath)) worktree remove \(q(worktreePath)) --force")
        if !isRetrigger {
            _ = try? await shell("git -C \(q(repoPath)) branch -D \(branch)")
        }
        try await shell("git -C \(q(repoPath)) fetch origin")

        if isRetrigger {
            try await shell("git -C \(q(repoPath)) worktree add \(q(worktreePath)) \(branch)")
            try await shell("git -C \(q(worktreePath)) pull origin \(branch) --rebase || true")
        } else {
            let base = await defaultBranch(repoPath: repoPath)
            try await shell("git -C \(q(repoPath)) worktree add -b \(branch) \(q(worktreePath)) origin/\(base)")
        }
    }

    private func defaultBranch(repoPath: String) async -> String {
        let result = try? await shell("git -C \(q(repoPath)) remote show origin | grep 'HEAD branch' | awk '{print $NF}'")
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "main" : trimmed
    }

    // MARK: - Worktree cleanup

    private func cleanupWorktrees(
        repos: [(name: String, repoPath: String)],
        sessionPath: String,
        isMultiRepo: Bool,
        identifier: String
    ) async {
        if isMultiRepo {
            for repo in repos {
                let worktreePath = "\(sessionPath)/\(repo.name)"
                do {
                    try await shell("git -C \(q(repo.repoPath)) worktree remove \(q(worktreePath)) --force")
                } catch {
                    Logger.worktree.warning("Worktree remove failed for \(repo.name): \(error)")
                }
            }
            do {
                try FileManager.default.removeItem(atPath: sessionPath)
            } catch {
                Logger.worktree.warning("Session dir removal failed at \(sessionPath): \(error)")
            }
        } else {
            do {
                try await shell("git -C \(q(repos[0].repoPath)) worktree remove \(q(sessionPath)) --force")
            } catch {
                Logger.worktree.warning("Worktree remove failed at \(sessionPath): \(error)")
            }
        }
        // Kill tmux session and remove all per-session artefacts in /tmp so
        // repeated runs don't leak launcher scripts, sentinel files, merged
        // MCP configs, or pane logs.
        runSync("tmux kill-session -t '\(tmuxSessionName(identifier))' 2>/dev/null || true")
        let id = identifier.lowercased()
        let leftovers = [
            logPath(identifier),
            "/tmp/lemon-launch-\(id).sh",
            "/tmp/lemon-exit-\(id)",
            "/tmp/lemon-mcp-\(id).json",
        ]
        for path in leftovers {
            try? FileManager.default.removeItem(atPath: path)
        }
        log("[lemon] worktree(s) cleaned up")
    }

    // MARK: - Context file

    // Returns true when the silence detector should fire Gemma.
    // Extracted for unit testability — call sites pass `now` explicitly.
    static func shouldInvokeGemma(
        lastActivityAt: Date,
        lastGemmaAt: Date?,
        now: Date = Date(),
        silenceThreshold: TimeInterval = 120,
        cooldown: TimeInterval = 180
    ) -> Bool {
        let silence = now.timeIntervalSince(lastActivityAt)
        let gemmaCooldown = lastGemmaAt.map { now.timeIntervalSince($0) } ?? .infinity
        return silence > silenceThreshold && gemmaCooldown > cooldown
    }

    // Derives a stable dev server port from the issue number (e.g. HRP-42 → 3042).
    // Keeps concurrent sessions on different ports without coordination.
    static func devPort(for identifier: String) -> Int {
        let n = Int(identifier.split(separator: "-").last.flatMap(String.init) ?? "0") ?? 0
        return 3000 + (n % 1000)   // stays in 3000–3999, wraps for very large issue numbers
    }

    private func writeContext(
        to sessionPath: String,
        issue: LinearIssue,
        repos: [(name: String, repoPath: String)],
        lemonMdPath: String?,
        devPort: Int
    ) {
        var content = ""

        // Team operating instructions come first — Claude reads this before the issue.
        if let path = lemonMdPath,
           let instructions = try? String(contentsOfFile: path, encoding: .utf8),
           !instructions.isEmpty {
            content += instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n\n---\n\n"
            log("[lemon] loaded team instructions from \(path)")
        }

        // Issue details.
        content += "# Issue: \(issue.identifier) — \(issue.title)\n\n"
        if let desc = issue.description, !desc.isEmpty {
            content += desc.trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n\n"
        }

        // Available repos (multi-repo mode).
        if !repos.isEmpty {
            content += "### Available Repos\n"
            for repo in repos {
                content += "- `\(repo.name)/`\n"
            }
            content += "\n"
        }

        // Dev environment — only the project-agnostic bits. Anything stack-specific
        // (Next.js, databases, deploy targets) belongs in the team's LEMON.md.
        content += "### Session Environment\n"
        content += "- **Reserved dev-server port:** `\(devPort)` — use this if you launch a dev server so concurrent Lemon sessions don't collide.\n"
        content += "- **Worktree:** you're in a fresh git worktree on branch `lemon/\(issue.identifier)`. Don't switch branches.\n\n"

        // Completion checklist — universal across stacks.
        content += """
        ---
        ## Completion checklist

        When the PR is open and ready for review:
        1. Apply the Linear label **🍋 Complete** to issue \(issue.identifier) via `gh` or the Linear MCP.
        2. Write a brief summary of what you did to `.lemon-summary.md` in this worktree (referenced by the Lemon Report comment).
        3. Kill any dev servers, background tasks, or external resources you started.

        If you need human input at any point, apply the label **🍋 Waiting** and pause.
        If the issue's team LEMON.md above gave you extra steps, do those too.

        ---
        ## Use `/loop` for iterative work

        Lemon itself is a hand-coded `/loop` — Orchestrator polls, Gemma
        watches the pane, the session keeps going until 🍋 Complete fires.
        For your work inside this session, prefer `/loop` whenever the
        task benefits from iteration rather than one pass:

        - **Polish** a UI / a doc / a code path (try, look, refine)
        - **Reviews** of a diff, a PR, a module — one finding per tick
        - **Refactors** where you can't enumerate every site upfront
        - **Bug-hunting sweeps** — fix one, run tests, find the next
        - **Test backfill** — write one, watch it pass, find the next gap
        - **Exploration** where the next move depends on the last result

        Each tick: make one concrete change, validate it, commit if it
        landed, decide what's next, repeat. Stop when the completion
        checklist above is satisfied. The pattern works because each
        loop iteration is small, scoped, and verifiable — same reason
        Lemon's outer loop works.
        """
        try? content.write(toFile: "\(sessionPath)/LEMON_CONTEXT.md", atomically: true, encoding: .utf8)
    }

    // MARK: - Session naming helpers

    func tmuxSessionName(_ identifier: String) -> String {
        "lemon-\(identifier.lowercased())"
    }

    func logPath(_ identifier: String) -> String {
        "/tmp/lemon-log-\(identifier.lowercased()).txt"
    }

    // MARK: - MCP config preparation

    // Merges .mcp.json files from all worktree repos into a single config file.
    // Returns the path to the merged file, or nil if no MCP servers were found.
    // Passing this via --mcp-config bypasses Claude's interactive MCP discovery prompt.
    private func prepareMcpConfig(sessionPath: String, repos: [(name: String, repoPath: String)],
                                  isMultiRepo: Bool, identifier: String) -> String? {
        var mcpServers: [String: Any] = [:]
        var sourceOf: [String: String] = [:]   // server name → repo it came from (for conflict logging)
        let searchPaths: [(label: String, path: String)] = isMultiRepo
            ? repos.map { (label: $0.name, path: "\(sessionPath)/\($0.name)") }
            : [(label: "session", path: sessionPath)]
        for entry in searchPaths {
            let mcpPath = "\(entry.path)/.mcp.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: mcpPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (name, config) in servers {
                if let prior = sourceOf[name], prior != entry.label {
                    Logger.worktree.warning("MCP server '\(name)' defined in both '\(prior)' and '\(entry.label)' — using '\(entry.label)'. Rename one if both should be active.")
                }
                mcpServers[name] = config
                sourceOf[name] = entry.label
            }
        }
        guard !mcpServers.isEmpty else { return nil }
        let configPath = "/tmp/lemon-mcp-\(identifier.lowercased()).json"
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": mcpServers],
                                                     options: .prettyPrinted) else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return configPath
        } catch {
            Logger.worktree.error("MCP config write failed at \(configPath): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - tmux launch

    // Creates a named tmux session running Claude, pipes output to a log file,
    // and opens the session in iTerm2 (tmux -CC for native tabs) if available.
    // The launcher script writes sentinelPath when claude exits so pollUntilDone
    // can detect early exits without waiting for the 8h deadline.
    @discardableResult
    private func launchTmux(sessionPath: String, identifier: String,
                             sentinelPath: String, mcpConfigPath: String? = nil) -> Bool {
        // Verify tmux is installed.
        guard runSync("which tmux > /dev/null 2>&1") else {
            log("[lemon] tmux not found — install with: brew install tmux", level: .error)
            return false
        }

        let sessionName  = tmuxSessionName(identifier)
        let launcherPath = "/tmp/lemon-launch-\(identifier.lowercased()).sh"
        let mcpFlag      = mcpConfigPath.map { "--mcp-config '\($0)'" } ?? ""

        // Trailing positional kickoff prompt — `claude [options] [prompt]`.
        // Without this Claude opens an empty REPL and just sits there; the
        // user is supposed to be afk, so Gemma sees an idle pane forever and
        // (correctly) returns state=running/action=null on every classify.
        // Pointing Claude at LEMON_CONTEXT.md makes the session self-starting.
        // Single-quoted in bash, so no apostrophes in the prompt body.
        let kickoffPrompt = "Read LEMON_CONTEXT.md in this directory and complete the task described there. Follow the completion checklist. Use /loop for iterative work."

        // Source common shell profiles so PATH includes Homebrew, npm-global,
        // pyenv shims, etc. Same root cause as the runSync(zsh -l -c) fix:
        // `claude` is typically installed via brew or npm -g, which puts it
        // somewhere non-default-bash PATH won't find. Without this the launch
        // dies immediately with "claude: command not found" the moment tmux
        // boots the launcher.
        let launcher = """
        #!/bin/bash
        [ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
        [ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
        [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
        cd '\(sessionPath)' && claude \(mcpFlag) --enable-auto-mode --remote-control '\(kickoffPrompt)'
        echo $? > '\(sentinelPath)'
        """
        do {
            try launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
        } catch {
            Logger.worktree.error("Failed to write launcher: \(error)")
            return false
        }

        // Kill any leftover session from a prior run.
        runSync("tmux kill-session -t '\(sessionName)' 2>/dev/null || true")

        // Create detached tmux session.
        guard runSync("tmux new-session -d -s '\(sessionName)' -x 220 -y 50 '\(launcherPath)'") else {
            log("[lemon] Failed to create tmux session '\(sessionName)'", level: .error)
            return false
        }

        // Pipe all pane output to the log file for Gemma to read.
        runSync("tmux pipe-pane -t '\(sessionName)' -o 'cat >> \(logPath(identifier))'")

        // Open a visible terminal so the user can watch and join. Prefer iTerm2
        // (native tmux control mode via tmux -CC) and fall back to Terminal.app,
        // which is present on every macOS install. The tmux session is detached
        // either way — the visible window is for human eyes only.
        let hasITerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        if hasITerm {
            let ok = runSync("""
                osascript -e 'tell application "iTerm" to create window with default profile \
                command "tmux -CC attach -t \(sessionName)"' 2>/dev/null
                """)
            if !ok {
                Logger.worktree.warning("iTerm window open failed for \(sessionName); falling back to Terminal.app")
                openInTerminalApp(sessionName: sessionName)
            }
        } else {
            openInTerminalApp(sessionName: sessionName)
        }

        return true
    }

    // Auto-launch path: the user didn't ask for this window — Lemon decided to
    // open it. So we deliberately omit `activate` to avoid stealing focus from
    // whatever they were typing in. Terminal.app's window still appears in the
    // window list and Mission Control; the user can switch to it when ready.
    // The Join button (PopoverView) uses an activate-ing variant for the case
    // where the user explicitly clicked Join.
    private func openInTerminalApp(sessionName: String) {
        runSync("""
            osascript -e 'tell application "Terminal" to do script "tmux attach -t \(sessionName)"' 2>/dev/null || true
            """)
    }

    // MARK: - Gemma orchestration

    private func invokeGemma(issue: LinearIssue) async {
        guard LocalLLM.shared.isReady() else {
            Logger.worktree.info("[gemma] skipped — LocalLLM not ready for \(issue.identifier)")
            return
        }
        let lines = tailLog(issue.identifier, last: 100)
        Logger.worktree.info("[gemma] classifying \(issue.identifier) with \(lines.count) log lines")
        do {
            let response = try await LocalLLM.shared.classify(issue: issue, logLines: lines)
            Logger.worktree.info("[gemma] state=\(response.state) action=\(response.action?.type ?? "nil") summary=\(response.summary, privacy: .public)")

            onAiSummary?(response.summary)
            log("[gemma] \(response.summary)")

            guard let action = response.action else { return }
            switch action.type {
            case "send_keys":
                handleSendKeys(keys: action.keys ?? "", identifier: issue.identifier,
                               reason: response.summary)
            case "notify_user":
                // Route through the existing push-notification / 🍋 Waiting path via log line.
                // A future iteration can wire this to a native notification.
                log("[gemma] needs human: \(action.message ?? response.summary)", level: .error)
            default:
                Logger.worktree.error("[gemma] unknown action type=\(action.type)")
            }
        } catch {
            Logger.worktree.error("[gemma] classify failed for \(issue.identifier): \(error.localizedDescription)")
        }
    }

    // Shows a 5-second cancellable toast, then sends keys to the tmux pane.
    // Safety: only an allowlist of low-risk confirmations is permitted. Anything
    // outside the list is logged and dropped — we'd rather miss a prompt than
    // type arbitrary text into a running Claude session.
    private func handleSendKeys(keys: String, identifier: String, reason: String) {
        let trimmed = keys.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorktreeRunner.isSafeSendKeys(trimmed) else {
            Logger.worktree.error("[gemma] dropping unsafe send_keys=\(trimmed, privacy: .public) reason=\(reason, privacy: .public)")
            log("[gemma] dropped unsafe keystroke (\(trimmed)); needs human review", level: .error)
            onPendingAction?(nil)
            return
        }
        onPendingAction?("Gemma: \(reason)…")
        pendingActionTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // Special tmux key names (Enter, Escape, Space, etc.) must be passed
            // as separate UNQUOTED arguments — `tmux send-keys 'Enter'` types the
            // literal string "Enter" rather than pressing the Enter key.
            // Letter keys still get an auto-Enter suffix to confirm.
            let cmd: String
            if WorktreeRunner.specialKeys.contains(trimmed) {
                cmd = "tmux send-keys -t '\(tmuxSessionName(identifier))' \(trimmed)"
            } else {
                let escaped = trimmed.replacingOccurrences(of: "'", with: "'\\''")
                cmd = "tmux send-keys -t '\(tmuxSessionName(identifier))' '\(escaped)' Enter"
            }
            runSync(cmd)
            log("[gemma] resolved: \(reason) (sent: \(trimmed.isEmpty ? "Enter" : trimmed))")
            onPendingAction?(nil)
        }
    }

    // tmux special key names that don't need an Enter-suffix and must not be quoted.
    static let specialKeys: Set<String> = ["Enter", "Return", "Escape", "Space", "Tab", "BSpace", "Up", "Down", "Left", "Right"]

    // Safe confirmations: single keystrokes Claude/claude-code prompts accept,
    // numeric menu selections (1-9), yes/no, and the navigation/confirmation
    // special keys an MCP-picker style menu needs (Enter to confirm a
    // pre-checked list, Space to toggle, Escape to reject).
    static func isSafeSendKeys(_ keys: String) -> Bool {
        let allowed: Set<String> = [
            "", "y", "Y", "n", "N",
            "yes", "Yes", "YES", "no", "No", "NO",
            "1", "2", "3", "4", "5", "6", "7", "8", "9"
        ]
        return allowed.contains(keys) || specialKeys.contains(keys)
    }

    // MARK: - Log tail helper

    // Counts non-empty lines in the pane log. Used by the silence detector
    // instead of byte-count so ANSI cursor-redraw inflation doesn't reset the
    // activity timer.
    private func countLogLines(at path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func tailLog(_ identifier: String, last n: Int) -> [String] {
        guard let content = try? String(contentsOfFile: logPath(identifier), encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.count <= n ? lines : Array(lines[(lines.count - n)...])
    }

    // MARK: - Synchronous shell helper (used for setup/teardown, not in async hot paths)

    // Use a login shell (`zsh -l -c`) so Homebrew's PATH on Apple Silicon
    // (/opt/homebrew/bin) is sourced from .zprofile. Without -l, tools like
    // tmux installed via `brew install` are invisible at runtime even though
    // the onboarding step (which also uses -l) correctly detects them — that
    // mismatch caused "tmux not found" failures live, despite tmux being
    // installed and verified at setup.
    @discardableResult
    private func runSync(_ command: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Label polling

    private func pollUntilDone(
        issue: LinearIssue,
        sessionPath: String,
        repos: [(name: String, repoPath: String)],
        isMultiRepo: Bool,
        branch: String,
        labelIds: [String: String],
        retrigger: LemonMarker?,
        apiKey: String,
        workspacePath: String,
        sentinelPath: String
    ) async {
        let deadline = Date().addingTimeInterval(8 * 3600)  // 8h max; prevents forever-stuck icon
        var lastLineCount: Int = 0
        var lastActivityAt = Date()
        var lastGemmaAt: Date? = nil

        while !stopped && Date() < deadline {
            try? await Task.sleep(for: .seconds(10))
            guard !stopped else { break }

            // Poll PR URL from gh CLI (first match across all repos).
            if let prUrl = await detectPR(branch: branch, repos: repos) {
                onPRUrl?(prUrl)
            }

            // Check for 🍋 Complete label.
            let userId = KeychainStore.shared.linearUserId
            if let completes = try? await linear.fetchCompleteIssues(apiKey: apiKey, userId: userId),
               completes.first(where: { $0.id == issue.id }) != nil {
                await handleComplete(
                    issue: issue,
                    sessionPath: sessionPath,
                    repos: repos,
                    isMultiRepo: isMultiRepo,
                    branch: branch,
                    labelIds: labelIds,
                    retrigger: retrigger,
                    apiKey: apiKey,
                    workspacePath: workspacePath
                )
                return
            }

            // Two ways the session can have ended without 🍋 Complete:
            //   (a) the launcher's `echo $? > sentinelPath` ran after claude
            //       exited cleanly — happy "claude died but session was alive"
            //   (b) the tmux session itself is gone — user killed the Terminal
            //       window (SIGHUPing the bash before it could write the sentinel),
            //       or `tmux kill-session` happened, or something OOM'd it.
            //
            // The previous code only handled (a). Without (b) the orchestrator
            // would happily poll for hours after the user closed the window,
            // showing "Executing" forever.
            let sentinelExists = FileManager.default.fileExists(atPath: sentinelPath)
            let tmuxAlive = runSync("tmux has-session -t '\(tmuxSessionName(issue.identifier))' 2>/dev/null")
            if sentinelExists || !tmuxAlive {
                let exitCode: String
                let cause: String
                if sentinelExists {
                    exitCode = (try? String(contentsOfFile: sentinelPath, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                    cause = "claude exited (code \(exitCode))"
                } else {
                    exitCode = "no-tmux"
                    cause = "tmux session disappeared (window closed or killed)"
                }
                Logger.worktree.warning("\(cause) without setting 🍋 Complete on \(issue.identifier)")
                log("[lemon] session ended without completing — \(cause)", level: .error)
                _ = try? await linear.postComment(
                    issueId: issue.id,
                    body: "🍋 Session ended without completing — \(cause). Re-add the 🍋 label to retry.",
                    apiKey: apiKey
                )
                if let inProgressId = labelIds[LinearClient.labelInProgress] {
                    try? await linear.removeLabel(issueId: issue.id, labelId: inProgressId, apiKey: apiKey)
                }
                if let waitingId = labelIds[LinearClient.labelWaiting] {
                    try? await linear.removeLabel(issueId: issue.id, labelId: waitingId, apiKey: apiKey)
                }
                _ = exitCode
                onStatusChange?(.failed)
                return
            }

            // Infer waiting vs executing from the issue's current labels.
            // fetchLemonQueue filters by the 🍋 trigger label, which we removed
            // when the session started — so it won't see the issue mid-session.
            // fetchIssueLabels targets the single issue and works after handoff.
            if let labels = try? await linear.fetchIssueLabels(issueId: issue.id, apiKey: apiKey) {
                if labels.contains(LinearClient.labelWaiting) {
                    onStatusChange?(.waiting)
                } else if labels.contains(LinearClient.labelInProgress) {
                    onStatusChange?(.executing)
                }
            }

            // Silence detection: track LINE-count growth, not byte count.
            // tmux pipe-pane streams ANSI cursor-redraw sequences continuously
            // even when Claude is wedged on an interactive prompt — byte count
            // keeps inflating and the silence timer never trips. Line count
            // only grows when actual output arrives.
            let currentLines = countLogLines(at: logPath(issue.identifier))
            if currentLines > lastLineCount {
                lastLineCount = currentLines
                lastActivityAt = Date()
            }
            if WorktreeRunner.shouldInvokeGemma(lastActivityAt: lastActivityAt, lastGemmaAt: lastGemmaAt) {
                lastGemmaAt = Date()
                await invokeGemma(issue: issue)
            }
        }
        // Loop exited without completing — either stopped externally or timed out.
        if !stopped {
            Logger.worktree.warning("Session for \(issue.identifier) timed out after 8h")
            onStatusChange?(.failed)
        }
    }

    // MARK: - Completion handler

    private func handleComplete(
        issue: LinearIssue,
        sessionPath: String,
        repos: [(name: String, repoPath: String)],
        isMultiRepo: Bool,
        branch: String,
        labelIds: [String: String],
        retrigger: LemonMarker?,
        apiKey: String,
        workspacePath: String
    ) async {
        onStatusChange?(.reviewing)
        log("[lemon] 🍋 Complete detected for \(issue.identifier)")

        // Final Gemma summary before posting the Linear comment.
        await invokeGemma(issue: issue)

        let prUrl = await detectPR(branch: branch, repos: repos)
        let prNumber = prUrl.flatMap { URL(string: $0)?.lastPathComponent } ?? ""
        let summary = (try? String(contentsOfFile: "\(sessionPath)/.lemon-summary.md", encoding: .utf8)) ?? ""

        // The marker stores the workspace path so retrigger can rediscover repos.
        let markerPath = workspacePath

        let commentBody = buildLemonComment(
            issue: issue,
            prUrl: prUrl,
            prNumber: prNumber,
            branch: branch,
            summary: summary,
            repoPath: markerPath
        )

        if let existingCommentId = retrigger?.commentId {
            let replyBody = buildReplyComment(prUrl: prUrl, summary: summary)
            do {
                try await linear.postComment(issueId: issue.id, body: replyBody, apiKey: apiKey)
            } catch {
                Logger.worktree.error("Failed to post reply comment for \(issue.identifier): \(error)")
            }
            _ = existingCommentId
        } else {
            if let commentId = try? await linear.postComment(issueId: issue.id, body: commentBody, apiKey: apiKey) {
                log("[lemon] posted Lemon comment \(commentId)")
            }
        }

        await cleanupWorktrees(repos: repos, sessionPath: sessionPath, isMultiRepo: isMultiRepo,
                               identifier: issue.identifier)
        onStatusChange?(.done)
    }

    // MARK: - Comment builders

    private func buildLemonComment(
        issue: LinearIssue,
        prUrl: String?,
        prNumber: String,
        branch: String,
        summary: String,
        repoPath: String
    ) -> String {
        var md = "## 🍋 Lemon Report — \(issue.identifier)\n\n"
        if let url = prUrl {
            md += "**PR:** [#\(prNumber)](\(url))\n"
        }
        md += "**Branch:** `\(branch)`\n"
        if !summary.isEmpty {
            md += "\n### What was done\n\(summary)\n"
        }
        md += "\n---\n*Reply to this comment to ask Lemon to revise. Lemon will update the branch and PR.*\n\n"
        // No `comment:` field here on purpose. The Lemon Report comment is the
        // marker itself, so its ID is unknown until commentCreate returns.
        // LinearClient.parseLemonMarker falls back to the host comment's own ID
        // when the field is absent, which is exactly what we want for re-trigger.
        md += "<!-- lemon\nbranch: \(branch)\npr: \(prNumber)\nrepo: \(repoPath)\n-->"
        return md
    }

    private func buildReplyComment(prUrl: String?, summary: String) -> String {
        var md = "## 🍋 Lemon Update\n\n"
        if let url = prUrl { md += "**PR:** \(url)\n\n" }
        if !summary.isEmpty { md += summary }
        return md
    }

    // MARK: - PR detection

    private func detectPR(branch: String, repos: [(name: String, repoPath: String)]) async -> String? {
        for repo in repos {
            if let url = await detectPRInRepo(branch: branch, repoPath: repo.repoPath) {
                return url
            }
        }
        return nil
    }

    private func detectPRInRepo(branch: String, repoPath: String) async -> String? {
        guard let output = try? await shell(
            "cd \(q(repoPath)) && gh pr list --head \(branch) --json url --jq '.[0].url' 2>/dev/null"
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }

    // MARK: - Shell helper

    // Login shell for the same PATH reason as runSync above.
    @discardableResult
    private func shell(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: ShellError(command: command, output: output, code: proc.terminationStatus))
                }
            }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func log(_ line: String, level: OSLogType = .info) {
        Logger.worktree.log(level: level, "\(line)")
        onLogLine?(line)
    }

    private func q(_ s: String) -> String { "\"\(s)\"" }
}

struct ShellError: Error, LocalizedError {
    let command: String
    let output: String
    let code: Int32
    var errorDescription: String? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "exit \(code)" : "exit \(code): \(out)"
    }
}
