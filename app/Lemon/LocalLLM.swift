import Foundation
import os

// Manages a SwiftLM subprocess and exposes a single classify() call.
// SwiftLM serves an OpenAI-compatible HTTP API on localhost.
// Invoked only on trigger (silence / completion) to minimise thermal impact.
final class LocalLLM: @unchecked Sendable {
    static let shared = LocalLLM(port: 8488, session: .shared)
    private var process: Process?
    private let port: Int
    private let session: URLSession
    private var _ready = false
    private var _state: AIState = .notConfigured

    // Coarse-grained AI status surfaced to the UI. Snapshot at any time via state().
    enum AIState: Equatable {
        case notConfigured                   // aiEnabled=false or paths missing
        case starting                        // SwiftLM subprocess launched, waiting for /health
        case ready                           // /health 200, classify() should succeed
        case failed(String)                  // exited / didn't respond / health-poll timeout

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    func state() -> AIState { _state }

    private init(port: Int, session: URLSession) {
        self.port = port
        self.session = session
    }

    #if DEBUG
    static func makeForTesting(port: Int, session: URLSession) -> LocalLLM {
        let llm = LocalLLM(port: port, session: session)
        llm._ready = true
        llm._state = .ready
        return llm
    }
    #endif

    // MARK: - Lifecycle

    func start() async {
        let store = KeychainStore.shared
        guard store.aiEnabled, !store.swiftLMPath.isEmpty, !store.modelPath.isEmpty else {
            _state = .notConfigured
            return
        }
        guard process == nil else { return }

        // Kill any zombie SwiftLM holding port \(port) from a previous launch.
        // Otherwise the new SwiftLM binds(), gets EADDRINUSE, dies — while our
        // /health probe is satisfied by the OLD instance and we briefly report
        // ready before the new pid disappears. Saw this exact pattern in logs.
        Self.killProcessHoldingPort(port)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: store.swiftLMPath)
        // SwiftLM b648 CLI: --model <hf-id-or-local-path> --port <n>
        // Verified against `SwiftLM --help`; do not use --model-path.
        p.arguments = ["--model", store.modelPath, "--port", "\(port)"]
        Logger.orchestrator.info("SwiftLM launching: \(store.swiftLMPath) --model \(store.modelPath) --port \(self.port)")
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        // Capture stdout/stderr to a log file AND drain them continuously.
        // Two reasons both matter:
        //   (a) without draining, the pipe buffer fills (~16-64 KB) and
        //       SwiftLM blocks/dies on its next write — a likely cause of
        //       the post-ready exit we keep seeing.
        //   (b) without capturing the stream to disk, we have no way to
        //       diagnose *why* SwiftLM crashed. The Self-test message ends
        //       up generic when the underlying SwiftLM stderr would have
        //       said something useful ("k_norm.weight not found",
        //       "Metal: out of memory", etc.).
        let logPath = "/tmp/lemon-swiftlm.log"
        try? FileManager.default.removeItem(atPath: logPath)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        // Append-on-demand drain. Opens/closes FileHandle per chunk to keep
        // the @Sendable closure free of non-Sendable captures (FileHandle
        // isn't Sendable). The overhead is fine — chunks are coalesced by
        // the kernel's pipe buffer, so we're not doing it per byte.
        let drain: @Sendable (FileHandle) -> Void = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if let fh = FileHandle(forWritingAtPath: logPath) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: chunk)
                try? fh.close()
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = drain
        errPipe.fileHandleForReading.readabilityHandler = drain

        do {
            try p.run()
            process = p
            _state = .starting
            Logger.orchestrator.info("SwiftLM launched (pid \(p.processIdentifier)) — stream → /tmp/lemon-swiftlm.log")
        } catch {
            let msg = "SwiftLM launch failed: \(error.localizedDescription)"
            Logger.orchestrator.error("\(msg)")
            _state = .failed(msg)
            return
        }

        // Poll /health up to 180 s for the server to become ready. A 4-bit Gemma 4 E4B
        // (5 GB) takes ~60-90 s to load on M-series Macs; a 2 GB Qwen 0.5B was ~6 s in
        // standalone testing. The earlier 30 s cap timed out before real models loaded.
        let startedAt = Date()
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            guard process?.isRunning == true else {
                let secs = Int(Date().timeIntervalSince(startedAt))
                let tail = Self.readSwiftLMLogTail()
                Logger.orchestrator.error("SwiftLM exited during startup after \(secs)s. Last lines:\n\(tail, privacy: .public)")
                let msg = "SwiftLM exited \(secs)s into startup. Tail of /tmp/lemon-swiftlm.log:\n\n\(tail)"
                process = nil
                _state = .failed(msg)
                return
            }
            if await healthCheck() {
                _ready = true
                _state = .ready
                Logger.orchestrator.info("SwiftLM ready on port \(self.port) after \(Int(Date().timeIntervalSince(startedAt))) s")
                return
            }
        }
        let msg = "SwiftLM didn't reach /health within 180 s — model load stalled."
        Logger.orchestrator.error("\(msg)")
        _state = .failed(msg)
    }

    func stop() {
        _ready = false
        _state = .notConfigured
        process?.terminate()
        process = nil
    }

    // In tests there is no process — treat nil process as "externally managed, assume running".
    // Also detects a post-ready process death: SwiftLM crashed or got SIGKILLed
    // after start() returned successfully. Without this detection, _state stays
    // .ready forever even though the runner is gone, and runAITest's "Race"
    // path keeps re-tripping with no escape — the next start() bails on
    // `guard process == nil` because the dead Process is still parked there.
    // Transition to .failed + clear process so a Re-run actually re-boots.
    func isReady() -> Bool {
        let stillUp = process?.isRunning ?? true
        if _ready && !stillUp {
            let tail = Self.readSwiftLMLogTail()
            Logger.orchestrator.error("SwiftLM process exited after reporting ready. Last lines:\n\(tail, privacy: .public)")
            _ready = false
            let msg = "SwiftLM exited after startup. Tail of /tmp/lemon-swiftlm.log:\n\n\(tail)"
            _state = .failed(msg)
            process = nil
            return false
        }
        return _ready && stillUp
    }

    // Find anything bound to our port (typically a zombie SwiftLM from a
    // previous Lemon launch) and SIGTERM it. Synchronous + best-effort;
    // we don't care if it fails (no process to kill is the same as success).
    static func killProcessHoldingPort(_ port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let outPipe = Pipe()
        lsof.standardOutput = outPipe
        lsof.standardError = Pipe()
        do {
            try lsof.run(); lsof.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pids = out.split(whereSeparator: { $0.isNewline })
                          .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                Logger.orchestrator.info("Killing zombie process pid=\(pid) on port \(port)")
                kill(Int32(pid), SIGTERM)
            }
            // Brief grace period so the kernel releases the socket before we bind.
            if !pids.isEmpty {
                Thread.sleep(forTimeInterval: 0.3)
            }
        } catch {
            Logger.orchestrator.warning("lsof probe failed (ok if first launch): \(error.localizedDescription)")
        }
    }

    // Reads the last ~80 lines (truncated to 1.5 KB) of the SwiftLM stream
    // we've been draining to /tmp/lemon-swiftlm.log. Surfaces in the Self-test
    // failure card so the user sees the actual SwiftLM error (model load fault,
    // GPU OOM, missing tensor, etc.) instead of a generic "exited" message.
    static func readSwiftLMLogTail(maxBytes: Int = 1500) -> String {
        let path = "/tmp/lemon-swiftlm.log"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              !content.isEmpty else {
            return "(log empty or unreadable — see Console.app)"
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxBytes else { return trimmed }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var acc = ""
        for line in lines.reversed() {
            let next = String(line) + (acc.isEmpty ? "" : "\n") + acc
            if next.count > maxBytes { break }
            acc = next
        }
        return acc.isEmpty ? String(trimmed.suffix(maxBytes)) : "…\n\(acc)"
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        guard let (_, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200 else { return false }
        return true
    }

    // MARK: - Inference

    func classify(issue: LinearIssue, logLines: [String]) async throws -> GemmaResponse {
        let systemPrompt = """
        You monitor a running Claude Code coding session for Lemon. Given the last \
        terminal output, classify the session and decide whether to act.

        Respond with ONLY valid JSON, no prose:
        {
          "state": "running" | "blocked_prompt" | "stuck" | "waiting" | "complete",
          "summary": "<one short sentence>",
          "action": null
            | { "type": "send_keys", "keys": "<one of: y, n, yes, no, 1-9, or empty>" }
            | { "type": "notify_user", "message": "<short msg>" }
        }

        Rules:
        - send_keys is ONLY for unambiguous confirmation prompts where the safe answer is obvious:
            • An MCP server install/trust prompt that the user clearly opted into
            • A numbered menu where one option is plainly the intended path
            • A "Continue? [Y/n]" where context says yes
            • A pre-checked multi-select list (e.g. Claude Code's "Select any MCP servers to enable" with all boxes ticked) — confirm with Enter
          DO NOT use send_keys for anything destructive, ambiguous, or open-ended.
          DO NOT type free-form text — keys MUST be one of:
              y / Y / n / N / yes / no / 1-9
              Enter (confirm the default / pre-checked list)
              Escape (reject / cancel)
              Space (toggle a single highlighted item)
        - notify_user when the session needs a human (auth, design choice, error).
        - complete when a PR URL or "PR opened" appears in output.
        - stuck when no progress for many minutes with no question visible.
        - When in doubt return action: null.

        Examples:

        Output: "Trust this MCP server (linear)? [y/N]"
        → {"state":"blocked_prompt","summary":"MCP server trust prompt for Linear",
            "action":{"type":"send_keys","keys":"y"}}

        Output: "6 new MCP servers found in this project / Select any you wish to enable. / [✓] vercel [✓] neon [✓] linear-server / Space to select · Enter to confirm"
        → {"state":"blocked_prompt","summary":"MCP server picker with all servers pre-checked",
            "action":{"type":"send_keys","keys":"Enter"}}

        Output: "Which database should I migrate? 1) prod 2) staging"
        → {"state":"blocked_prompt","summary":"Asking which database to migrate",
            "action":{"type":"notify_user","message":"Choose database: prod vs staging"}}

        Output: "Opened https://github.com/x/y/pull/42"
        → {"state":"complete","summary":"PR opened","action":null}

        Output: "$" (idle prompt for 5 minutes, no question)
        → {"state":"stuck","summary":"No progress for several minutes","action":null}
        """

        let issueCtx = "Issue: \(issue.identifier) — \(issue.title)\n" +
            (issue.description.map { String($0.prefix(400)) } ?? "")
        let terminal = logLines.isEmpty ? "(no output yet)" : logLines.joined(separator: "\n")
        let userMsg  = "\(issueCtx)\n\nLast terminal output:\n\(terminal)"

        let body: [String: Any] = [
            "model": "local-model",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMsg]
            ],
            "response_format": ["type": "json_object"],
            "max_tokens": 200,
            "temperature": 0.1
        ]

        guard let url  = URL(string: "http://localhost:\(port)/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LocalLLMError.invalidRequest
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody   = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let (responseData, _) = try await session.data(for: req)

        // Parse OpenAI-compatible wrapper, then decode the inner JSON string.
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: responseData)
        guard let content = chat.choices.first?.message.content else {
            throw LocalLLMError.invalidResponse
        }
        // GemmaResponse.parse strips markdown fences and prose, then decodes.
        // Smaller / chat-tuned models routinely emit ```json {...} ``` or
        // leading "Here's my analysis: {...}" — the raw decoder would reject
        // both, leaving the silence-detector pipeline silently broken.
        do {
            return try GemmaResponse.parse(content)
        } catch let err as GemmaResponse.ParseError {
            Logger.orchestrator.error("Gemma response parse failed: \(String(describing: err)); raw=\(content.prefix(400), privacy: .public)")
            throw LocalLLMError.invalidResponse
        }
    }
}

enum LocalLLMError: Error, Equatable {
    case invalidRequest
    case invalidResponse
}
