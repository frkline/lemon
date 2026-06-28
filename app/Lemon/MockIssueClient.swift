import Foundation

// File-backed IssueSourceClient for the sandbox iteration loop (LEMON_SANDBOX=1).
//
// Reads and writes issues as JSON fixtures under SandboxFixtures.issuesDir, so the
// full Orchestrator → WorktreeRunner loop runs with zero GitHub/Linear traffic and
// no public side effects. Triggering a test issue = dropping a fixture with the 🍋
// label; label flips and Lemon's comments write back to the fixture files, which the
// scenario runner inspects to assert behavior.
//
// See WORKFLOW_DESIGN.md and memory/sandbox-iteration-loop.md.

/// Seeded config the sandbox injects so the existing poll loop runs unmodified:
/// one GitHub-kind identity routed to a single `sandbox/demo` surface, backed by a
/// throwaway git repo at `workspacePath`.
enum SandboxFixtures {
    static let root = "/tmp/lemon-sandbox"
    static let issuesDir = "\(root)/issues"
    static let workspacePath = "\(root)/workspace"

    static let identityId = UUID(uuidString: "5A0DB0C5-0000-4000-A000-000000000001")!
    static let workspaceId = UUID(uuidString: "5A0DB0C5-0000-4000-A000-000000000002")!
    static let surfaceId = "sandbox/demo"

    static var surface: Surface {
        Surface(id: surfaceId, key: surfaceId, displayName: surfaceId)
    }

    static var identity: Identity {
        Identity(
            id: identityId,
            kind: .github,
            label: "Sandbox · @sandbox",
            handle: "sandbox",
            principalId: "sandbox",
            host: nil,
            knownSurfaces: [surface],
            surfacesFetchedAt: nil,
        )
    }

    static var workspace: Workspace {
        Workspace(
            id: workspaceId,
            path: workspacePath,
            allReposInFolder: false,
            homeRepo: "",
            routing: Routing(identityId: identityId, surfaceId: surfaceId),
        )
    }

    static var auth: SourceAuth {
        .github(pat: "sandbox", login: "sandbox", host: nil)
    }
}

/// On-disk fixture shape. One file per issue at `{issuesDir}/{number}.json`.
private struct SandboxIssueFixture: Codable {
    var number: Int
    var title: String
    var description: String?
    var labelNames: [String]
    var comments: [SandboxCommentFixture] = []
    var commentSeq: Int = 0
}

private struct SandboxCommentFixture: Codable {
    var id: String
    var body: String
    var createdAt: Double // epoch seconds
}

final class MockIssueClient: IssueSourceClient, @unchecked Sendable {
    private let lock = NSLock()

    /// Synchronous scoped lock — NSLock.lock()/unlock() are unavailable directly
    /// in async contexts under Swift 6, so the critical section lives in a sync
    /// closure the async protocol methods call into.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Fixture IO

    private func filePath(for number: Int) -> String {
        "\(SandboxFixtures.issuesDir)/\(number).json"
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: SandboxFixtures.issuesDir,
            withIntermediateDirectories: true,
        )
    }

    private func loadAll() -> [SandboxIssueFixture] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: SandboxFixtures.issuesDir) else { return [] }
        let issues = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> SandboxIssueFixture? in
                let path = "\(SandboxFixtures.issuesDir)/\(name)"
                guard let data = fm.contents(atPath: path) else { return nil }
                return try? JSONDecoder().decode(SandboxIssueFixture.self, from: data)
            }
        return issues.sorted { $0.number < $1.number }
    }

    private func load(_ number: Int) -> SandboxIssueFixture? {
        guard let data = FileManager.default.contents(atPath: filePath(for: number)) else { return nil }
        return try? JSONDecoder().decode(SandboxIssueFixture.self, from: data)
    }

    private func save(_ issue: SandboxIssueFixture) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(issue) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath(for: issue.number)))
    }

    // MARK: - Mapping

    private func ref(_ issue: SandboxIssueFixture) -> IssueRef {
        IssueRef(
            id: "\(SandboxFixtures.surfaceId)#\(issue.number)",
            identifier: "\(SandboxFixtures.surfaceId)#\(issue.number)",
            title: issue.title,
            description: issue.description,
            labelNames: issue.labelNames,
            scope: .githubRepo(owner: "sandbox", repo: "demo", number: issue.number),
        )
    }

    private func number(of ref: IssueRef) -> Int? {
        if case let .githubRepo(_, _, n) = ref.scope { return n }
        return nil
    }

    private func comments(for number: Int) -> [IssueComment] {
        (load(number)?.comments ?? []).map {
            IssueComment(id: $0.id, body: $0.body, createdAt: Date(timeIntervalSince1970: $0.createdAt))
        }
    }

    // MARK: - IssueSourceClient

    func fetchTriggerQueue(config _: SourceConfig, auth _: SourceAuth) async throws -> [IssueRef] {
        withLock { loadAll().filter { $0.labelNames.contains(LemonState.trigger.labelName) }.map(ref) }
    }

    func fetchCompleteQueue(config _: SourceConfig, auth _: SourceAuth) async throws -> [IssueRef] {
        withLock { loadAll().filter { $0.labelNames.contains(LemonState.complete.labelName) }.map(ref) }
    }

    func fetchIssueLabels(ref: IssueRef, auth _: SourceAuth) async throws -> [String]? {
        withLock {
            guard let n = number(of: ref) else { return nil }
            return load(n)?.labelNames
        }
    }

    func applyState(ref: IssueRef, state: LemonState, auth _: SourceAuth) async throws {
        withLock {
            guard let n = number(of: ref), var issue = load(n) else { return }
            if !issue.labelNames.contains(state.labelName) {
                issue.labelNames.append(state.labelName)
                save(issue)
            }
        }
    }

    func clearState(ref: IssueRef, state: LemonState, auth _: SourceAuth) async throws {
        withLock {
            guard let n = number(of: ref), var issue = load(n) else { return }
            issue.labelNames.removeAll { $0 == state.labelName }
            save(issue)
        }
    }

    @discardableResult
    func postComment(ref: IssueRef, body: String, auth _: SourceAuth) async throws -> String {
        withLock {
            guard let n = number(of: ref), var issue = load(n) else { return "" }
            issue.commentSeq += 1
            let id = "c\(issue.commentSeq)"
            issue.comments.append(SandboxCommentFixture(
                id: id, body: body, createdAt: Date().timeIntervalSince1970,
            ))
            save(issue)
            return id
        }
    }

    func fetchComments(ref: IssueRef, auth _: SourceAuth) async throws -> [IssueComment] {
        withLock {
            guard let n = number(of: ref) else { return [] }
            return comments(for: n)
        }
    }

    func hasNewComment(ref: IssueRef, afterCommentId: String, auth _: SourceAuth) async throws -> Bool {
        withLock {
            guard let n = number(of: ref) else { return false }
            return LemonMarkerExtractor.hasNewComment(in: comments(for: n), afterCommentId: afterCommentId)
        }
    }

    func fetchCommentsAfter(ref: IssueRef, afterCommentId: String, auth _: SourceAuth) async throws -> [String] {
        withLock {
            guard let n = number(of: ref) else { return [] }
            return LemonMarkerExtractor.bodiesAfter(in: comments(for: n), afterCommentId: afterCommentId)
        }
    }

    func findLemonMarker(ref: IssueRef, auth _: SourceAuth) async throws -> LemonMarker? {
        withLock {
            guard let n = number(of: ref) else { return nil }
            return LemonMarkerExtractor.findLatest(in: comments(for: n))
        }
    }

    func bootstrapLabels(config _: SourceConfig, auth _: SourceAuth) async throws {
        ensureDir() // labels are implicit in the sandbox; just make sure the dir exists
    }

    func verifyCredential(token _: String, host _: String?) async throws -> CredentialIdentity {
        CredentialIdentity(id: "sandbox", displayName: "Sandbox", handle: "sandbox", avatarUrl: nil)
    }

    func listSurfaces(token _: String, host _: String?) async throws -> [Surface] {
        [SandboxFixtures.surface]
    }

    func countAssignedOpenIssues(token _: String, host _: String?, principalId _: String) async throws -> Int {
        withLock { loadAll().count }
    }
}
