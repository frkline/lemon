import Foundation
import os

// Registers Lemon's MCP tool surface on LemonMCPServer.shared. Called once at
// app launch when MCP is enabled. Each tool handler captures `orchestrator`,
// hops to MainActor to read SessionStore / publish state changes, then
// JSON-encodes inside the closure so a Sendable String crosses back out
// (strict concurrency won't let [String: Any] dictionaries traverse actors).
//
// Tools are organized by capability:
//   read-only:  list_sessions, get_session, get_pane_log, get_opencode_session,
//               get_engine_config, get_swiftlm_log
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
            description: "List all Lemon sessions — active (currently running) plus the most recent completed/failed. Returns each session's UUID, issue identifier (Linear key or GitHub owner/repo#n), source, status, timing, and worktree path.",
            inputSchema: [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false,
            ],
            handler: { _ in
                await MainActor.run {
                    let payload: [String: Any] = [
                        "active": orchestrator.sessions.active.map(sessionSummary),
                        "recent": orchestrator.sessions.recent.map(sessionSummary),
                    ]
                    return LemonMCPServer.encode(payload)
                }
            },
        ))

        // ── get_session ────────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_session",
            description: "Get the detailed state of one Lemon session — issue, status, last AI summary + pending action, log tail, worktree path. Pass either the session UUID or the issue identifier (Linear key like 'HRP-37' or GitHub 'owner/repo#n').",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')",
                    ],
                    "log_lines": [
                        "type": "integer",
                        "description": "How many lines of pane log to return from the tail (default 60, max 500)",
                        "default": 60,
                    ],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            handler: { (args: [String: Any]) async throws -> String in
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
                    if let openCode = openCodeSessionMetadata(session) {
                        detail["opencode"] = openCode
                    }
                    if let summary = session.aiSummary { detail["last_ai_summary"] = summary }
                    if let pending = session.pendingAction { detail["pending_action"] = pending }
                    if let pr = session.prUrl { detail["pr_url"] = pr }
                    return LemonMCPServer.encode(detail)
                }
            },
        ))

        // ── get_pane_log ───────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_pane_log",
            description: "Read the tmux pane log of a Claude Code session. For OpenCode sessions, returns engine metadata and points callers to get_opencode_session instead of returning an empty tmux log.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                    "lines": ["type": "integer", "description": "Lines from the tail (default 100, max 2000)", "default": 100],
                ],
                "required": ["id"],
                "additionalProperties": false,
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
                    if engineKind(for: session) == .openCode {
                        var payload: [String: Any] = [
                            "identifier": session.issue.identifier,
                            "engine": AgentEngineKind.openCode.rawValue,
                            "message": "OpenCode sessions are daemon/API-backed and do not have a tmux pane log. Use get_opencode_session.",
                        ]
                        if let metadata = openCodeSessionMetadata(session) {
                            payload["opencode"] = metadata
                        }
                        return LemonMCPServer.encode(payload)
                    }
                    let payload: [String: Any] = [
                        "identifier": session.issue.identifier,
                        "log_path": "/tmp/lemon-log-\(session.issue.pathSlug).txt",
                        "tail": readPaneLogTail(slug: session.issue.pathSlug, lines: lines),
                    ]
                    return LemonMCPServer.encode(payload)
                }
            },
        ))

        // ── get_opencode_session ───────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_opencode_session",
            description: "Read OpenCode daemon metadata and recent message parts for an OpenCode-backed Lemon session. Pass the Lemon issue/session id; returns the OpenCode session id, URL, model, cost/tokens, and compact recent messages.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                    "messages": ["type": "integer", "description": "Recent OpenCode messages to return (default 8, max 30)", "default": 8],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let messageLimit = min(max((args["messages"] as? Int) ?? 8, 1), 30)
                let resolved = try await MainActor.run { () throws -> (String, OpenCodeWorkspaceConfig, String) in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg) else {
                        throw MCPError(code: -32004, message: "no session matching '\(idArg)'")
                    }
                    guard engineKind(for: session) == .openCode else {
                        throw MCPError(code: -32006, message: "session '\(idArg)' is not an OpenCode session")
                    }
                    guard let config = openCodeConfig(for: session),
                          let sessionID = openCodeSessionID(for: session)
                    else {
                        throw MCPError(code: -32007, message: "OpenCode session metadata missing for '\(idArg)'")
                    }
                    return (session.issue.identifier, config, sessionID)
                }

                let (identifier, config, sessionID) = resolved
                let base = "http://\(config.daemon.host):\(config.daemon.port)"
                let infoURL = URL(string: "\(base)/session/\(sessionID)")!
                let messagesURL = URL(string: "\(base)/api/session/\(sessionID)/message?limit=\(messageLimit)&order=desc")!
                let info = await (try? fetchJSON(url: infoURL))
                let messages = await (try? fetchJSON(url: messagesURL))
                let payload: [String: Any] = [
                    "identifier": identifier,
                    "engine": AgentEngineKind.openCode.rawValue,
                    "session_id": sessionID,
                    "url": "\(base)/sessions/\(sessionID)",
                    "daemon": ["host": config.daemon.host, "port": config.daemon.port],
                    "session": compactOpenCodeSessionInfo(info),
                    "messages": compactOpenCodeMessages(messages),
                ]
                return LemonMCPServer.encode(payload)
            },
        ))

        // ── get_engine_config ──────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "get_engine_config",
            description: "Read Lemon engine configuration: global OpenCode defaults and, optionally, the resolved engine config for one Lemon session/workspace. Secrets are never returned.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Optional session UUID or issue identifier to include resolved workspace engine config"],
                ],
                "additionalProperties": false,
            ],
            handler: { args in
                let requestedID = args["id"] as? String
                return await MainActor.run {
                    var payload: [String: Any] = [
                        "global_opencode_defaults": openCodeConfigPayload(KeychainStore.shared.openCodeDefaults),
                    ]
                    if let idArg = requestedID, !idArg.isEmpty,
                       let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg)
                    {
                        var sessionPayload = sessionSummary(session)
                        sessionPayload["engine"] = engineKind(for: session).rawValue
                        if let config = openCodeConfig(for: session) {
                            sessionPayload["opencode_config"] = openCodeConfigPayload(config)
                            sessionPayload["uses_global_opencode_defaults"] = workspaceOpenCodeOverride(for: session) == nil
                        }
                        payload["session"] = sessionPayload
                    }
                    return LemonMCPServer.encode(payload)
                }
            },
        ))

        // ── get_swiftlm_log ────────────────────────────────────────────────
        // Reads a static file path — no actor state needed, no hop required.
        server.register(LemonMCPServer.Tool(
            name: "get_swiftlm_log",
            description: "Read the tail of the SwiftLM (local AI inference server) log at /tmp/lemon-swiftlm.log. Useful for diagnosing classifier failures, model load errors, or token-rate observations.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "lines": ["type": "integer", "description": "Lines from the tail (default 80, max 1000)", "default": 80],
                ],
                "additionalProperties": false,
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
                    "ai_state": aiStateText,
                ]
                return LemonMCPServer.encode(payload)
            },
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
            description: "Run the Gemma classifier on a session's current pane log immediately, bypassing the silence-detector wait. Returns the GemmaResponse {state, summary, action} plus the input log lines. With act=true, ALSO executes a send_keys verdict (sends the keys to the pane) — the on-demand 'analyze + act now' trigger, e.g. to clear a launch-time prompt without waiting for the silence timer.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                    "log_lines": [
                        "type": "integer",
                        "description": "How many tail lines to feed Gemma (default 80, max 400). Mirrors what the silence detector normally sends.",
                        "default": 80,
                    ],
                    "act": [
                        "type": "boolean",
                        "description": "If true and Gemma returns a send_keys action, send those keys to the pane immediately (default false = observe only).",
                        "default": false,
                    ],
                ],
                "required": ["id"],
                "additionalProperties": false,
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
                guard await LocalLLM.shared.ensureReady() else {
                    throw MCPError(code: -32001, message: "LocalLLM not ready — reloading model, retry shortly")
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

                // act=true: execute a send_keys verdict immediately (the on-demand
                // "analyze + act" trigger — bypasses the silence timer to clear a
                // launch-time prompt like folder-trust without waiting).
                var acted = false
                let shouldAct = (args["act"] as? Bool) ?? false
                if shouldAct, verdict.action?.type == "send_keys",
                   let keys = verdict.action?.keys, !keys.isEmpty
                {
                    let sessionName = "lemon-\(issue.pathSlug)"
                    let specialKeys: Set = ["Enter", "Return", "Escape", "Space", "Tab", "BSpace", "Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End"]
                    let cmd = if specialKeys.contains(keys) {
                        "\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' \(keys)"
                    } else {
                        "\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' '\(keys.replacingOccurrences(of: "'", with: "'\\''"))' Enter"
                    }
                    acted = runShell(cmd) == 0
                }

                let payload: [String: Any] = [
                    "identifier": issue.identifier,
                    "state": verdict.state,
                    "summary": verdict.summary,
                    "action": actionDict.isEmpty ? NSNull() : actionDict,
                    "acted": acted,
                    "input_log_lines": tail,
                    "elapsed_ms": elapsedMs,
                ]
                return LemonMCPServer.encode(payload)
            },
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
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                    "keys": ["type": "string", "description": "Key sequence or tmux special-key name (e.g. 'Enter', 'y', '/clear')"],
                    "append_enter": [
                        "type": "boolean",
                        "description": "Append Enter after the keys (default true; ignored for tmux special-key names)",
                        "default": true,
                    ],
                ],
                "required": ["id", "keys"],
                "additionalProperties": false,
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
                guard runShell("\(WorktreeRunner.tmuxBase) has-session -t '\(sessionName)' 2>/dev/null") == 0 else {
                    throw MCPError(code: -32005, message: "tmux session '\(sessionName)' not alive")
                }
                let specialKeys: Set = ["Enter", "Return", "Escape", "Space", "Tab", "BSpace", "Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End"]
                let cmd: String
                if specialKeys.contains(keys) {
                    cmd = "\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' \(keys)"
                } else {
                    let escaped = keys.replacingOccurrences(of: "'", with: "'\\''")
                    cmd = appendEnter
                        ? "\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' '\(escaped)' Enter"
                        : "\(WorktreeRunner.tmuxBase) send-keys -t '\(sessionName)' '\(escaped)'"
                }
                let rc = runShell(cmd)
                let payload: [String: Any] = [
                    "identifier": identifier,
                    "session_name": sessionName,
                    "keys": keys,
                    "appended_enter": !specialKeys.contains(keys) && appendEnter,
                    "exit_code": rc,
                    "ok": rc == 0,
                ]
                return LemonMCPServer.encode(payload)
            },
        ))

        // ── stop_session ───────────────────────────────────────────────────
        server.register(LemonMCPServer.Tool(
            name: "stop_session",
            description: "Cancel an active Lemon session — terminates the WorktreeRunner, kills the tmux session, marks the session as failed, and moves it into recent. Does NOT clean up the worktree directory or revert source labels.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let json: String? = await MainActor.run { () -> String? in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg),
                          orchestrator.sessions.active.contains(where: { $0.id == session.id })
                    else {
                        return nil
                    }
                    let payload: [String: Any] = [
                        "identifier": session.issue.identifier,
                        "uuid": session.id.uuidString,
                        "stopped": true,
                    ]
                    orchestrator.stopSession(session)
                    return LemonMCPServer.encode(payload)
                }
                guard let json else {
                    throw MCPError(code: -32004, message: "no active session matching '\(idArg)'")
                }
                return json
            },
        ))

        // ── approve_gate ───────────────────────────────────────────────────
        // Resolve a human gate (plan review / result review) remotely — the
        // same action the popover's Approve button takes. Lets the scenario
        // runner (and a remote operator) drive the plan/result gates.
        server.register(LemonMCPServer.Tool(
            name: "approve_gate",
            description: "Resolve a session parked at a human gate (Plan Review or Result Review). decision='approve' sends the live claude approval (plan→auto, or open-PR); decision='request_changes' sends it back for revision. No-ops if the session isn't at a gate.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session UUID or issue identifier (Linear 'HRP-37' or GitHub 'owner/repo#7')"],
                    "decision": ["type": "string", "enum": ["approve", "request_changes"], "default": "approve", "description": "approve = let it proceed; request_changes = send back for revision"],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            handler: { args in
                guard let idArg = args["id"] as? String, !idArg.isEmpty else {
                    throw MCPError(code: -32602, message: "missing 'id' argument")
                }
                let decision: Orchestrator.GateDecision =
                    (args["decision"] as? String) == "request_changes" ? .requestChanges : .approve
                let json: String? = await MainActor.run { () -> String? in
                    guard let session = findSession(orchestrator: orchestrator, idOrIdentifier: idArg),
                          session.status.isGate
                    else { return nil }
                    let gate = session.status.displayLabel
                    orchestrator.resolveGate(session: session, decision: decision)
                    return LemonMCPServer.encode([
                        "identifier": session.issue.identifier,
                        "uuid": session.id.uuidString,
                        "gate": gate,
                        "decision": decision.rawValue,
                        "new_status": session.status.displayLabel,
                        "resolved": true,
                    ])
                }
                guard let json else {
                    throw MCPError(code: -32004, message: "no session at a gate matching '\(idArg)'")
                }
                return json
            },
        ))
    }

    // MARK: - Helpers

    @MainActor
    private static func sessionSummary(_ s: Session) -> [String: Any] {
        var d: [String: Any] = [
            "uuid": s.id.uuidString,
            "issue_id": s.issue.id,
            "identifier": s.issue.identifier,
            "source": s.issue.source.rawValue,
            "title": s.issue.title,
            "status": s.status.displayLabel,
            "labels": s.issue.labelNames,
            "started_at": ISO8601DateFormatter().string(from: s.startedAt),
            "log_line_count": s.logLines.count,
            "engine": engineKind(for: s).rawValue,
        ]
        if let end = s.endedAt { d["ended_at"] = ISO8601DateFormatter().string(from: end) }
        if let wt = s.worktreePath { d["worktree_path"] = wt }
        if let openCode = openCodeSessionMetadata(s) {
            d["opencode"] = openCode
        }
        return d
    }

    @MainActor
    private static func engineKind(for session: Session) -> AgentEngineKind {
        guard let workspaceId = session.workspaceId,
              let workspace = KeychainStore.shared.workspaces.first(where: { $0.id == workspaceId })
        else { return .claudeCode }
        return workspace.engine.kind
    }

    @MainActor
    private static func workspaceOpenCodeOverride(for session: Session) -> OpenCodeWorkspaceConfig? {
        guard let workspaceId = session.workspaceId,
              let workspace = KeychainStore.shared.workspaces.first(where: { $0.id == workspaceId })
        else { return nil }
        return workspace.engine.openCode
    }

    @MainActor
    private static func openCodeConfig(for session: Session) -> OpenCodeWorkspaceConfig? {
        guard engineKind(for: session) == .openCode else { return nil }
        return workspaceOpenCodeOverride(for: session) ?? KeychainStore.shared.openCodeDefaults
    }

    private static func openCodeSessionID(for session: Session) -> String? {
        let path = WorktreeRunner.openCodeSessionPath(slug: session.issue.pathSlug)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private static func openCodeSessionMetadata(_ session: Session) -> [String: Any]? {
        guard let config = openCodeConfig(for: session),
              let sessionID = openCodeSessionID(for: session)
        else { return nil }
        return [
            "session_id": sessionID,
            "url": "http://\(config.daemon.host):\(config.daemon.port)/sessions/\(sessionID)",
            "daemon": ["host": config.daemon.host, "port": config.daemon.port],
            "models": [
                "plan": config.models.plan,
                "code": config.models.code,
                "review": config.models.review,
            ],
        ]
    }

    private static func openCodeConfigPayload(_ config: OpenCodeWorkspaceConfig) -> [String: Any] {
        [
            "models": [
                "plan": config.models.plan,
                "code": config.models.code,
                "review": config.models.review,
            ],
            "auto_open_threshold": config.autoOpenThreshold.rawValue,
            "daemon": ["host": config.daemon.host, "port": config.daemon.port],
        ]
    }

    @MainActor
    private static func findSession(orchestrator: Orchestrator, idOrIdentifier: String) -> Session? {
        let all = orchestrator.sessions.active + orchestrator.sessions.recent
        if let uuid = UUID(uuidString: idOrIdentifier),
           let s = all.first(where: { $0.id == uuid })
        {
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
        case .notConfigured: "not_configured"
        case .starting: "starting"
        case .ready: "ready"
        case let .failed(m): "failed: \(m)"
        case .idle: "idle"
        }
    }

    private nonisolated static func fetchJSON(url: URL) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw MCPError(code: -32008, message: "HTTP request failed for \(url.absoluteString)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func compactOpenCodeSessionInfo(_ object: Any?) -> [String: Any] {
        guard let dict = object as? [String: Any] else { return [:] }
        var output: [String: Any] = [:]
        for key in ["id", "slug", "title", "agent", "version", "cost", "tokens", "summary", "time"] {
            if let value = dict[key] { output[key] = value }
        }
        if let model = dict["model"] { output["model"] = model }
        return output
    }

    private nonisolated static func compactOpenCodeMessages(_ object: Any?) -> [[String: Any]] {
        let items: [[String: Any]]
        if let dict = object as? [String: Any], let data = dict["data"] as? [[String: Any]] {
            items = data
        } else if let array = object as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        return items.map { item in
            let info = (item["info"] as? [String: Any]) ?? item
            let parts = (item["parts"] as? [[String: Any]]) ?? []
            let textParts = parts.compactMap { part -> [String: Any]? in
                let type = part["type"] as? String ?? "unknown"
                if let text = part["text"] as? String, ["text", "reasoning"].contains(type) {
                    return ["type": type, "text": String(text.prefix(1000))]
                }
                if type == "tool" {
                    return [
                        "type": "tool",
                        "tool": part["tool"] as? String ?? "unknown",
                        "status": (part["state"] as? [String: Any])?["status"] as? String ?? "unknown",
                    ]
                }
                return nil
            }
            return [
                "id": info["id"] as? String ?? "",
                "role": info["role"] as? String ?? info["type"] as? String ?? "unknown",
                "finish": info["finish"] as? String ?? NSNull(),
                "model": info["modelID"] as? String ?? NSNull(),
                "provider": info["providerID"] as? String ?? NSNull(),
                "time": info["time"] as? [String: Any] ?? [:],
                "parts": textParts,
            ]
        }
    }

    /// Synchronous shell helper for tmux send-keys / tmux has-session. Same
    /// login-shell pattern WorktreeRunner uses so Homebrew tmux is on PATH.
    /// nonisolated so handlers can call it without an actor hop — Process is
    /// thread-safe and doesn't touch any MainActor state.
    private nonisolated static func runShell(_ command: String) -> Int32 {
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
