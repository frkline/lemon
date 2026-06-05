import Foundation

// Source-agnostic helpers for the Lemon HTML marker block embedded in issue
// comments. Both LinearClient and GitHubClient pass their normalized
// [IssueComment] list through these functions instead of duplicating the
// parser per source.
//
// Marker shape (kept identical across sources):
//
//   <!-- lemon
//   branch: lemon/HRP-42
//   pr: 101
//   repo: /Users/frank/Projects/myapp
//   source: github       <-- optional, missing = .linear (pre-upgrade comments)
//   comment: <optional explicit id, falls back to host comment>
//   -->
enum LemonMarkerExtractor {

    // Parse a single comment body. Public so tests can target it directly.
    static func parse(body: String, commentId: String) -> LemonMarker? {
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
            let branch = fields["branch"],
            let pr     = fields["pr"],
            let repo   = fields["repo"]
        else { return nil }

        let storedCommentId = fields["comment"] ?? commentId
        let source = fields["source"].flatMap(IssueSource.init(rawValue:))
        return LemonMarker(
            branch: branch,
            prNumber: pr,
            commentId: storedCommentId,
            repoPath: repo,
            source: source
        )
    }

    // Latest marker in a comment list. Walks newest → oldest because a fresh
    // Lemon Report supersedes earlier ones.
    static func findLatest(in comments: [IssueComment]) -> LemonMarker? {
        for comment in comments.reversed() {
            if let marker = parse(body: comment.body, commentId: comment.id) {
                return marker
            }
        }
        return nil
    }

    // True if any comment was created after the given comment ID. Comments
    // are expected chronological (oldest → newest); see LinearClient.fetchComments
    // and the equivalent GitHubClient invariant.
    static func hasNewComment(in comments: [IssueComment], afterCommentId: String) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == afterCommentId }) else {
            return false
        }
        return idx < comments.count - 1
    }

    // Bodies of all comments strictly after the given comment ID.
    static func bodiesAfter(in comments: [IssueComment], afterCommentId: String) -> [String] {
        guard let idx = comments.firstIndex(where: { $0.id == afterCommentId }) else {
            return []
        }
        return comments.suffix(from: comments.index(after: idx)).map { $0.body }
    }
}
