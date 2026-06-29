@testable import Lemon
import XCTest

final class GitHubClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStubURLProtocol.self]
        session = URLSession(configuration: config)
        GitHubStubURLProtocol.reset()
    }

    private func client() -> GitHubClient {
        GitHubClient(session: session)
    }

    private func auth() -> SourceAuth {
        .github(pat: "test-pat", login: "frkline")
    }

    private func githubRef(owner: String = "acme", repo: String = "widgets", number: Int = 7) -> IssueRef {
        IssueRef(
            id: "\(owner)/\(repo)#\(number)",
            identifier: "\(owner)/\(repo)#\(number)",
            title: "Sample",
            description: nil,
            labelNames: [],
            scope: .githubRepo(owner: owner, repo: repo, number: number),
        )
    }

    // MARK: - Search

    func testFetchTriggerQueueParsesSearchResults() async throws {
        let item = """
        {
          "id": 9,
          "number": 7,
          "title": "Fix the bug",
          "body": "Details",
          "labels": [{"name":"🍋"}],
          "repository_url": "https://api.github.com/repos/acme/widgets",
          "html_url": "https://github.com/acme/widgets/issues/7"
        }
        """
        GitHubStubURLProtocol.respond(json: "{\"total_count\":1,\"items\":[\(item)]}")
        let cfg = SourceConfig(source: .github, displayName: "GitHub", githubRepos: ["acme/widgets"])
        let issues = try await client().fetchTriggerQueue(config: cfg, auth: auth())
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].identifier, "acme/widgets#7")
        XCTAssertEqual(issues[0].scope, .githubRepo(owner: "acme", repo: "widgets", number: 7))
    }

    func testFetchTriggerQueueFiltersIssuesWithActiveLemonLabels() async throws {
        let inProgress = """
        {"id":1,"number":1,"title":"x","body":null,"labels":[{"name":"🍋"},{"name":"🍋 In Progress"}],"repository_url":"https://api.github.com/repos/acme/widgets","html_url":""}
        """
        let fresh = """
        {"id":2,"number":2,"title":"y","body":null,"labels":[{"name":"🍋"}],"repository_url":"https://api.github.com/repos/acme/widgets","html_url":""}
        """
        GitHubStubURLProtocol.respond(json: "{\"total_count\":2,\"items\":[\(inProgress),\(fresh)]}")
        let cfg = SourceConfig(source: .github, displayName: "GitHub", githubRepos: ["acme/widgets"])
        let issues = try await client().fetchTriggerQueue(config: cfg, auth: auth())
        XCTAssertEqual(issues.map(\.id), ["acme/widgets#2"])
    }

    func testFetchTriggerQueueEmptyReposReturnsEmpty() async throws {
        let cfg = SourceConfig(source: .github, displayName: "GitHub", githubRepos: [])
        let issues = try await client().fetchTriggerQueue(config: cfg, auth: auth())
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Auth verification

    func testVerifyCredentialReturnsIdentity() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":42,"login":"frkline","name":"Frank Kline","avatar_url":"https://avatars/frkline"}
        """)
        let id = try await client().verifyCredential(token: "test-pat")
        XCTAssertEqual(id.id, "42")
        XCTAssertEqual(id.displayName, "Frank Kline")
        XCTAssertEqual(id.avatarUrl, "https://avatars/frkline")
    }

    func testVerifyCredentialFallsBackToLoginWhenNameMissing() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":1,"login":"justlogin","name":null,"avatar_url":null}
        """)
        let id = try await client().verifyCredential(token: "t")
        XCTAssertEqual(id.displayName, "justlogin")
    }

    // MARK: - Auth headers

    func testRequestsCarryBearerTokenAndJsonAccept() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":1,"login":"x","name":null,"avatar_url":null}
        """)
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        _ = try await client().verifyCredential(token: "shh")
        XCTAssertEqual(observed?.value(forHTTPHeaderField: "Authorization"), "Bearer shh")
        XCTAssertEqual(observed?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(observed?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    // MARK: - Mutation: postComment

    func testPostCommentReturnsCreatedId() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":12345,"body":"hi","user":{"login":"frkline"}}
        """)
        let id = try await client().postComment(ref: githubRef(), body: "hi", auth: auth())
        XCTAssertEqual(id, "12345")
    }

    // MARK: - Errors

    func testThrowsOn401() async throws {
        GitHubStubURLProtocol.respond(json: "{}", statusCode: 401)
        do {
            _ = try await client().verifyCredential(token: "bad")
            XCTFail("Expected throw")
        } catch {
            XCTAssertTrue(error is GitHubClient.GitHubError)
        }
    }

    // MARK: - Label color sanity

    //
    // The single biggest regression risk: GH expects bare hex without '#'.
    // We can't observe the encoded body through a simple stub without
    // pulling it out of httpBodyStream — verifyCredential is enough as a
    // smoke; the color logic is contained in bareHexColor(for:) and
    // exercised end-to-end during ensureLabel.

    func testLabelColorStripsLeadingHash() {
        let triggerColor = LinearClient.labelColors[LemonState.trigger.labelName] ?? ""
        XCTAssertTrue(triggerColor.hasPrefix("#"),
                      "LinearClient palette stores '#'-prefixed values; GitHubClient strips it on send.")
    }

    // MARK: - Label removal (regression: #51 double-encoding)

    ///
    /// removeLabel used to pre-percent-encode the label name AND let
    /// authedRequest's appendingPathComponent encode it again — "🍋 Waiting"
    /// became %25F0…%2520Waiting, GitHub 404'd, and allow404 masked it so the
    /// label was silently never removed. That left every gate transition with
    /// stale 🍋 labels and desynced the session status for the whole build (#51).
    /// This locks in single-encoding: the emoji + space appear once, never %25.
    func testClearStateSingleEncodesEmojiLabelInDeletePath() async throws {
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        GitHubStubURLProtocol.respond(json: "[]") // DELETE returns the remaining labels

        try await client().clearState(ref: githubRef(), state: .waiting, auth: auth())

        XCTAssertEqual(observed?.httpMethod, "DELETE")
        let url = try XCTUnwrap(observed?.url?.absoluteString)
        XCTAssertTrue(url.contains("/labels/%F0%9F%8D%8B%20Waiting"),
                      "expected single-encoded label path, got \(url)")
        XCTAssertFalse(url.contains("%25"),
                       "label name was double-encoded (the #51 bug): \(url)")
    }

    // MARK: - bootstrapLabels

    //
    // Regression: the trigger label was getting silently dropped because
    // GitHub rejects pure-emoji label names ("Name must contain more
    // than native emoji") and the bare "🍋" POST returned 422. The
    // bootstrap now sends "🍋 Lemon" on the wire for the trigger state
    // (everything else keeps its canonical name) and translates inbound
    // labels back at read time. This test locks in the wire shape.

    func testBootstrapLabelsPostsAllFourStates() async throws {
        var posted: [(name: String, color: String, description: String)] = []
        GitHubStubURLProtocol.onRequest = { req in
            guard req.httpMethod == "POST",
                  let path = req.url?.path,
                  path.hasSuffix("/labels") else { return }
            guard let data = req.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            posted.append((
                name: (json["name"] as? String) ?? "",
                color: (json["color"] as? String) ?? "",
                description: (json["description"] as? String) ?? "",
            ))
        }
        GitHubStubURLProtocol.respond(json: "{}", statusCode: 201)

        let cfg = SourceConfig(source: .github, displayName: "g", githubRepos: ["acme/widgets"])
        try await client().bootstrapLabels(config: cfg, auth: auth())

        let names = Set(posted.map(\.name))
        XCTAssertEqual(names,
                       Set(["🍋 Lemon", "🍋 In Progress", "🍋 Waiting", "🍋 Complete"]),
                       "Trigger label is renamed to '🍋 Lemon' on the GH wire — GH rejects pure-emoji names.")
        XCTAssertTrue(posted.allSatisfy { !$0.color.hasPrefix("#") },
                      "GitHub expects bare hex colors without leading '#'.")
        XCTAssertTrue(posted.allSatisfy { !$0.description.isEmpty },
                      "Each Lemon label should ship with a description GitHub renders in tooltips.")
    }

    func testSearchQueryUsesAssigneeShapeAndOmitsLabelFilter() async throws {
        // Regression: GitHub's lexical search engine silently swallows
        // `label:"🍋 Lemon"` (emoji-bearing label queries return 0 even
        // when the label is applied). The proven-working shape is the
        // same one verifyCredential / countAssignedOpenIssues use:
        // `repo:o/r is:issue is:open assignee:LOGIN`. Label filtering
        // moves client-side. Lock the wire shape so we don't regress
        // back into the lexical pothole.
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        GitHubStubURLProtocol.respond(json: "{\"total_count\":0,\"items\":[]}")

        let cfg = SourceConfig(source: .github, displayName: "g", githubRepos: ["frkline/lemon"])
        _ = try await client().fetchTriggerQueue(config: cfg, auth: auth())

        let q = observed?.url?.query(percentEncoded: false) ?? ""
        XCTAssertTrue(q.contains("repo:frkline/lemon"), "Query must scope to the configured repo. Got: \(q)")
        XCTAssertTrue(q.contains("is:issue"), "Query must filter to issues. Got: \(q)")
        XCTAssertTrue(q.contains("is:open"), "Query must filter to open. Got: \(q)")
        XCTAssertTrue(q.contains("assignee:frkline"), "Query must use the proven assignee:LOGIN form. Got: \(q)")
        XCTAssertFalse(q.contains("label:"), "Query must NOT include a label filter — that's done client-side. Got: \(q)")
        XCTAssertFalse(q.contains(" OR "), "Old OR construct should be gone. Got: \(q)")
    }

    func testIncomingTriggerLabelIsNormalizedToCanonical() async throws {
        // GH returns "🍋 Lemon" on an issue; downstream code (WorktreeRunner,
        // state checks) compares against LemonState.trigger.labelName which
        // is bare "🍋". The client should translate at the read boundary.
        let item = """
        {
          "id": 9,
          "number": 7,
          "title": "Fix it",
          "body": null,
          "labels": [{"name":"🍋 Lemon"}],
          "repository_url": "https://api.github.com/repos/acme/widgets",
          "html_url": ""
        }
        """
        GitHubStubURLProtocol.respond(json: "{\"total_count\":1,\"items\":[\(item)]}")
        let cfg = SourceConfig(source: .github, displayName: "g", githubRepos: ["acme/widgets"])
        let refs = try await client().fetchTriggerQueue(config: cfg, auth: auth())
        XCTAssertEqual(refs.first?.labelNames, ["🍋"],
                       "Inbound '🍋 Lemon' must be normalized back to the canonical LemonState.trigger.labelName.")
    }

    func testBootstrapLabelsTreats422AsAlreadyExists() async throws {
        // Pre-existing labels return 422; ensureLabel should swallow that
        // and bootstrapLabels should not throw.
        GitHubStubURLProtocol.respond(json: "{\"message\":\"Validation Failed\"}", statusCode: 422)
        let cfg = SourceConfig(source: .github, displayName: "g", githubRepos: ["acme/widgets"])
        try await client().bootstrapLabels(config: cfg, auth: auth())
    }

    // MARK: - Enterprise host

    func testEnterpriseHostRoutesAPIRequestsCorrectly() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":1,"login":"frank-acme","name":null,"avatar_url":null}
        """)
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        _ = try await client().verifyCredential(token: "tok", host: "api.github.acmecorp.com")
        XCTAssertEqual(observed?.url?.host, "api.github.acmecorp.com",
                       "Enterprise host should replace the default api.github.com base.")
        XCTAssertEqual(observed?.url?.path, "/user")
    }

    func testNilHostDefaultsToGithubDotCom() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":1,"login":"x","name":null,"avatar_url":null}
        """)
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        _ = try await client().verifyCredential(token: "tok", host: nil)
        XCTAssertEqual(observed?.url?.host, "api.github.com")
    }

    func testEmptyHostFallsBackToGithubDotCom() async throws {
        GitHubStubURLProtocol.respond(json: """
        {"id":1,"login":"x","name":null,"avatar_url":null}
        """)
        var observed: URLRequest?
        GitHubStubURLProtocol.onRequest = { observed = $0 }
        _ = try await client().verifyCredential(token: "tok", host: "   ")
        XCTAssertEqual(observed?.url?.host, "api.github.com",
                       "Whitespace-only host treated as unset.")
    }
}

// MARK: - URLProtocol stub (parallel to StubURLProtocol used by LinearClientTests).

final class GitHubStubURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var _data = Data()
    private nonisolated(unsafe) static var _statusCode = 200
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?

    static func reset() {
        _data = Data()
        _statusCode = 200
        onRequest = nil
    }

    static func respond(json: String, statusCode: Int = 200) {
        _data = Data(json.utf8)
        _statusCode = statusCode
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let hook = Self.onRequest {
            var req = request
            if let stream = request.httpBodyStream {
                var bodyData = Data()
                stream.open()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n > 0 { bodyData.append(buf, count: n) }
                }
                buf.deallocate()
                stream.close()
                req.httpBody = bodyData
            }
            hook(req)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self._statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self._data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
