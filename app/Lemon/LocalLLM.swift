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

        let p = Process()
        p.executableURL = URL(fileURLWithPath: store.swiftLMPath)
        // SwiftLM b648 CLI: --model <hf-id-or-local-path> --port <n>
        // Verified against `SwiftLM --help`; do not use --model-path.
        p.arguments = ["--model", store.modelPath, "--port", "\(port)"]
        Logger.orchestrator.info("SwiftLM launching: \(store.swiftLMPath) --model \(store.modelPath) --port \(self.port)")
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            process = p
            _state = .starting
            Logger.orchestrator.info("SwiftLM launched (pid \(p.processIdentifier))")
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
                let msg = "SwiftLM exited during startup after \(secs) s — check `log stream --predicate 'subsystem == \"com.lemon.app\"'`"
                Logger.orchestrator.error("\(msg)")
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
    func isReady() -> Bool { _ready && (process?.isRunning ?? true) }

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
