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
                    detail["log_tail"] = readPaneLogTail(identifier: session.issue.identifier, lines: lines)
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
                        "tail": readPaneLogTail(identifier: session.issue.identifier, lines: lines)
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

    private static func readPaneLogTail(identifier: String, lines: Int) -> [String] {
        let path = "/tmp/lemon-log-\(identifier.lowercased()).txt"
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
}
