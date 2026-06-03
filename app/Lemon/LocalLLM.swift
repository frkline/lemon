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

    private init(port: Int, session: URLSession) {
        self.port = port
        self.session = session
    }

    #if DEBUG
    static func makeForTesting(port: Int, session: URLSession) -> LocalLLM {
        let llm = LocalLLM(port: port, session: session)
        llm._ready = true
        return llm
    }
    #endif

    // MARK: - Lifecycle

    func start() async {
        let store = KeychainStore.shared
        guard store.aiEnabled, !store.swiftLMPath.isEmpty, !store.modelPath.isEmpty else { return }
        guard process == nil else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: store.swiftLMPath)
        // SwiftLM CLI: --model-path <dir> --port <n>
        // Adjust if your SwiftLM build uses different flags.
        p.arguments = ["--model-path", store.modelPath, "--port", "\(port)"]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            process = p
            Logger.orchestrator.info("SwiftLM launched (pid \(p.processIdentifier))")
        } catch {
            Logger.orchestrator.error("SwiftLM launch failed: \(error)")
            return
        }

        // Poll /health up to 30 s for the server to become ready.
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            guard process?.isRunning == true else {
                Logger.orchestrator.error("SwiftLM exited during startup")
                process = nil
                return
            }
            if await healthCheck() {
                _ready = true
                Logger.orchestrator.info("SwiftLM ready on port \(self.port)")
                return
            }
        }
        Logger.orchestrator.error("SwiftLM did not become healthy within 30 s")
    }

    func stop() {
        _ready = false
        process?.terminate()
        process = nil
    }

    // In tests there is no process — treat nil process as "externally managed, assume running".
    func isReady() -> Bool { _ready && (process?.isRunning ?? true) }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        return (try? await session.data(from: url)) != nil
    }

    // MARK: - Inference

    func classify(issue: LinearIssue, logLines: [String]) async throws -> GemmaResponse {
        let systemPrompt = """
        You are a session monitor for Lemon, an AI coding agent orchestrator. \
        A Claude coding session is running on the user's machine. \
        Classify the current state and decide if action is needed. \
        Respond ONLY with valid JSON: \
        { "state": "running|blocked_prompt|stuck|waiting|complete", \
          "summary": "<one sentence>", \
          "action": null | { "type": "send_keys", "keys": "<keys>" } \
                          | { "type": "notify_user", "message": "<msg>" } } \
        Use send_keys ONLY for unambiguous low-risk confirmations (e.g. accept a pre-selected list). \
        When in doubt, use notify_user or return null.
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
        guard let content    = chat.choices.first?.message.content,
              let innerData  = content.data(using: .utf8) else {
            throw LocalLLMError.invalidResponse
        }
        return try JSONDecoder().decode(GemmaResponse.self, from: innerData)
    }
}

enum LocalLLMError: Error, Equatable {
    case invalidRequest
    case invalidResponse
}
