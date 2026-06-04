import Foundation

struct LinearIssue: Identifiable, Codable, Equatable {
    let id: String
    let identifier: String  // e.g. "LEM-42"
    let title: String
    let description: String?
    let labelNames: [String]
    let teamId: String

    var identifierPrefix: String {
        String(identifier.prefix(while: { $0.isLetter }))
    }
}

struct WorkspaceRepo: Codable, Identifiable {
    var id: UUID = UUID()
    var issuePrefix: String        // e.g. "LEM" matches "LEM-42"
    var path: String               // single repo path OR parent folder
    var allReposInFolder: Bool = false
    var homeRepo: String = ""      // subdirectory to launch Claude in (e.g. "memory"); empty = session root
}

enum SessionStatus: Equatable {
    case planning    // worktree setup
    case executing   // claude session running
    case waiting     // claude paused, awaiting human input
    case reviewing   // PR open, Lemon comment posted
    case done        // issue moved to completed state
    case failed      // worktree/process error

    var displayLabel: String {
        switch self {
        case .planning:  return "Planning"
        case .executing: return "Executing"
        case .waiting:   return "Waiting"
        case .reviewing: return "Reviewing"
        case .done:      return "Done"
        case .failed:    return "Failed"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

struct LemonMarker {
    let branch: String
    let prNumber: String
    let commentId: String
    let repoPath: String
}

@Observable
final class Session: Identifiable {
    let id: UUID = UUID()
    let issue: LinearIssue
    let startedAt: Date
    var status: SessionStatus = .planning
    var logLines: [String] = []
    var prUrl: String?
    var worktreePath: String?
    var terminalWindowName: String?
    var endedAt: Date?
    var aiSummary: String?
    var pendingAction: String?

    init(issue: LinearIssue) {
        self.issue = issue
        self.startedAt = Date()
    }

    #if DEBUG
    init(issue: LinearIssue, startedAt: Date) {
        self.issue = issue
        self.startedAt = startedAt
    }
    #endif

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 { logLines.removeFirst() }
    }
}

// MARK: - Gemma response types

struct GemmaResponse: Decodable {
    let state: String
    let summary: String
    let action: GemmaAction?

    enum ParseError: Error, Equatable {
        case empty
        case noJSON
        case decodeFailed(String)
    }

    // Robust parser for the inner JSON content returned by SwiftLM's
    // /v1/chat/completions choices[0].message.content. Chat-tuned models
    // sometimes wrap the JSON in markdown fences (```json ... ```), prefix it
    // with prose, or trail commentary. This locates the JSON body, strips
    // fences/prose, and decodes — handing back a typed ParseError when it
    // can't recover, so callers can degrade gracefully instead of crashing.
    static func parse(_ raw: String) throws -> GemmaResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        // Strip ```json ... ``` or ``` ... ``` fences if present.
        let fenced: String = {
            guard trimmed.hasPrefix("```") else { return trimmed }
            // Drop opening fence (and optional "json" tag) up to the first newline.
            let afterOpenFence = trimmed
                .drop(while: { $0 == "`" })
                .drop(while: { !$0.isNewline })
                .dropFirst()  // the newline itself
            // Drop the trailing fence + any trailing whitespace.
            var body = String(afterOpenFence)
            if let range = body.range(of: "```", options: .backwards) {
                body = String(body[..<range.lowerBound])
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        // Fall back to extracting the first {...} object in case the model
        // emitted prose before or after the JSON.
        let jsonString: String = {
            if fenced.hasPrefix("{") { return fenced }
            guard let start = fenced.firstIndex(of: "{"),
                  let end   = fenced.lastIndex(of: "}"),
                  start < end else { return fenced }
            return String(fenced[start...end])
        }()

        guard jsonString.hasPrefix("{") else { throw ParseError.noJSON }
        do {
            return try JSONDecoder().decode(GemmaResponse.self, from: Data(jsonString.utf8))
        } catch {
            throw ParseError.decodeFailed(error.localizedDescription)
        }
    }
}

struct GemmaAction: Decodable {
    let type: String       // "send_keys" | "notify_user"
    let keys: String?
    let message: String?
}
