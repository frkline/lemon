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

    struct Comment {
        let id: String
        let body: String
        let createdAt: Date
    }

    func fetchComments(issueId: String, apiKey: String) async throws -> [Comment] {
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
        let parsed = nodes.compactMap { node -> Comment? in
            guard
                let id   = node["id"]   as? String,
                let body = node["body"] as? String,
                let ts   = node["createdAt"] as? String,
                let date = iso.date(from: ts)
            else { return nil }
            return Comment(id: id, body: body, createdAt: date)
        }
        // Normalize to chronological order (oldest first). Linear returns
        // newest-first by default — every downstream consumer (findLemonMarker
        // iterates reversed; hasNewComment / fetchCommentsAfter compare indices)
        // breaks subtly if the input order shifts. Sorting here once means the
        // re-trigger pipeline reasons about time, not API quirks.
        return parsed.sorted { $0.createdAt < $1.createdAt }
    }

    // Returns true if there is any comment on the issue that was created
    // after the comment with the given ID (exclusive).
    func hasNewComment(issueId: String, afterCommentId: String, apiKey: String) async throws -> Bool {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        guard let idx = comments.firstIndex(where: { $0.id == afterCommentId }) else {
            return false
        }
        return idx < comments.count - 1
    }

    // Returns the bodies of all comments posted after the given comment ID
    // (exclusive). Used on re-trigger to surface human revision requests into
    // LEMON_CONTEXT.md — without this, Claude reads only the original issue
    // body on a re-run and concludes the task is already done.
    func fetchCommentsAfter(issueId: String, afterCommentId: String, apiKey: String) async throws -> [String] {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        guard let idx = comments.firstIndex(where: { $0.id == afterCommentId }) else {
            return []
        }
        let after = comments.suffix(from: comments.index(after: idx))
        return after.map { $0.body }
    }

    // Finds the Lemon HTML marker in the issue's comments and parses it.
    func findLemonMarker(issueId: String, apiKey: String) async throws -> LemonMarker? {
        let comments = try await fetchComments(issueId: issueId, apiKey: apiKey)
        for comment in comments.reversed() {
            if let marker = parseLemonMarker(from: comment.body, commentId: comment.id) {
                return marker
            }
        }
        return nil
    }

    // Exposed for tests; treat as private otherwise.
    func parseLemonMarker(from body: String, commentId: String) -> LemonMarker? {
        guard
            let start = body.range(of: "<!-- lemon\n"),
            let end   = body.range(of: "\n-->", range: start.upperBound..<body.endIndex)
        else { return nil }

        let block = String(body[start.upperBound..<end.lowerBound])
        var fields: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }

        guard
            let branch   = fields["branch"],
            let pr       = fields["pr"],
            let repo     = fields["repo"]
        else { return nil }

        let storedCommentId = fields["comment"] ?? commentId
        return LemonMarker(branch: branch, prNumber: pr, commentId: storedCommentId, repoPath: repo)
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
