import Foundation
import os

// Registers Lemon's MCP tool surface on LemonMCPServer.shared. Called once at
// app launch when MCP is enabled. Each tool handler captures `orchestrator`,
// hops to MainActor to read SessionStore / publish state changes, then
// JSON-encodes inside the closure so a Sendable String crosses back out
// (strict concurrency won't let [String: Any] dictionaries traverse actors).
//
// Tools are organized by capability:
//   read-only:  list_sessions, get_session, get_pane_log, get_swiftlm_log
//   control:    force_classify, send_keys, set_label, stop_session
//   dev-only:   seed_test_session (gated behind LEMON_DEV_MODE)
@MainActor
enum LemonMCPTools {
    static func registerAll(server: LemonMCPServer, orchestrator: Orchestrator) {
        registerReadOnly(server: server, orchestrator: orchestrator)
        registerControl(server: server, orchestrator: orchestrator)
    }

    // MARK: - Read-only tools

    private static func registerReadOnly(server: LemonMCPServer, orchestrator: Orchestrator) {
        // ── list_sessions ──────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "list_sessions",
            description: "List all Lemon sessions — active (currently running) plus the most recent completed/failed. Returns each session's UUID, Linear issue identifier, status, timing, and worktree path.",
            inputSchema: [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false
            ],
            handler: { _ in
                await MainActor.run {
                    let payload: [String: Any] = [
                        "active": orchestrator.sessions.active.map(sessionSummary),
                        "recent": orchestrator.sessions.recent.map(sessionSummary)
                    ]
                    return LemonMCPServer.encode(payload)
                }
            }
        ))

        // ── get_session ────────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_session",
            description: "Get the detailed state of one Lemon session — Linear issue, status, last AI summary + pending action, log tail, worktree path. Pass either the session UUID or the Linear issue identifier (e.g. 'HRP-37').",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Session UUID or Linear issue identifier (e.g. HRP-37)"
                    ],
                    "log_lines": [
                        "type": "integer",
                        "description": "How many lines of pane log to return from the tail (default 60, max 500)",
                        "default": 60
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let lines = min(max((args["log_lines"] as? Int) ?? 60, 1), 500)
                return try await MainActor.run { () throws -> String in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg) else {
                        throw MCPError(code: -32004, message: "no session matching '\(idArg)'")
                    }
                    var detail = sessionSummary(session)
                    detail["log_tail"] = readPaneLogTail(slug: session.issue.pathSlug, lines: lines)
                    if let summary = session.aiSummary { detail["last_ai_summary"] = summary }
                    if let pending = session.pendingAction { detail["pending_action"] = pending }
                    if let pr = session.prUrl { detail["pr_url"] = pr }
                    return LemonMCPServer.encode(detail)
                }
            }
        ))

        // ── get_pane_log ───────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_pane_log",
            description: "Read the tmux pane log of a session — the raw terminal output Claude has produced. ANSI escape codes are preserved. Pass the Linear issue identifier (e.g. 'HRP-37') or session UUID.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or Linear identifier"],
                    "lines": ["type": "integer", "description": "Lines from the tail (default 100, max 2000)", "default": 100]
                ],
                "required": ["id"],
                "additionalProperties": false
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let lines = min(max((args["lines"] as? Int) ?? 100, 1), 2000)
                return try await MainActor.run { () throws -> String in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg) else {
                        throw MCPError(code: -32004, message: "no session matching '\(idArg)'")
                    }
                    let payload: [String: Any] = [
                        "identifier": session.issue.identifier,
                        "log_path": "/tmp/lemon-log-\(session.issue.identifier.lowercased()).txt",
                        "tail": readPaneLogTail(slug: session.issue.pathSlug, lines: lines)
                    ]
                    return LemonMCPServer.encode(payload)
                }
            }
        ))

        // ── get_swiftlm_log ────────────────────────────────────────────────
        // Reads a static file path — no actor state needed, no hop required.
        server.register(LemonMCPServer.Tool(
            name: "get_swiftlm_log",
            description: "Read the tail of the SwiftLM (local AI inference server) log at /tmp/lemon-swiftlm.log. Useful for diagnosing classifier failures, model load errors, or token-rate observations.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "lines": ["type": "integer", "description": "Lines from the tail (default 80, max 1000)", "default": 80]
                ],
                "additionalProperties": false
            ],
            handler: { args in
                let lines = min(max((args["lines"] as? Int) ?? 80, 1), 1000)
                let content = (try? String(contentsOfFile: "/tmp/lemon-swiftlm.log", encoding: .utf8)) ?? ""
                let split = content.split(separator: "\n", omittingEmptySubsequences: false)
                let tailLines = split.suffix(lines).map(String.init)
                let aiStateText = await MainActor.run { stringify(aiState: orchestrator.aiState) }
                let payload: [String: Any] = [
                    "path": "/tmp/lemon-swiftlm.log",
                    "lines": tailLines,
                    "lines_returned": tailLines.count,
                    "ai_state": aiStateText
                ]
                return LemonMCPServer.encode(payload)
            }
        ))
    }

    // MARK: - Control tools

    private static func registerControl(server: LemonMCPServer, orchestrator: Orchestrator) {
        // ── force_classify ─────────────────────────────────────────────────
        // Sidestep the 2-minute silence detector — pull the pane log right
        // now, run Gemma on it, return the raw verdict. Lets a recursive
        // Claude probe what Gemma thinks of the current state on demand.
        server.register(LemonMCPServer.Tool(
            name: "force_classify",
            description: "Run the Gemma classifier on a session's current pane log immediately, bypassing the silence-detector wait. Returns the GemmaResponse {state, summary, action} plus the input log lines that were sent for the classification.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or Linear identifier"],
                    "log_lines": [
                        "type": "integer",
                        "description": "How many tail lines to feed Gemma (default 80, max 400). Mirrors what the silence detector normally sends.",
                        "default": 80
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let lines = min(max((args["log_lines"] as? Int) ?? 80, 1), 400)
                // Resolve the session and snapshot the issue + log lines on
                // MainActor so we can leave the actor before the (potentially
                // slow) network round-trip to SwiftLM.
                let snapshot = await MainActor.run { () -> (IssueRef, [String])? in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg) else { return nil }
                    let tail = readPaneLogTail(slug: session.issue.pathSlug, lines: lines)
                    return (session.issue, tail)
                }
                guard let (issue, tail) = snapshot else {
                    throw MCPError(code: -32004, message: "no session matching '\(idArg)'")
                }
                guard LocalLLM.shared.isReady() else {
                    throw MCPError(code: -32001, message: "LocalLLM not ready — check Self-test in Settings")
                }
                let started = Date()
                let verdict: GemmaResponse
                do {
                    verdict = try await LocalLLM.shared.classify(issue: issue, logLines: tail)
                } catch {
                    throw MCPError(code: -32002, message: "classify failed: \(error.localizedDescription)")
                }
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                var actionDict: [String: Any] = [:]
                if let a = verdict.action {
                    actionDict["type"] = a.type
                    if let k = a.keys { actionDict["keys"] = k }
                    if let m = a.message { actionDict["message"] = m }
                }
                let payload: [String: Any] = [
                    "identifier": issue.identifier,
                    "state": verdict.state,
                    "summary": verdict.summary,
                    "action": actionDict.isEmpty ? NSNull() : actionDict,
                    "input_log_lines": tail,
                    "elapsed_ms": elapsedMs
                ]
                return LemonMCPServer.encode(payload)
            }
        ))

        // ── send_keys ──────────────────────────────────────────────────────
        // Bypasses WorktreeRunner's isSafeSendKeys allowlist — anything the
        // caller passes goes straight to tmux. That's the point: this is for
        // unsticking sessions the silence detector or Gemma can't handle.
        // Loopback bind + no auth is the threat model.
        server.register(LemonMCPServer.Tool(
            name: "send_keys",
            description: "Send raw keystrokes to a session's tmux pane. BYPASSES the safety allowlist — the caller is fully trusted (localhost-only bind). For special keys, pass tmux's literal names (Enter, Escape, Space, Up, Down, Left, Right, BSpace, Tab). Regular text keys auto-append Enter unless 'append_enter' is false.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or Linear identifier"],
                    "keys": ["type": "string", "description": "Key sequence or tmux special-key name (e.g. 'Enter', 'y', '/clear')"],
                    "append_enter": [
                        "type": "boolean",
                        "description": "Append Enter after the keys (default true; ignored for tmux special-key names)",
                        "default": true
                    ]
                ],
                "required": ["id", "keys"],
                "additionalProperties": false
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                guard let keys = args["keys"] as? String, !keys.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'keys' argument")
                }
                let appendEnter = (args["append_enter"] as? Bool) ?? true
                let resolved = await MainActor.run { () -> (identifier: String, slug: String)? in
                    guard let s = findSession(orchestrator: orchestrator, idOrIdentifier: idArg) else { return nil }
                    return (s.issue.identifier, s.issue.pathSlug)
                }
                guard let resolved else {
                    throw MCPError(code: -32004, message: "no session matching '\(idArg)'")
                }
                let identifier = resolved.identifier
                let sessionName = "lemon-\(resolved.slug)"
                // Verify the tmux session is actually alive — silent failure
                // here would just look like "I sent keys but nothing happened"
                // and waste the caller's debugging time.
                guard runShell("tmux has-session -t '\(sessionName)' 2>/dev/null") == 0 else {
                    throw MCPError(code: -32005, message: "tmux session '\(sessionName)' not alive")
                }
                let specialKeys: Set<String> = ["Enter", "Return", "Escape", "Space", "Tab", "BSpace", "Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End"]
                let cmd: String
                if specialKeys.contains(keys) {
                    cmd = "tmux send-keys -t '\(sessionName)' \(keys)"
                } else {
                    let escaped = keys.replacingOccurrences(of: "'", with: "'\\''")
                    cmd = appendEnter
                        ? "tmux send-keys -t '\(sessionName)' '\(escaped)' Enter"
                        : "tmux send-keys -t '\(sessionName)' '\(escaped)'"
                }
                let rc = runShell(cmd)
                let payload: [String: Any] = [
                    "identifier": identifier,
                    "session_name": sessionName,
                    "keys": keys,
                    "appended_enter": !specialKeys.contains(keys) && appendEnter,
                    "exit_code": rc,
                    "ok": rc == 0
                ]
                return LemonMCPServer.encode(payload)
            }
        ))

        // ── stop_session ───────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "stop_session",
            description: "Cancel an active Lemon session — terminates the WorktreeRunner, kills the tmux session, marks the session as failed, and moves it into recent. Does NOT clean up the worktree directory or revert Linear labels.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or Linear identifier"]
                ],
                "required": ["id"],
                "additionalProperties": false
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let json: String? = await MainActor.run { () -> String? in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg),
                          orchestrator.sessions.active.contains(where: { $0.id == session.id }) else {
                        return nil
                    }
                    let payload: [String: Any] = [
                        "identifier": session.issue.identifier,
                        "uuid": session.id.uuidString,
                        "stopped": true
                    ]
                    orchestrator.stopSession(session)
                    return LemonMCPServer.encode(payload)
                }
                guard let json else {
                    throw MCPError(code: -32004, message: "no active session matching '\(idArg)'")
                }
                return json
            }
        ))
    }

    // MARK: - Helpers

    @MainActor
    private static func sessionSummary(_ s: Session) -> [String: Any] {
        var d: [String: Any] = [
            "uuid": s.id.uuidString,
            "issue_id": s.issue.id,
            "identifier": s.issue.identifier,
            "title": s.issue.title,
            "status": s.status.displayLabel,
            "labels": s.issue.labelNames,
            "started_at": ISO8601DateFormatter().string(from: s.startedAt),
            "log_line_count": s.logLines.count
        ]
        if let end = s.endedAt { d["ended_at"] = ISO8601DateFormatter().string(from: end) }
        if let wt = s.worktreePath { d["worktree_path"] = wt }
        return d
    }

    @MainActor
    private static func findSession(orchestrator: Orchestrator, idOrIdentifier: String) -> Session? {
        let all = orchestrator.sessions.active + orchestrator.sessions.recent
        if let uuid = UUID(uuidString: idOrIdentifier),
           let s = all.first(where: { $0.id == uuid }) {
            return s
        }
        let needle = idOrIdentifier.lowercased()
        return all.first { $0.issue.identifier.lowercased() == needle }
    }

    private static func readPaneLogTail(slug: String, lines: Int) -> [String] {
        let path = "/tmp/lemon-log-\(slug).txt"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let split = content.split(separator: "\n", omittingEmptySubsequences: false)
        return split.suffix(lines).map(String.init)
    }

    private static func stringify(aiState: LocalLLM.AIState) -> String {
        switch aiState {
        case .notConfigured: return "not_configured"
        case .starting:      return "starting"
        case .ready:         return "ready"
        case .failed(let m): return "failed: \(m)"
        }
    }

    // Synchronous shell helper for tmux send-keys / tmux has-session. Same
    // login-shell pattern WorktreeRunner uses so Homebrew tmux is on PATH.
    // nonisolated so handlers can call it without an actor hop — Process is
    // thread-safe and doesn't touch any MainActor state.
    nonisolated private static func runShell(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
