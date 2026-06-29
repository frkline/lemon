import Foundation

struct LinearIssue: Identifiable, Codable, Equatable {
    let id: String
    let identifier: String // e.g. "LEM-42"
    let title: String
    let description: String?
    let labelNames: [String]
    let teamId: String
    var creatorName: String? = nil // issue opener (trust boundary #13)

    var identifierPrefix: String {
        String(identifier.prefix(while: { $0.isLetter }))
    }
}

struct WorkspaceRepo: Codable, Identifiable {
    var id: UUID = .init()
    var issuePrefix: String // e.g. "LEM" matches "LEM-42"
    var path: String // single repo path OR parent folder
    var allReposInFolder: Bool = false
    var homeRepo: String = "" // subdirectory to launch Claude in (e.g. "memory"); empty = session root
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
        case .linear: "Linear"
        case .github: "GitHub"
        }
    }
}

enum IssueScope: Codable, Equatable, Hashable {
    case linearTeam(id: String)
    case githubRepo(owner: String, repo: String, number: Int)
}

struct IssueRef: Identifiable, Codable, Equatable, Hashable {
    let id: String // opaque source-side id (Linear node id, or "owner/repo#n")
    let identifier: String // human-facing label, e.g. "HRP-42" or "acme/widgets#7"
    let title: String
    let description: String?
    let labelNames: [String]
    let scope: IssueScope
    /// Issue opener (GitHub login / Linear creator). nil = unknown. Used by
    /// lockdown (#13) to trigger only on the user's own issues.
    var authorLogin: String? = nil

    var source: IssueSource {
        switch scope {
        case .linearTeam: .linear
        case .githubRepo: .github
        }
    }

    /// Linear-style prefix ("HRP" for "HRP-42"). For GitHub identifiers this
    /// returns whatever leading-letters happen to be there; routing for GH
    /// pairs goes through scope, not prefix, so the value is unused in that path.
    var identifierPrefix: String {
        String(identifier.prefix(while: { $0.isLetter }))
    }

    /// Namespaced so Linear node IDs and GitHub identifiers can't collide in
    /// SessionStore.isTracking — see plan §5.
    var trackingKey: String {
        "\(source.rawValue):\(id)"
    }

    /// Drives /tmp/lemon-{slug} worktree paths. Linear: "lem-42". GitHub:
    /// "acme-widgets-7" — slashes flatten to dashes, lowercased so filesystem
    /// case-insensitivity on APFS doesn't bite.
    var pathSlug: String {
        switch scope {
        case .linearTeam:
            identifier.lowercased()
        case let .githubRepo(owner, repo, number):
            "\(owner)-\(repo)-\(number)"
                .lowercased()
                .replacingOccurrences(of: "/", with: "-")
        }
    }

    /// Adapter from the Linear-specific issue shape used by LinearClient
    /// internals. Mirrors LinearIssue field-for-field.
    init(linearIssue i: LinearIssue) {
        self.id = i.id
        self.identifier = i.identifier
        self.title = i.title
        self.description = i.description
        self.labelNames = i.labelNames
        self.scope = .linearTeam(id: i.teamId)
        self.authorLogin = i.creatorName
    }

    init(id: String, identifier: String, title: String, description: String?,
         labelNames: [String], scope: IssueScope, authorLogin: String? = nil)
    {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.description = description
        self.labelNames = labelNames
        self.scope = scope
        self.authorLogin = authorLogin
    }
}

/// Source-agnostic comment used by both LinearClient and GitHubClient. The
/// shared LemonMarkerExtractor consumes these.
struct IssueComment: Identifiable, Equatable {
    let id: String
    let body: String
    let createdAt: Date
    /// Commenter identity (GitHub login / Linear user name or id). nil = unknown.
    /// Used by the trust boundary (#13): in lockdown only the user's own comments
    /// re-trigger, and non-user content is wrapped/excluded in LEMON_CONTEXT.
    var author: String?
}

// MARK: - Identity → Surface → Workspace

//
// The richer mental model that supersedes WorkspacePair. Three layers:
//   • Identity  — a credential (Linear key, GitHub PAT, future MCP/Git).
//                 Knows its own surfaces. Multiple identities are allowed
//                 (work + oss Linear accounts; github.com + Enterprise host).
//   • Surface   — a queryable scope under an identity (Linear team, GitHub
//                 repo, MCP namespace). Cached on the identity so editor
//                 pickers populate from known surfaces, not free text.
//   • Workspace — a local folder/repo with one routing that names which
//                 identity + which surface owns its issues.
//
// Existing `WorkspacePair` is kept below for migration + a thin synthesizer
// view; the identity-aware code paths supersede it.

enum IdentityKind: String, Codable, Hashable {
    case linear
    case github
    // Reserved for the deferred work tracked in issue #12:
    //   case mcp
    //   case git

    var displayName: String {
        switch self {
        case .linear: "Linear"
        case .github: "GitHub"
        }
    }

    var issueSource: IssueSource {
        switch self {
        case .linear: .linear
        case .github: .github
        }
    }
}

/// One discoverable scope on an identity — a Linear team or a GitHub repo.
struct Surface: Codable, Hashable, Identifiable {
    /// Stable identifier inside the identity. For Linear: team.id. For GitHub:
    /// "owner/repo".
    var id: String
    /// Short human handle used for routing lookups. Linear: team.key ("HRP").
    /// GitHub: "owner/repo" (same as id; kept for parity).
    var key: String
    /// Display label shown in editor pickers ("Harpy Rocks", "frkline/lemon").
    var displayName: String
}

/// One credential + the surfaces it can reach.
struct Identity: Codable, Identifiable, Hashable {
    var id: UUID = .init()
    var kind: IdentityKind

    /// User-facing label in the editor — "Linear · work", "GitHub · @frkline".
    /// Defaults from the verified handle but the user can override.
    var label: String

    /// Resolved handle from `verifyCredential`. Linear: user name. GitHub: login.
    var handle: String

    /// Source-side principal id (Linear node id, GitHub user id). Used as the
    /// assignee filter when polling.
    var principalId: String

    /// API host. nil/"api.github.com" means github.com; an Enterprise host
    /// looks like "api.github.acmecorp.com". Linear ignores this.
    var host: String?

    /// Cache of discovered surfaces. Populated by `verifyCredential` and the
    /// refresh action. Pickers in the editor read from this; if empty, they
    /// fall back to free-text entry.
    var knownSurfaces: [Surface] = []

    /// Last time `knownSurfaces` was refreshed; nil pre-first-verify.
    var surfacesFetchedAt: Date?
}

/// Where a workspace's issues come from. One per workspace (per the
/// product decision to defer multi-routing — issue #10 thread).
struct Routing: Codable, Hashable {
    var identityId: UUID
    /// `Surface.id` under the identity. The orchestrator looks up the surface
    /// on the resolved identity at poll time.
    var surfaceId: String
}

enum AgentEngineKind: String, Codable, Hashable, CaseIterable {
    case claudeCode = "claude_code"
    case openCode = "opencode"

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        }
    }

    var chipLabel: String {
        switch self {
        case .claudeCode: "claude"
        case .openCode: "opencode"
        }
    }
}

enum OpenCodeAutoOpenThreshold: String, Codable, Hashable, CaseIterable {
    case off
    case highConfidenceOnly = "high_confidence_only"
    case anyApprove = "any_approve"

    var displayName: String {
        switch self {
        case .off: "Off"
        case .highConfidenceOnly: "High confidence only"
        case .anyApprove: "Any approve"
        }
    }
}

struct OpenCodeModelConfig: Codable, Hashable {
    var plan: String = ""
    var code: String = ""
    var review: String = ""

    static let defaultSuggestedModels: [String] = [
        "openai/gpt-5.3-codex",
        "anthropic/claude-opus-4",
        "anthropic/claude-sonnet-4",
        "openai/gpt-4.1-mini",
    ]

    var hasAllConfigured: Bool {
        !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var malformedConfiguredModels: [String] {
        [plan, code, review]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { Self.providerSlug(for: $0) == nil }
    }

    var requiredProviders: [String] {
        let parsed = [plan, code, review]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(Self.providerSlug(for:))
        var seen = Set<String>()
        var ordered: [String] = []
        for provider in parsed where seen.insert(provider).inserted {
            ordered.append(provider)
        }
        return ordered
    }

    static func providerSlug(for modelID: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return provider.isEmpty ? nil : provider
    }

    static func splitProviderModel(_ modelID: String) -> (providerID: String, modelID: String)? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let model = String(trimmed[trimmed.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }
}

struct OpenCodeDaemonConfig: Codable, Hashable {
    var host: String = "127.0.0.1"
    var port: Int = 4096
}

struct OpenCodeWorkspaceConfig: Codable, Hashable {
    var models: OpenCodeModelConfig = .init()
    var autoOpenThreshold: OpenCodeAutoOpenThreshold = .highConfidenceOnly
    var daemon: OpenCodeDaemonConfig = .init()
}

struct WorkspaceEngineConfig: Codable, Hashable {
    var kind: AgentEngineKind = .claudeCode
    var openCode: OpenCodeWorkspaceConfig? = nil

    static let claudeDefault = WorkspaceEngineConfig()
}

/// Local folder + a single routing.
struct Workspace: Codable, Identifiable, Hashable {
    var id: UUID = .init()
    var path: String
    var allReposInFolder: Bool = false
    var homeRepo: String = ""
    var routing: Routing
    /// Lockdown (the #13 trust boundary). When on, Lemon treats this workspace
    /// as low-trust: only issues the user authored trigger, only the user's own
    /// comments re-trigger, and any non-user content in LEMON_CONTEXT is excluded
    /// (vs. delimiter-wrapped when off). Default on is offered for public GitHub
    /// repos in onboarding. Decodes false for pre-lockdown configs.
    var lockdown: Bool = false
    /// Per-workspace agent engine selection and engine-specific config.
    /// Defaults to Claude Code for backward compatibility.
    var engine: WorkspaceEngineConfig = .claudeDefault

    init(id: UUID = .init(), path: String, allReposInFolder: Bool = false,
         homeRepo: String = "", routing: Routing, lockdown: Bool = false,
         engine: WorkspaceEngineConfig = .claudeDefault)
    {
        self.id = id
        self.path = path
        self.allReposInFolder = allReposInFolder
        self.homeRepo = homeRepo
        self.routing = routing
        self.lockdown = lockdown
        self.engine = engine
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, allReposInFolder, homeRepo, routing, lockdown, engine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        allReposInFolder = try container.decodeIfPresent(Bool.self, forKey: .allReposInFolder) ?? false
        homeRepo = try container.decodeIfPresent(String.self, forKey: .homeRepo) ?? ""
        routing = try container.decode(Routing.self, forKey: .routing)
        lockdown = try container.decodeIfPresent(Bool.self, forKey: .lockdown) ?? false
        engine = try container.decodeIfPresent(WorkspaceEngineConfig.self, forKey: .engine) ?? .claudeDefault
    }
}

// MARK: - Legacy WorkspacePair surface (migration source)

struct SourceConfig: Codable, Identifiable, Hashable {
    var id: UUID = .init()
    var source: IssueSource
    var displayName: String
    var linearTeamKeys: [String]? // optional allowlist; nil = all teams
    var githubRepos: [String]? // "owner/repo" entries
}

struct WorkspaceMapping: Codable, Hashable {
    var matchKey: String // Linear team key ("HRP") or GH "owner/repo"
    var path: String
    var allReposInFolder: Bool = false
    var homeRepo: String = ""
}

struct WorkspacePair: Codable, Identifiable, Hashable {
    var id: UUID = .init()
    var source: SourceConfig
    var workspace: WorkspaceMapping
}

/// Lemon label state, mapped through each client to its source-specific
/// representation (Linear label ID, GitHub label name).
enum LemonState: String, CaseIterable, Equatable {
    case trigger
    case inProgress
    case waiting
    case complete

    var labelName: String {
        switch self {
        case .trigger: "🍋"
        case .inProgress: "🍋 In Progress"
        case .waiting: "🍋 Waiting"
        case .complete: "🍋 Complete"
        }
    }

    static let active: Set<LemonState> = [.inProgress, .waiting, .complete]
}

enum SessionStatus: String, Codable, Equatable {
    case queued // triggered but over the concurrency limit — awaiting a free slot (#46)
    case planning // worktree setup
    case planReview // plan drafted, awaiting human approval (the plan gate)
    case executing // claude session running
    case waiting // claude paused, awaiting human input
    case resultReview // build done, awaiting human go to open PR (the result gate)
    case reviewing // PR open, Lemon comment posted
    case done // issue moved to completed state
    case failed // worktree/process error

    var displayLabel: String {
        switch self {
        case .queued: "Queued"
        case .planning: "Planning"
        case .planReview: "Plan Review"
        case .executing: "Executing"
        case .waiting: "Waiting"
        case .resultReview: "Result Review"
        case .reviewing: "Reviewing"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// The two human gates — Lemon is parked awaiting an approve/feedback signal.
    var isGate: Bool {
        switch self {
        case .planReview, .resultReview: true
        default: false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }
}

/// Aggregate menu-bar state derived from all sessions, mapped to the design
/// handoff's six glyph states (idle/working/waiting/done/error/disabled). The
/// NSImage assets are the `MenuLemon*` template imagesets; loading lives in the
/// AppKit layer (LemonApp) since Models stays Foundation-only.
enum MenuBarGlyph: String, CaseIterable {
    case idle, working, waiting, done, error, disabled

    var assetName: String {
        switch self {
        case .idle: "MenuLemonIdle"
        case .working: "MenuLemonWorking"
        case .waiting: "MenuLemonWaiting"
        case .done: "MenuLemonDone"
        case .error: "MenuLemonError"
        case .disabled: "MenuLemonDisabled"
        }
    }

    /// How long a freshly-failed session keeps the glyph red (#48). An error is
    /// only worth the user's eye while it's actionable; past this window the
    /// glyph decays so an idle app reads idle, not stuck on a stale failure.
    static let errorWindow: TimeInterval = 5 * 60

    /// Pure aggregate: which glyph for the current sessions. Priority reflects
    /// what most needs the user's eye — a session awaiting human input (either
    /// gate, or a mid-build question) wins, then active work, then a reviewing
    /// session (finished, awaiting cleanup), then the most recent terminal
    /// outcome. Disabled when nothing is configured. Pure so it's unit-testable
    /// without AppKit or the Keychain (pass an explicit `now` for determinism).
    static func aggregate(activeStatuses: [SessionStatus],
                          lastRecentStatus: SessionStatus?,
                          lastRecentEndedAt: Date? = nil,
                          now: Date = Date(),
                          configured: Bool) -> MenuBarGlyph
    {
        guard configured else { return .disabled }
        if activeStatuses.contains(where: { $0.isGate || $0 == .waiting }) { return .waiting }
        if activeStatuses.contains(where: { $0 == .planning || $0 == .executing || $0 == .queued }) { return .working }
        if activeStatuses.contains(.reviewing) { return .done }
        if lastRecentStatus == .failed {
            // #48: only stay red while the failure is fresh. With no timestamp
            // (mock/legacy) or once the window has elapsed, decay to idle so a
            // single past failure doesn't pin the glyph to error forever.
            if let endedAt = lastRecentEndedAt, now.timeIntervalSince(endedAt) < errorWindow {
                return .error
            }
            return .idle
        }
        if lastRecentStatus == .done { return .done }
        return .idle
    }
}

struct LemonMarker: Codable, Equatable {
    let branch: String
    let prNumber: String
    let commentId: String
    let repoPath: String
    /// Pre-upgrade comments omit this line; nil parses as .linear so existing
    /// re-trigger flows keep working after the multi-source migration.
    let source: IssueSource?
}

/// Everything Orchestrator needs to clean up a finished session's
/// worktree(s) + tmux + /tmp leftovers, stashed on the Session so the
/// user can fire the cleanup later from the "Ready for review" card
/// without WorktreeRunner staying alive in memory.
struct WorktreeCleanupInfo: Codable, Equatable {
    let sessionPath: String
    let isMultiRepo: Bool
    /// Per-repo (name, source-repo-path) tuples — both single-repo and
    /// multi-repo cleanup walk this list. For single-repo, count == 1.
    let repos: [RepoRef]
    let slug: String

    struct RepoRef: Codable, Equatable {
        let name: String
        let repoPath: String
    }
}

@Observable
final class Session: Identifiable {
    let id: UUID = .init()
    let issue: IssueRef
    let startedAt: Date
    /// The owning Workspace.id, stashed so the persisted session index
    /// (issue #35) can rebuild the WorkspacePair on reattach. Set by
    /// Orchestrator.startSession / restoreSessions; nil for mock/smoke sessions.
    var workspaceId: UUID?
    /// Git branch and re-trigger marker, stashed so `SessionStore.persist()` is a
    /// faithful projection — reattach resumes `pollUntilDone` with the same
    /// branch (for PR detection) and retrigger (for the completion path).
    var branch: String?
    var retrigger: LemonMarker?
    var status: SessionStatus = .planning
    var logLines: [String] = []
    var prUrl: String?
    var worktreePath: String?
    var terminalWindowName: String?
    var endedAt: Date?
    var aiSummary: String?
    var pendingAction: String?
    /// The plan Claude proposed, read from the plan sentinel it writes in auto
    /// mode. Shown in the `.planReview` gate card for approval.
    var planMarkdown: String?
    /// Populated when handleComplete fires. The session moves to
    /// `.reviewing` and stays in the active list until the user clicks
    /// "Cleanup worktree" in the detail view, which fires
    /// `Orchestrator.cleanupSession`.
    var cleanupInfo: WorktreeCleanupInfo?
    /// Set once the PR for a `.reviewing` session is detected as merged (#54).
    /// Surfaces "✅ Merged — ready to clean up" on the review card; teardown
    /// stays a confirm-first click (Orchestrator.cleanupSession).
    var prMerged: Bool = false
    /// Silence-detector timing for the Gemma idle countdown (#50): when the pane
    /// last produced output, and when Gemma last classified. The view derives
    /// "Gemma checks in 0:48" / "Listening" / "Looked just now" from these.
    var lastPaneActivityAt: Date?
    var lastGemmaClassifyAt: Date?

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

/// Value-type projection of a `Session` persisted to UserDefaults so Lemon can
/// reattach to still-running tmux sessions after a relaunch/crash (issue #35).
/// The live `Session` (`@Observable`, holds log buffers) is intentionally NOT
/// Codable — only the fields reattach needs are stored. The real `IssueRef` is
/// kept (not reconstructed from the slug) because `pathSlug → IssueRef` is lossy:
/// for Linear the node `id` is unrecoverable, so `fetchIssueLabels`/`postComment`
/// would fail.
struct PersistedSession: Codable, Equatable {
    let issue: IssueRef
    let workspaceId: UUID
    let slug: String
    let branch: String
    let status: SessionStatus
    let retrigger: LemonMarker?
    let startedAt: Date
    let cleanupInfo: WorktreeCleanupInfo?
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

    /// Robust parser for the inner JSON content returned by SwiftLM's
    /// /v1/chat/completions choices[0].message.content. Chat-tuned models
    /// sometimes wrap the JSON in markdown fences (```json ... ```), prefix it
    /// with prose, or trail commentary. This locates the JSON body, strips
    /// fences/prose, and decodes — handing back a typed ParseError when it
    /// can't recover, so callers can degrade gracefully instead of crashing.
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
                .dropFirst() // the newline itself
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
                  let end = fenced.lastIndex(of: "}"),
                  start < end else { return fenced }
            return String(fenced[start ... end])
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
    let type: String // "send_keys" | "notify_user"
    let keys: String?
    let message: String?
}
