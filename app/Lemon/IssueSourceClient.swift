import Foundation

// Shared surface used by Orchestrator and WorktreeRunner. Each per-source
// client (LinearClient, GitHubClient) conforms; downstream code never touches
// source-specific types.
//
// Auth and per-source filter scope flow through call sites rather than living
// on the client instance — this matches the existing LinearClient shape and
// avoids forcing one client instance per (credential, scope) tuple.
protocol IssueSourceClient: Sendable {

    func fetchTriggerQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef]
    func fetchCompleteQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef]

    // Current label-name list for one issue, or nil if the issue is unreachable.
    // Used during pollUntilDone to track in-progress / waiting / complete
    // transitions after the trigger label has already been removed.
    func fetchIssueLabels(ref: IssueRef, auth: SourceAuth) async throws -> [String]?

    // Add/remove one Lemon state label on an issue. The client maps `state`
    // to its source-specific representation (Linear label ID, GitHub label name).
    func applyState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws
    func clearState(ref: IssueRef, state: LemonState, auth: SourceAuth) async throws

    @discardableResult
    func postComment(ref: IssueRef, body: String, auth: SourceAuth) async throws -> String

    func fetchComments(ref: IssueRef, auth: SourceAuth) async throws -> [IssueComment]
    func hasNewComment(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> Bool
    func fetchCommentsAfter(ref: IssueRef, afterCommentId: String, auth: SourceAuth) async throws -> [String]
    func findLemonMarker(ref: IssueRef, auth: SourceAuth) async throws -> LemonMarker?

    // Per-source label bootstrap. Linear: ensure labels in each configured
    // team. GitHub: ensure labels in each configured repo (lazy is fine too).
    func bootstrapLabels(config: SourceConfig, auth: SourceAuth) async throws

    // Used by the onboarding "Verify" buttons + Settings connection state.
    // Takes a raw token because the user id / login isn't known yet at
    // verification time — verifyCredential populates it. Optional `host`
    // for GitHub Enterprise; Linear ignores it.
    func verifyCredential(token: String, host: String?) async throws -> CredentialIdentity
}

extension IssueSourceClient {
    /// Back-compat shim — most callers don't need a host.
    func verifyCredential(token: String) async throws -> CredentialIdentity {
        try await verifyCredential(token: token, host: nil)
    }
}

// Per-source credential.
//
// GitHub carries an optional `host` for Enterprise installations. Nil or
// "api.github.com" routes to public github.com; an Enterprise host looks
// like "api.github.acmecorp.com". The client uses it as the API base.
enum SourceAuth: Sendable, Hashable {
    case linear(apiKey: String, userId: String)
    case github(pat: String, login: String, host: String? = nil)

    var source: IssueSource {
        switch self {
        case .linear: return .linear
        case .github: return .github
        }
    }
}

// Returned from verifyCredential. Powers the "Connected as X" affordance in
// onboarding + the Settings connection badge.
struct CredentialIdentity: Equatable {
    let id: String
    let displayName: String
    let avatarUrl: String?
}

// Errors raised when a client receives an auth value of the wrong source.
// Should only fire on bugs (Orchestrator wiring the wrong client to a pair).
enum IssueSourceError: Error, LocalizedError {
    case authMismatch(expected: IssueSource, got: IssueSource)

    var errorDescription: String? {
        switch self {
        case .authMismatch(let expected, let got):
            return "Source mismatch: expected \(expected.displayName) auth, got \(got.displayName)"
        }
    }
}
