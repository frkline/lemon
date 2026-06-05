import Foundation
import os

// GraphQL client for the Linear API.
// Polls for 🍋-labeled issues and manages Lemon status labels.
final class LinearClient: Sendable {
    private let endpoint = URL(string: "https://api.linear.app/graphql")!
    private let session: URLSession

    static let labelTrigger    = "🍋"
    static let labelInProgress = "🍋 In Progress"
    static let labelWaiting    = "🍋 Waiting"
    static let labelComplete   = "🍋 Complete"

    private let activeLabels: Set<String> = [
        labelInProgress, labelWaiting, labelComplete
    ]

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Viewer (auth verification + identity)

    struct Viewer {
        let id: String
        let name: String
        let email: String
        let avatarUrl: String?
    }

    func fetchViewer(apiKey: String) async throws -> Viewer {
        let query = "query { viewer { id name email avatarUrl } }"
        let json = try await graphql(query: query, variables: [:], apiKey: apiKey)
        guard
            let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any],
            let id   = viewer["id"]   as? String,
            let name = viewer["name"] as? String,
            let email = viewer["email"] as? String
        else { throw LinearError.unexpectedShape }
        return Viewer(id: id, name: name, email: email, avatarUrl: viewer["avatarUrl"] as? String)
    }

    // MARK: - Issue queues

    // Issues with 🍋 label but none of the active labels — new work to pick up.
    // Includes both issues assigned to the user AND unassigned issues, since solo
    // developers commonly don't self-assign. Workspace prefix → repo mapping in the
    // Orchestrator still scopes the issues that can actually be acted on.
    func fetchLemonQueue(apiKey: String, userId: String) async throws -> [LinearIssue] {
        let query = """
        query LemonQueue($label: String!, $activeStates: [String!]!, $userId: ID!) {
          issues(
            filter: {
              labels: { name: { eq: $label } }
              state: { type: { nin: $activeStates } }
              or: [
                { assignee: { id: { eq: $userId } } }
                { assignee: { null: true } }
              ]
            }
            first: 25
          ) {
            nodes {
              id identifier title description
              labels { nodes { name } }
              team { id }
              state { type }
            }
          }
        }
        """
        let variables: [String: Any] = [
            "label": Self.labelTrigger,
            "activeStates": ["completed", "cancelled"],
            "userId": userId
        ]
        let json = try await graphql(query: query, variables: variables, apiKey: apiKey)
        let nodes = issueNodes(from: json, key: "issues")
        return nodes.compactMap { parseIssue($0) }.filter { issue in
            Set(issue.labelNames).isDisjoint(with: activeLabels)
        }
    }

    // Issues with 🍋 Complete label that are still open. Same assignee semantics
    // as fetchLemonQueue: assigned to the user OR unassigned.
    func fetchCompleteIssues(apiKey: String, userId: String) async throws -> [LinearIssue] {
        let query = """
        query LemonComplete($label: String!, $activeStates: [String!]!, $userId: ID!) {
          issues(
            filter: {
              labels: { name: { eq: $label } }
              state: { type: { nin: $activeStates } }
              or: [
                { assignee: { id: { eq: $userId } } }
                { assignee: { null: true } }
              ]
            }
            first: 25
          ) {
            nodes {
              id identifier title description
              labels { nodes { name } }
              team { id }
              state { type }
            }
          }
        }
        """
        let variables: [String: Any] = [
            "label": Self.labelComplete,
            "activeStates": ["completed", "cancelled"],
            "userId": userId
        ]
        let json = try await graphql(query: query, variables: variables, apiKey: apiKey)
        return issueNodes(from: json, key: "issues").compactMap { parseIssue($0) }
    }

    // Returns the current label names for one issue, or nil if the issue is
    // unreachable. Used by WorktreeRunner.pollUntilDone to track waiting /
    // in-progress transitions during an active session, where the trigger
    // label has already been removed (so fetchLemonQueue can't see the issue).
    func fetchIssueLabels(issueId: String, apiKey: String) async throws -> [String]? {
        let query = """
        query IssueLabels($id: String!) {
          issue(id: $id) {
            labels { nodes { name } }
          }
        }
        """
        let json = try await graphql(query: query, variables: ["id": issueId], apiKey: apiKey)
        guard let issue = (json["data"] as? [String: Any])?["issue"] as? [String: Any],
              let labels = (issue["labels"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { return nil }
        return labels.compactMap { $0["name"] as? String }
    }

    // MARK: - Comments

    func fetchComments(issueId: String, apiKey: String) async throws -> [IssueComment] {
        // Use `first: 25, orderBy: createdAt` — Linear returns nodes newest-first
        // by default. The previous query used `last: 25` which is valid Linear
        // syntax but the resulting JSON parse-chain in this method was broken
        // (Optional<Any>.flatMap path), silently returning zero comments and
        // breaking the entire re-trigger flow. Direct + obvious is better here.
        let query = """
        query IssueComments($id: String!) {
          issue(id: $id) {
            comments(first: 25, orderBy: createdAt) {
              nodes { id body createdAt }
            }
          }
        }
        """
        let json = try await graphql(query: query, variables: ["id": issueId], apiKey: apiKey)
        guard
            let data     = json["data"] as? [String: Any],
            let issue    = data["issue"] as? [String: Any],
            let comments = issue["comments"] as? [String: Any],
            let nodes    = comments["nodes"] as? [[String: Any]]
        else {
            return []
        }

        let iso = ISO8601DateFormatter()
        // Fractional seconds in Linear timestamps (e.g. "...537Z") — the default
        // ISO8601 formatter rejects them. Opt in so we don't silently drop comments.
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = nodes.compactMap { node -> IssueComment? in
            guard
                let id   = node["id"]   as? String,
                let body = node["body"] as? String,
                let ts   = node["createdAt"] as? String,
                let date = iso.date(from: ts)
            else { return nil }
            return IssueComment(id: id, body: body, createdAt: date)
        }
        // Normalize to chronological order (oldest first). Linear returns
        // newest-first by default — every downstream consumer
        // (LemonMarkerExtractor walks reversed; hasNewComment / bodiesAfter
        // compare indices) breaks subtly if the input order shifts. Sorting
        // here once means the re-trigger pipeline reasons about time, not API quirks.
        return parsed.sorted { $0.createdAt < $1.createdAt }
    }

    // Re-trigger detection helpers — thin wrappers over LemonMarkerExtractor
    // so LinearClient and GitHubClient share one parser.
    func hasNewComment(issueId: String, afterCommentId: String, apiKey: String) async throws -> Bool {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        return LemonMarkerExtractor.hasNewComment(in: comments, afterCommentId: afterCommentId)
    }

    func fetchCommentsAfter(issueId: String, afterCommentId: String, apiKey: String) async throws -> [String] {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        return LemonMarkerExtractor.bodiesAfter(in: comments, afterCommentId: afterCommentId)
    }

    func findLemonMarker(issueId: String, apiKey: String) async throws -> LemonMarker? {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        return LemonMarkerExtractor.findLatest(in: comments)
    }

    // MARK: - Mutations: post comment

    @discardableResult
    func postComment(issueId: String, body: String, apiKey: String) async throws -> String {
        let mutation = """
        mutation CreateComment($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) {
            comment { id }
          }
        }
        """
        let json = try await graphql(
            query: mutation,
            variables: ["issueId": issueId, "body": body],
            apiKey: apiKey
        )
        guard let commentId = ((json["data"] as? [String: Any])?["commentCreate"] as? [String: Any])?["comment"].flatMap({ ($0 as? [String: Any])?["id"] as? String })
        else { throw LinearError.unexpectedShape }
        return commentId
    }

    // MARK: - Mutations: labels

    // Colors for auto-created Lemon labels.
    static let labelColors: [String: String] = [
        labelTrigger:    "#F7C842",  // lemon yellow
        labelInProgress: "#F7C842",  // lemon yellow
        labelWaiting:    "#FF6B46",  // coral
        labelComplete:   "#4EC97B",  // green
    ]

    // Returns the label ID, creating the label first if it doesn't exist.
    func ensureLabelId(name: String, teamId: String, apiKey: String) async throws -> String {
        if let existing = try await fetchLabelId(name: name, teamId: teamId, apiKey: apiKey) {
            return existing
        }
        return try await createLabel(name: name, teamId: teamId, apiKey: apiKey)
    }

    func createLabel(name: String, teamId: String, apiKey: String) async throws -> String {
        let color = Self.labelColors[name] ?? "#F7C842"
        let mutation = """
        mutation CreateLabel($teamId: String!, $name: String!, $color: String!) {
          issueLabelCreate(input: { teamId: $teamId, name: $name, color: $color }) {
            issueLabel { id }
          }
        }
        """
        let json = try await graphql(
            query: mutation,
            variables: ["teamId": teamId, "name": name, "color": color],
            apiKey: apiKey
        )
        guard let id = ((json["data"] as? [String: Any])?["issueLabelCreate"] as? [String: Any])?["issueLabel"].flatMap({ ($0 as? [String: Any])?["id"] as? String })
        else { throw LinearError.unexpectedShape }
        return id
    }

    func fetchLabelId(name: String, teamId: String, apiKey: String) async throws -> String? {
        let query = """
        query Labels($teamId: String!) {
          team(id: $teamId) {
            labels(filter: { name: { eq: "\(name)" } }, first: 1) {
              nodes { id name }
            }
          }
        }
        """
        let json = try await graphql(query: query, variables: ["teamId": teamId], apiKey: apiKey)
        return (((json["data"] as? [String: Any])?["team"] as? [String: Any])?["labels"] as? [String: Any])?["nodes"].flatMap { ($0 as? [[String: Any]])?.first?["id"] as? String }
    }

    func addLabel(issueId: String, labelId: String, apiKey: String) async throws {
        let mutation = """
        mutation AddLabel($issueId: String!, $labelId: String!) {
          issueAddLabel(id: $issueId, labelId: $labelId) { success }
        }
        """
        try await graphql(query: mutation, variables: ["issueId": issueId, "labelId": labelId], apiKey: apiKey)
    }

    func removeLabel(issueId: String, labelId: String, apiKey: String) async throws {
        let mutation = """
        mutation RemoveLabel($issueId: String!, $labelId: String!) {
          issueRemoveLabel(id: $issueId, labelId: $labelId) { success }
        }
        """
        try await graphql(query: mutation, variables: ["issueId": issueId, "labelId": labelId], apiKey: apiKey)
    }

    // MARK: - Teams

    struct LinearTeam: Identifiable {
        let id: String
        let name: String
        let key: String   // issue identifier prefix, e.g. "HRP"
    }

    func fetchTeams(apiKey: String) async throws -> [LinearTeam] {
        let query = """
        query {
          teams(first: 50) {
            nodes { id name key }
          }
        }
        """
        let json = try await graphql(query: query, variables: [:], apiKey: apiKey)
        let nodes = (json["data"] as? [String: Any])?["teams"].flatMap {
            ($0 as? [String: Any])?["nodes"] as? [[String: Any]]
        } ?? []
        return nodes.compactMap { node -> LinearTeam? in
            guard
                let id   = node["id"]   as? String,
                let name = node["name"] as? String,
                let key  = node["key"]  as? String
            else { return nil }
            return LinearTeam(id: id, name: name, key: key)
        }
    }

    // MARK: - Private helpers

    @discardableResult
    private func graphql(query: String, variables: [String: Any], apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        Logger.linear.debug("HTTP \(statusCode) — \(body.prefix(500))")

        guard statusCode == 200 else {
            Logger.linear.error("HTTP error \(statusCode): \(body.prefix(200))")
            throw LinearError.http(statusCode, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinearError.unexpectedShape
        }
        // Surface GraphQL-level errors (Linear returns 200 with {"errors":[...]}).
        if let errors = json["errors"] as? [[String: Any]],
           let first = errors.first {
            let message = first["message"] as? String ?? "unknown error"
            let code = (first["extensions"] as? [String: Any])?["code"] as? String
            Logger.linear.error("GraphQL error (\(code ?? "?")): \(message)")
            if code == "RATELIMITED" { throw LinearError.rateLimited }
            throw LinearError.graphql(message)
        }
        return json
    }

    private func issueNodes(from json: [String: Any], key: String) -> [[String: Any]] {
        (json["data"] as? [String: Any])?[key].flatMap {
            ($0 as? [String: Any])?["nodes"] as? [[String: Any]]
        } ?? []
    }

    private func parseIssue(_ node: [String: Any]) -> LinearIssue? {
        guard
            let id         = node["id"]         as? String,
            let identifier = node["identifier"] as? String,
            let title      = node["title"]      as? String,
            let teamId     = (node["team"] as? [String: Any])?["id"] as? String
        else { return nil }
        let labelNames = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        return LinearIssue(
            id: id,
            identifier: identifier,
            title: title,
            description: node["description"] as? String,
            labelNames: labelNames,
            teamId: teamId
        )
    }

    enum LinearError: LocalizedError {
        case http(Int, String)
        case graphql(String)
        case rateLimited
        case unexpectedShape

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .graphql(let msg):         return "Linear: \(msg)"
            case .rateLimited:              return "Linear rate limit hit (2,500 req/hr). Slow down polling."
            case .unexpectedShape:          return "Unexpected response shape"
            }
        }
    }
}

// MARK: - IssueSourceClient conformance

extension LinearClient: IssueSourceClient {

    private func linearAuth(_ auth: SourceAuth) throws -> (apiKey: String, userId: String) {
        guard case .linear(let apiKey, let userId) = auth else {
            throw IssueSourceError.authMismatch(expected: .linear, got: auth.source)
        }
        return (apiKey, userId)
    }

    private func linearScope(_ ref: IssueRef) throws -> String {
        guard case .linearTeam(let teamId) = ref.scope else {
            throw IssueSourceError.authMismatch(expected: .linear, got: ref.source)
        }
        return teamId
    }

    func fetchTriggerQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef] {
        let (apiKey, userId) = try linearAuth(auth)
        let issues = try await fetchLemonQueue(apiKey: apiKey, userId: userId)
        // Linear team allowlist is by team key (e.g. "HRP"); filter post-fetch
        // since Linear's filter API takes IDs, and we surface keys in onboarding.
        if let allow = config.linearTeamKeys, !allow.isEmpty {
            let lowered = Set(allow.map { $0.lowercased() })
            return issues
                .filter { lowered.contains($0.identifierPrefix.lowercased()) }
                .map { IssueRef(linearIssue: $0) }
        }
        return issues.map { IssueRef(linearIssue: $0) }
    }

    func fetchCompleteQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef] {
        let (apiKey, userId) = try linearAuth(auth)
        let issues = try await fetchCompleteIssues(apiKey: apiKey, userId: userId)
        if let allow = config.linearTeamKeys, !allow.isEmpty {
            let lowered = Set(allow.map { $0.lowercased() })
            return issues
                .filter { lowered.contains($0.identifierPrefix.lowercased()) }
                .map { IssueRef(linearIssue: $0) }
        }
        return issues.map { IssueRef(linearIssue: $0) }
    }

    func fetchIssueLabels(ref: IssueRef, auth: SourceAuth) async throws -> [String]? {
        let (apiKey, _) = try linearAuth(auth)
        return try await fetchIssueLabels(issueId: ref.id, apiKey: apiKey)
    }

    func applyState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws {
        let (apiKey, _) = try linearAuth(auth)
        let teamId = try linearScope(ref)
        let labelId = try await ensureLabelId(name: state.labelName, teamId: teamId, apiKey: apiKey)
        try await addLabel(issueId: ref.id, labelId: labelId, apiKey: apiKey)
    }

    func clearState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws {
        let (apiKey, _) = try linearAuth(auth)
        let teamId = try linearScope(ref)
        let labelId = try await ensureLabelId(name: state.labelName, teamId: teamId, apiKey: apiKey)
        try await removeLabel(issueId: ref.id, labelId: labelId, apiKey: apiKey)
    }

    @discardableResult
    func postComment(ref: IssueRef, body: String, auth: SourceAuth) async throws -> String {
        let (apiKey, _) = try linearAuth(auth)
        return try await postComment(issueId: ref.id, body: body, apiKey: apiKey)
    }

    func fetchComments(ref: IssueRef, auth: SourceAuth) async throws -> [IssueComment] {
        let (apiKey, _) = try linearAuth(auth)
        return try await fetchComments(issueId: ref.id, apiKey: apiKey)
    }

    func hasNewComment(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> Bool {
        let (apiKey, _) = try linearAuth(auth)
        return try await hasNewComment(issueId: ref.id, afterCommentId: afterCommentId, apiKey: apiKey)
    }

    func fetchCommentsAfter(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> [String] {
        let (apiKey, _) = try linearAuth(auth)
        return try await fetchCommentsAfter(issueId: ref.id, afterCommentId: afterCommentId, apiKey: apiKey)
    }

    func findLemonMarker(ref: IssueRef, auth: SourceAuth) async throws -> LemonMarker? {
        let (apiKey, _) = try linearAuth(auth)
        return try await findLemonMarker(issueId: ref.id, apiKey: apiKey)
    }

    func bootstrapLabels(config: SourceConfig, auth: SourceAuth) async throws {
        let (apiKey, _) = try linearAuth(auth)
        let teams = try await fetchTeams(apiKey: apiKey)
        let allow = config.linearTeamKeys.map { Set($0.map { $0.lowercased() }) }
        for team in teams {
            if let allow, !allow.contains(team.key.lowercased()) { continue }
            for state in LemonState.allCases {
                _ = try? await ensureLabelId(name: state.labelName, teamId: team.id, apiKey: apiKey)
            }
        }
    }

    func verifyCredential(token: String, host: String?) async throws -> CredentialIdentity {
        // Linear ignores host — its API is single-tenant.
        _ = host
        let viewer = try await fetchViewer(apiKey: token)
        return CredentialIdentity(
            id: viewer.id,
            displayName: viewer.name,
            handle: viewer.name,
            avatarUrl: viewer.avatarUrl
        )
    }

    /// Discover every team this API key can see. Maps to `Surface` so the
    /// editor's routing dropdowns can render `[Harpy Rocks (HRP)]` instead
    /// of asking the user to type the prefix.
    func listSurfaces(token: String, host: String?) async throws -> [Surface] {
        _ = host
        let teams = try await fetchTeams(apiKey: token)
        return teams.map { Surface(id: $0.key, key: $0.key, displayName: $0.name) }
    }

    /// Count of open issues currently assigned to the user. Replaces the
    /// abstract "surfaces" count after verify — gives the user a concrete
    /// sense of what Lemon will be polling on their behalf.
    func countAssignedOpenIssues(token: String, host: String?, principalId: String) async throws -> Int {
        _ = host
        let query = """
        query AssignedCount($userId: ID!, $closed: [String!]!) {
          issues(
            filter: {
              assignee: { id: { eq: $userId } }
              state: { type: { nin: $closed } }
            }
            first: 1
          ) { nodes { id } pageInfo { hasNextPage } }
        }
        """
        // Linear doesn't expose a totalCount on the filter; we ask for one node
        // and then page through if hasNextPage is true. For the editor chip a
        // bounded count (capped at, say, 200) is plenty.
        var cursor: String? = nil
        var total = 0
        let cap = 200
        repeat {
            let pagedQuery = """
            query AssignedCount($userId: ID!, $closed: [String!]!, $after: String) {
              issues(
                filter: {
                  assignee: { id: { eq: $userId } }
                  state: { type: { nin: $closed } }
                }
                first: 50
                after: $after
              ) { nodes { id } pageInfo { hasNextPage endCursor } }
            }
            """
            var vars: [String: Any] = ["userId": principalId, "closed": ["completed", "cancelled"]]
            if let cursor { vars["after"] = cursor }
            let json = try await graphql(query: pagedQuery, variables: vars, apiKey: token)
            let issues = (json["data"] as? [String: Any])?["issues"] as? [String: Any]
            let nodes = (issues?["nodes"] as? [[String: Any]]) ?? []
            total += nodes.count
            let pageInfo = issues?["pageInfo"] as? [String: Any]
            let hasNext = (pageInfo?["hasNextPage"] as? Bool) ?? false
            cursor = hasNext ? (pageInfo?["endCursor"] as? String) : nil
            if total >= cap { return cap }
        } while cursor != nil
        _ = query
        return total
    }
}
