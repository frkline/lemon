import Foundation

/// Shared surface used by Orchestrator and WorktreeRunner. Each per-source
/// client (LinearClient, GitHubClient) conforms; downstream code never touches
/// source-specific types.
///
/// Auth and per-source filter scope flow through call sites rather than living
/// on the client instance — this matches the existing LinearClient shape and
/// avoids forcing one client instance per (credential, scope) tuple.
protocol IssueSourceClient: Sendable {
    func fetchTriggerQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef]
    func fetchCompleteQueue(config: SourceConfig, auth: SourceAuth) async throws -> [IssueRef]

    /// Current label-name list for one issue, or nil if the issue is unreachable.
    /// Used during pollUntilDone to track in-progress / waiting / complete
    /// transitions after the trigger label has already been removed.
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

    /// Login of whoever most recently applied the 🍋 trigger label (the labeler,
    /// not necessarily the opener) — the trust anchor for lockdown (#13 M2).
    /// nil = undeterminable; callers fall back to the issue author. A protocol
    /// requirement (not just an extension default) so `any IssueSourceClient`
    /// dynamically dispatches to each client's real implementation.
    func triggerLabelActor(ref: IssueRef, auth: SourceAuth) async throws -> String?

    /// Per-source label bootstrap. Linear: ensure labels in each configured
    /// team. GitHub: ensure labels in each configured repo (lazy is fine too).
    func bootstrapLabels(config: SourceConfig, auth: SourceAuth) async throws

    /// Used by the onboarding "Verify" buttons + Settings connection state.
    /// Takes a raw token because the user id / login isn't known yet at
    /// verification time — verifyCredential populates it. Optional `host`
    /// for GitHub Enterprise; Linear ignores it.
    func verifyCredential(token: String, host: String?) async throws -> CredentialIdentity

    /// Discover the surfaces this credential can reach. Linear: every team
    /// the API key has access to. GitHub: every repo (public + private) the
    /// PAT can see. Results populate `Identity.knownSurfaces` so the editor's
    /// routing dropdowns are pre-filled from real data rather than free text.
    func listSurfaces(token: String, host: String?) async throws -> [Surface]

    /// Count of issues currently assigned to the principal (open, not closed
    /// / cancelled / completed). Surfaced after verify as user-meaningful
    /// proof that the credential reaches actual work — replaces the
    /// abstract "surfaces" count in the UI.
    func countAssignedOpenIssues(token: String, host: String?, principalId: String) async throws -> Int

    /// True if the issue is closed/completed/cancelled on the source. Secondary
    /// auto-retire trigger for a `.reviewing` session (#54) — the primary is a
    /// merged PR (`WorktreeRunner.isPRMerged`). Default false (sources opt in)
    /// so a source that can't cheaply answer simply leans on the PR signal.
    func isIssueClosed(ref: IssueRef, auth: SourceAuth) async throws -> Bool
}

extension IssueSourceClient {
    /// Back-compat shim — most callers don't need a host.
    func verifyCredential(token: String) async throws -> CredentialIdentity {
        try await verifyCredential(token: token, host: nil)
    }

    /// Login of whoever most recently applied the 🍋 trigger label — the labeler,
    /// not necessarily the issue opener. The precise trust anchor for lockdown
    /// (#13 M2): you can authorize an outsider's issue by labeling it yourself,
    /// and an outsider labeling your issue is caught. nil = undeterminable;
    /// callers fall back to the issue author. Default nil (sources opt in).
    func triggerLabelActor(ref _: IssueRef, auth _: SourceAuth) async throws -> String? {
        nil
    }

    /// Default: undeterminable → false, so auto-retire (#54) leans on the merged-PR
    /// signal. GitHub overrides this with a cheap issue-state GET.
    func isIssueClosed(ref _: IssueRef, auth _: SourceAuth) async throws -> Bool {
        false
    }
}

/// Per-source credential.
///
/// GitHub carries an optional `host` for Enterprise installations. Nil or
/// "api.github.com" routes to public github.com; an Enterprise host looks
/// like "api.github.acmecorp.com". The client uses it as the API base.
enum SourceAuth: Hashable {
    case linear(apiKey: String, userId: String)
    case github(pat: String, login: String, host: String? = nil)

    var source: IssueSource {
        switch self {
        case .linear: .linear
        case .github: .github
        }
    }
}

/// Returned from verifyCredential. Powers the "Connected as X" affordance in
/// onboarding + the Settings connection badge.
struct CredentialIdentity: Equatable {
    let id: String // principal id (Linear node id, GitHub numeric id)
    let displayName: String // user-facing name ("Frank Kline III")
    let handle: String // login / username — Linear's name, GitHub's login
    let avatarUrl: String?
}

/// Errors raised when a client receives an auth value of the wrong source.
/// Should only fire on bugs (Orchestrator wiring the wrong client to a pair).
enum IssueSourceError: Error, LocalizedError {
    case authMismatch(expected: IssueSource, got: IssueSource)

    var errorDescription: String? {
        switch self {
        case let .authMismatch(expected, got):
            "Source mismatch: expected \(expected.displayName) auth, got \(got.displayName)"
        }
    }
}
