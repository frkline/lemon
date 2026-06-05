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

// MARK: - Source-agnostic issue model
//
// `IssueRef` is the lingua franca between Orchestrator/WorktreeRunner and the
// per-source clients (LinearClient, GitHubClient). Each client maps its own
// raw response into IssueRef at the boundary; downstream code never sees the
// source-specific shape.

enum IssueSource: String, Codable, Hashable {
    case linear
    case github

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .github: return "GitHub"
        }
    }
}

enum IssueScope: Codable, Equatable, Hashable {
    case linearTeam(id: String)
    case githubRepo(owner: String, repo: String, number: Int)
}

struct IssueRef: Identifiable, Codable, Equatable, Hashable {
    let id: String              // opaque source-side id (Linear node id, or "owner/repo#n")
    let identifier: String      // human-facing label, e.g. "HRP-42" or "acme/widgets#7"
    let title: String
    let description: String?
    let labelNames: [String]
    let scope: IssueScope

    var source: IssueSource {
        switch scope {
        case .linearTeam:  return .linear
        case .githubRepo:  return .github
        }
    }

    // Linear-style prefix ("HRP" for "HRP-42"). For GitHub identifiers this
    // returns whatever leading-letters happen to be there; routing for GH
    // pairs goes through scope, not prefix, so the value is unused in that path.
    var identifierPrefix: String {
        String(identifier.prefix(while: { $0.isLetter }))
    }

    // Namespaced so Linear node IDs and GitHub identifiers can't collide in
    // SessionStore.isTracking — see plan §5.
    var trackingKey: String { "\(source.rawValue):\(id)" }

    // Drives /tmp/lemon-{slug} worktree paths. Linear: "lem-42". GitHub:
    // "acme-widgets-7" — slashes flatten to dashes, lowercased so filesystem
    // case-insensitivity on APFS doesn't bite.
    var pathSlug: String {
        switch scope {
        case .linearTeam:
            return identifier.lowercased()
        case .githubRepo(let owner, let repo, let number):
            return "\(owner)-\(repo)-\(number)"
                .lowercased()
                .replacingOccurrences(of: "/", with: "-")
        }
    }

    // Adapter from the Linear-specific issue shape used by LinearClient
    // internals. Mirrors LinearIssue field-for-field.
    init(linearIssue i: LinearIssue) {
        self.id = i.id
        self.identifier = i.identifier
        self.title = i.title
        self.description = i.description
        self.labelNames = i.labelNames
        self.scope = .linearTeam(id: i.teamId)
    }

    init(id: String, identifier: String, title: String, description: String?,
         labelNames: [String], scope: IssueScope) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.description = description
        self.labelNames = labelNames
        self.scope = scope
    }
}

// Source-agnostic comment used by both LinearClient and GitHubClient. The
// shared LemonMarkerExtractor consumes these.
struct IssueComment: Identifiable, Equatable {
    let id: String
    let body: String
    let createdAt: Date
}

// MARK: - Workspace pairs (replacement for WorkspaceRepo array)
//
// One WorkspacePair = one source identity + one local workspace mapping. The
// pair list lives in KeychainStore under "lemon-workspace-pairs", capped at 10.

struct SourceConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var source: IssueSource
    var displayName: String
    var linearTeamKeys: [String]?   // optional allowlist; nil = all teams
    var githubRepos: [String]?      // "owner/repo" entries
}

struct WorkspaceMapping: Codable, Hashable {
    var matchKey: String            // Linear team key ("HRP") or GH "owner/repo"
    var path: String
    var allReposInFolder: Bool = false
    var homeRepo: String = ""
}

struct WorkspacePair: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var source: SourceConfig
    var workspace: WorkspaceMapping
}

// Lemon label state, mapped through each client to its source-specific
// representation (Linear label ID, GitHub label name).
enum LemonState: String, CaseIterable, Equatable {
    case trigger
    case inProgress
    case waiting
    case complete

    var labelName: String {
        switch self {
        case .trigger:    return "🍋"
        case .inProgress: return "🍋 In Progress"
        case .waiting:    return "🍋 Waiting"
        case .complete:   return "🍋 Complete"
        }
    }

    static let active: Set<LemonState> = [.inProgress, .waiting, .complete]
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

struct LemonMarker: Equatable {
    let branch: String
    let prNumber: String
    let commentId: String
    let repoPath: String
    // Pre-upgrade comments omit this line; nil parses as .linear so existing
    // re-trigger flows keep working after the multi-source migration.
    let source: IssueSource?
}

@Observable
final class Session: Identifiable {
    let id: UUID = UUID()
    let issue: IssueRef
    let startedAt: Date
    var status: SessionStatus = .planning
    var logLines: [String] = []
    var prUrl: String?
    var worktreePath: String?
    var terminalWindowName: String?
    var endedAt: Date?
    var aiSummary: String?
    var pendingAction: String?

    init(issue: IssueRef) {
        self.issue = issue
        self.startedAt = Date()
    }

    #if DEBUG
    init(issue: IssueRef, startedAt: Date) {
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
