import Foundation
import os

// REST v3 GitHub Issues client. Conforms to IssueSourceClient so Orchestrator
// + WorktreeRunner treat it identically to LinearClient.
//
// Auth: PAT via `Authorization: Bearer <pat>`. Per-pair credential, threaded
// through SourceAuth at each call (matches LinearClient shape).
//
// Polling, not webhooks — Lemon has no public endpoint. Webhook support
// (Linear + GitHub) is tracked separately as #4.
final class GitHubClient: Sendable {
    static let defaultHost = "api.github.com"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves the API base URL for an auth payload. github.com defaults
    /// when host is nil/empty; otherwise treats the host as the API host
    /// (e.g. `api.github.acmecorp.com`).
    private static func baseURL(host: String?) -> URL {
        let resolved = host?.trimmingCharacters(in: .whitespaces)
        let h = (resolved?.isEmpty == false) ? resolved! : Self.defaultHost
        return URL(string: "https://\(h)")!
    }

    // MARK: - Public errors

    enum GitHubError: LocalizedError {
        case http(Int, String)
        case rateLimited(resetEpoch: Int?)
        case unexpectedShape

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .rateLimited(let reset):   return "GitHub rate limit hit\(reset.map { " (resets at epoch \($0))" } ?? "")."
            case .unexpectedShape:          return "Unexpected response shape"
            }
        }
    }

    // MARK: - REST plumbing

    private func authedRequest(_ method: String, path: String, query: [URLQueryItem] = [],
                               token: String, host: String? = nil, body: Data? = nil) -> URLRequest {
        let base = Self.baseURL(host: host)
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("lemon", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest, allow404: Bool = false) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        Logger.linear.debug("[gh] \(req.httpMethod ?? "?") \(req.url?.path ?? "?") → HTTP \(status) · \(bodyStr.prefix(300))")

        switch status {
        case 200...299, 204:
            return (status, data)
        case 404 where allow404:
            return (status, data)
        case 403, 429:
            let reset = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Int.init)
            // 403 with rate-limit-remaining=0 is rate limiting; 403 otherwise
            // is permission. Treat both as 403 surface for now.
            if let remaining = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
               remaining == "0" {
                throw GitHubError.rateLimited(resetEpoch: reset)
            }
            throw GitHubError.http(status, bodyStr)
        default:
            throw GitHubError.http(status, bodyStr)
        }
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.unexpectedShape
        }
    }

    // MARK: - DTOs

    private struct UserDTO: Decodable {
        let id: Int
        let login: String
        let name: String?
        let avatar_url: String?
    }

    private struct IssueDTO: Decodable {
        let id: Int
        let number: Int
        let title: String
        let body: String?
        let labels: [LabelDTO]
        let repository_url: String?
        let html_url: String?

        struct LabelDTO: Decodable { let name: String }
    }

    private struct SearchIssuesDTO: Decodable {
        let total_count: Int
        let items: [IssueDTO]
    }

    private struct CommentDTO: Decodable {
        let id: Int
        let body: String?
        let created_at: String
    }

    // MARK: - Search

    // Builds `repo:o/r is:issue is:open label:LABEL (assignee:LOGIN OR no:assignee)`-style query.
    // Multiple repos collapse to multiple `repo:` terms (OR semantics).
    private func buildSearchQuery(label: String, repos: [String], login: String) -> String {
        let repoTerms = repos.map { "repo:\($0)" }.joined(separator: " ")
        // GitHub search OR: either assigned to the user OR unassigned.
        // The OR keyword is required — a bare space is AND, so
        // `(assignee:LOGIN no:assignee)` asks GH for issues both
        // assigned-to-LOGIN AND unassigned, which never matches.
        let assigneeClause = "(assignee:\(login) OR no:assignee)"
        return "\(repoTerms) is:issue is:open label:\"\(label)\" \(assigneeClause)"
    }

    private func searchIssues(label: String, repos: [String], token: String, login: String, host: String?) async throws -> [IssueRef] {
        guard !repos.isEmpty else { return [] }
        let q = buildSearchQuery(label: label, repos: repos, login: login)
        // Log the literal query so we can debug "0 results when there
        // are obviously matches" cases — GitHub's lexical search type
        // can swallow label-with-emoji queries silently.
        Logger.linear.debug("[gh] search q=\(q)")
        let req = authedRequest(
            "GET",
            path: "/search/issues",
            query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "per_page", value: "100")],
            token: token,
            host: host
        )
        let (_, data) = try await send(req)
        let result = try decode(data, as: SearchIssuesDTO.self)
        return result.items.compactMap { dto in
            guard let (owner, repo) = repoCoordsFromURL(dto.repository_url) else { return nil }
            return IssueRef(
                id: "\(owner)/\(repo)#\(dto.number)",
                identifier: "\(owner)/\(repo)#\(dto.number)",
                title: dto.title,
                description: dto.body,
                labelNames: dto.labels.map { Self.normalizeIncomingLabel($0.name) },
                scope: .githubRepo(owner: owner, repo: repo, number: dto.number)
            )
        }
    }

    private func repoCoordsFromURL(_ url: String?) -> (owner: String, repo: String)? {
        // repository_url shape: "https://api.github.com/repos/{owner}/{repo}"
        guard let url, let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "repos" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    private func reposFromConfig(_ config: SourceConfig) -> [String] {
        config.githubRepos ?? []
    }

    private func ghAuth(_ auth: SourceAuth) throws -> (token: String, login: String, host: String?) {
        guard case .github(let pat, let login, let host) = auth else {
            throw IssueSourceError.authMismatch(expected: .github, got: auth.source)
        }
        return (pat, login, host)
    }

    private func ghScope(_ ref: IssueRef) throws -> (owner: String, repo: String, number: Int) {
        guard case .githubRepo(let owner, let repo, let n) = ref.scope else {
            throw IssueSourceError.authMismatch(expected: .github, got: ref.source)
        }
        return (owner, repo, n)
    }

    // MARK: - Label colors
    //
    // GitHub expects bare hex (no leading '#'). LinearClient.labelColors has
    // the canonical lemon palette with '#'; strip it before sending.
    private static func bareHexColor(for state: LemonState) -> String {
        // Key off the canonical labelName ("🍋", "🍋 Complete", …) — the
        // GH rename below only changes what we send to GitHub's API, not
        // the lemon palette identity.
        let withHash = LinearClient.labelColors[state.labelName] ?? "#F7C842"
        return withHash.hasPrefix("#") ? String(withHash.dropFirst()) : withHash
    }

    // MARK: - GitHub label name translation
    //
    // GitHub rejects label names that are ONLY a native emoji
    // ("Name must contain more than native emoji"), so the bare-🍋
    // trigger label can't land. Map the trigger to "🍋 Lemon" on the
    // GH wire and translate inbound labels back to the canonical
    // labelName so downstream code (WorktreeRunner.pollUntilDone,
    // SessionStore state checks) keeps comparing against
    // LemonState.labelName directly. Linear has no such restriction
    // and continues using bare "🍋".
    private static let ghTriggerLabelName = "🍋 Lemon"

    private static func ghLabelName(for state: LemonState) -> String {
        switch state {
        case .trigger: return ghTriggerLabelName
        default:       return state.labelName
        }
    }

    /// Inverse of `ghLabelName(for:)`. Use when reading label names out
    /// of GitHub API responses to translate "🍋 Lemon" back to "🍋"
    /// before handing the list to source-agnostic code.
    private static func normalizeIncomingLabel(_ name: String) -> String {
        name == ghTriggerLabelName ? LemonState.trigger.labelName : name
    }

    // Per-repo label bootstrap memo. Once we've ensured one state's label
    // in a repo, we know the repo has been touched.
    private static let bootstrappedRepos = LockedSet()

    // MARK: - Label ensure / mutate

    private func ensureLabel(owner: String, repo: String, state: LemonState, token: String, host: String?) async throws {
        // Always POST; treat 422 (label already exists) as success. The
        // earlier GET-then-POST flow was missing the plain "🍋" trigger
        // label intermittently — GET on a bare-emoji label name doesn't
        // reliably return 200 when the label exists, and a stray 4xx on
        // GET fell through the bootstrap's `try?` and never created it.
        // Just POST and let GitHub return 422 if it's already there;
        // simpler and proven idempotent.
        struct CreateBody: Encodable { let name: String; let color: String; let description: String? }
        let body = try JSONEncoder().encode(CreateBody(
            name: Self.ghLabelName(for: state),
            color: Self.bareHexColor(for: state),
            description: Self.labelDescription(for: state)
        ))
        let createReq = authedRequest(
            "POST",
            path: "/repos/\(owner)/\(repo)/labels",
            token: token,
            host: host,
            body: body
        )
        do {
            _ = try await send(createReq)
        } catch GitHubError.http(let code, _) where code == 422 {
            return
        }
    }

    /// Per-state label description rendered by GitHub on the labels page
    /// and in label tooltips. Tells the user (and any teammates) what
    /// each Lemon label means.
    private static func labelDescription(for state: LemonState) -> String {
        switch state {
        case .trigger:    return "Lemon: add this label to queue an issue for Claude"
        case .inProgress: return "Lemon: Claude is working on this in a worktree"
        case .waiting:    return "Lemon: Claude paused — needs your input"
        case .complete:   return "Lemon: PR open — reply to the Lemon comment to re-trigger"
        }
    }

    // URL-encode a single path segment. Emoji + spaces require encoding.
    private func encodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func addLabel(owner: String, repo: String, number: Int, name: String, token: String, host: String?) async throws {
        struct Body: Encodable { let labels: [String] }
        let body = try JSONEncoder().encode(Body(labels: [name]))
        let req = authedRequest(
            "POST",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/labels",
            token: token,
            host: host,
            body: body
        )
        _ = try await send(req)
    }

    private func removeLabel(owner: String, repo: String, number: Int, name: String, token: String, host: String?) async throws {
        let req = authedRequest(
            "DELETE",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/labels/\(encodePathSegment(name))",
            token: token,
            host: host
        )
        // 404 = already absent → idempotent.
        _ = try await send(req, allow404: true)
    }

    // MARK: - Comments
    //
    // GET sort=created direction=asc matches the chronological invariant
    // LemonMarkerExtractor relies on (and LinearClient also enforces).
    private func fetchCommentsRaw(owner: String, repo: String, number: Int, token: String, host: String?) async throws -> [IssueComment] {
        let req = authedRequest(
            "GET",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
            query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "created"),
                URLQueryItem(name: "direction", value: "asc")
            ],
            token: token,
            host: host
        )
        let (_, data) = try await send(req)
        let dtos = try decode(data, as: [CommentDTO].self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return dtos.compactMap { dto in
            guard let date = iso.date(from: dto.created_at) ?? ISO8601DateFormatter().date(from: dto.created_at) else { return nil }
            return IssueComment(id: String(dto.id), body: dto.body ?? "", createdAt: date)
        }
    }
}

// Tiny thread-safe set used to memoize the per-repo bootstrap status during
// a single Lemon process lifetime.
final class LockedSet: @unchecked Sendable {
    private var storage = Set<String>()
    private let lock = NSLock()

    func insertIfAbsent(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.insert(value).inserted
    }

    func contains(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.contains(value)
    }
}

// MARK: - IssueSourceClient conformance

extension GitHubClient: IssueSourceClient {

    func fetchTriggerQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef] {
        let (token, login, host) = try ghAuth(auth)
        let repos = reposFromConfig(config)
        // Search by the GH-side trigger label ("🍋 Lemon") — GitHub
        // rejects pure-emoji label names, so the trigger label is
        // renamed at the wire. searchIssues already maps inbound
        // labelNames back to the canonical form.
        let allWithTrigger = try await searchIssues(label: Self.ghLabelName(for: .trigger), repos: repos, token: token, login: login, host: host)
        // Exclude issues that already carry any active Lemon state label —
        // mirrors LinearClient.fetchLemonQueue's client-side filter.
        let activeNames = Set(LemonState.active.map(\.labelName))
        return allWithTrigger.filter { Set($0.labelNames).isDisjoint(with: activeNames) }
    }

    func fetchCompleteQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef] {
        let (token, login, host) = try ghAuth(auth)
        let repos = reposFromConfig(config)
        return try await searchIssues(label: Self.ghLabelName(for: .complete), repos: repos, token: token, login: login, host: host)
    }

    func fetchIssueLabels(ref: IssueRef, auth: SourceAuth) async throws -> [String]? {
        let (token, _, host) = try ghAuth(auth)
        let (owner, repo, number) = try ghScope(ref)
        let req = authedRequest(
            "GET",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/labels",
            token: token,
            host: host
        )
        do {
            let (_, data) = try await send(req, allow404: true)
            struct LabelDTO: Decodable { let name: String }
            let labels = try decode(data, as: [LabelDTO].self)
            // Translate GH-side names (e.g. "🍋 Lemon") back to the
            // canonical LemonState.labelName so callers can compare
            // against state.labelName directly.
            return labels.map { Self.normalizeIncomingLabel($0.name) }
        } catch GitHubError.http(let code, _) where code == 404 {
            return nil
        }
    }

    func applyState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws {
        let (token, _, host) = try ghAuth(auth)
        let (owner, repo, number) = try ghScope(ref)
        // Lazy per-repo bootstrap: ensure all four Lemon labels exist before
        // we attempt to attach one. Idempotent + memoized so the first
        // applyState per repo per process does the work. Memo key includes
        // the host so Enterprise and github.com don't share a memo entry.
        let memoKey = "\(host ?? Self.defaultHost):\(owner)/\(repo)"
        if Self.bootstrappedRepos.insertIfAbsent(memoKey) {
            for s in LemonState.allCases {
                do {
                    try await ensureLabel(owner: owner, repo: repo, state: s, token: token, host: host)
                } catch {
                    Logger.orchestrator.error("GH lazy bootstrap \(owner)/\(repo) label '\(s.labelName)' failed: \(error.localizedDescription)")
                }
            }
        }
        try await ensureLabel(owner: owner, repo: repo, state: state, token: token, host: host)
        try await addLabel(owner: owner, repo: repo, number: number, name: Self.ghLabelName(for: state), token: token, host: host)
    }

    func clearState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws {
        let (token, _, host) = try ghAuth(auth)
        let (owner, repo, number) = try ghScope(ref)
        try await removeLabel(owner: owner, repo: repo, number: number, name: Self.ghLabelName(for: state), token: token, host: host)
    }

    @discardableResult
    func postComment(ref: IssueRef, body: String, auth: SourceAuth) async throws -> String {
        let (token, _, host) = try ghAuth(auth)
        let (owner, repo, number) = try ghScope(ref)
        struct Body: Encodable { let body: String }
        let payload = try JSONEncoder().encode(Body(body: body))
        let req = authedRequest(
            "POST",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
            token: token,
            host: host,
            body: payload
        )
        let (_, data) = try await send(req)
        struct Created: Decodable { let id: Int }
        let created = try decode(data, as: Created.self)
        return String(created.id)
    }

    func fetchComments(ref: IssueRef, auth: SourceAuth) async throws -> [IssueComment] {
        let (token, _, host) = try ghAuth(auth)
        let (owner, repo, number) = try ghScope(ref)
        return try await fetchCommentsRaw(owner: owner, repo: repo, number: number, token: token, host: host)
    }

    func hasNewComment(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> Bool {
        let comments = try await fetchComments(ref: ref, auth: auth)
        return LemonMarkerExtractor.hasNewComment(in: comments, afterCommentId: afterCommentId)
    }

    func fetchCommentsAfter(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> [String] {
        let comments = try await fetchComments(ref: ref, auth: auth)
        return LemonMarkerExtractor.bodiesAfter(in: comments, afterCommentId: afterCommentId)
    }

    func findLemonMarker(ref: IssueRef, auth: SourceAuth) async throws -> LemonMarker? {
        let comments = try await fetchComments(ref: ref, auth: auth)
        return LemonMarkerExtractor.findLatest(in: comments)
    }

    func bootstrapLabels(config: SourceConfig, auth: SourceAuth) async throws {
        let (token, _, host) = try ghAuth(auth)
        for repoFullName in reposFromConfig(config) {
            let parts = repoFullName.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let owner = String(parts[0]); let repo = String(parts[1])
            // Per-label failures are logged but don't abort — the other
            // three still need to land. Without explicit logging, the
            // earlier silent swallow hid the trigger-label miss for a
            // long time.
            for state in LemonState.allCases {
                do {
                    try await ensureLabel(owner: owner, repo: repo, state: state, token: token, host: host)
                } catch {
                    Logger.orchestrator.error("GH bootstrap \(owner)/\(repo) label '\(state.labelName)' failed: \(error.localizedDescription)")
                }
            }
            _ = Self.bootstrappedRepos.insertIfAbsent("\(host ?? Self.defaultHost):\(owner)/\(repo)")
        }
    }

    func verifyCredential(token: String, host: String?) async throws -> CredentialIdentity {
        let req = authedRequest("GET", path: "/user", token: token, host: host)
        let (_, data) = try await send(req)
        let user = try decode(data, as: UserDTO.self)
        return CredentialIdentity(
            id: String(user.id),
            displayName: user.name ?? user.login,
            handle: user.login,          // GitHub login, used as the assignee filter
            avatarUrl: user.avatar_url
        )
    }

    /// Count of open issues currently assigned to the user. Uses the search
    /// API's `total_count` so we get a real number without paginating.
    func countAssignedOpenIssues(token: String, host: String?, principalId: String) async throws -> Int {
        // principalId here is the user's `login` (handle) — GitHub's search
        // syntax wants `assignee:LOGIN`, not the numeric id.
        let query = "assignee:\(principalId) is:issue is:open"
        let req = authedRequest(
            "GET",
            path: "/search/issues",
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: "1"),
            ],
            token: token,
            host: host
        )
        let (_, data) = try await send(req)
        struct CountDTO: Decodable { let total_count: Int }
        let parsed = try decode(data, as: CountDTO.self)
        return parsed.total_count
    }

    /// Fetch the authenticated user's repositories (public + private the PAT
    /// can see). Returns up to 100 entries sorted by recent push activity;
    /// pagination deferred until anyone runs out of space.
    func listSurfaces(token: String, host: String?) async throws -> [Surface] {
        let req = authedRequest(
            "GET",
            path: "/user/repos",
            query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "pushed"),
            ],
            token: token,
            host: host
        )
        let (_, data) = try await send(req)
        struct RepoDTO: Decodable { let full_name: String; let name: String }
        let repos = try decode(data, as: [RepoDTO].self)
        return repos.map { Surface(id: $0.full_name, key: $0.full_name, displayName: $0.name) }
    }
}
