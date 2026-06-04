import XCTest
@testable import Lemon

// End-to-end tests that boot a real LemonMCPServer on an ephemeral high port,
// register a couple of synthetic tools, and exercise the JSON-RPC surface via
// URLSession. These prove the wire works without touching the real Orchestrator
// or live SwiftLM — the tool handlers we register are entirely self-contained.
final class LemonMCPServerTests: XCTestCase {
    private var server: LemonMCPServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        // Use a fresh LemonMCPServer per test class run. The singleton is global
        // by design (one server per app launch), so we just register our tools
        // on it and clean up on tearDown. Pick a random port in the ephemeral
        // range so parallel xcodebuild invocations don't collide.
        server = LemonMCPServer.shared
        port = UInt16.random(in: 30_000...60_000)
        try server.start(port: port)

        // Echo tool: returns its arguments verbatim. Validates arg passthrough.
        server.register(LemonMCPServer.Tool(
            name: "test_echo",
            description: "Returns the arguments dict, JSON-encoded.",
            inputSchema: ["type": "object"],
            handler: { args in
                LemonMCPServer.encode(args)
            }
        ))
        // Add tool: returns the sum of two integers. Validates typed-arg parsing.
        server.register(LemonMCPServer.Tool(
            name: "test_add",
            description: "Add a + b.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "a": ["type": "integer"],
                    "b": ["type": "integer"]
                ],
                "required": ["a", "b"]
            ],
            handler: { args in
                let a = (args["a"] as? Int) ?? 0
                let b = (args["b"] as? Int) ?? 0
                return LemonMCPServer.encode(["sum": a + b])
            }
        ))
        // Throwing tool: validates the dispatcher's MCPError → JSON-RPC error
        // mapping plus the isError-true content shape for tool execution errors.
        server.register(LemonMCPServer.Tool(
            name: "test_throws",
            description: "Always throws an MCPError.",
            inputSchema: ["type": "object"],
            handler: { _ in
                throw MCPError(code: -32099, message: "intentional test failure")
            }
        ))
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    // MARK: - Liveness

    func testGetRootReturnsLiveness() async throws {
        let resp = try await get(path: "/")
        XCTAssertEqual(resp.status, 200)
        let json = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["server"] as? String, "lemon-mcp")
    }

    func testUnknownPathReturns404() async throws {
        let resp = try await post(path: "/nope", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        XCTAssertEqual(resp.status, 404)
    }

    // MARK: - JSON-RPC core methods

    func testInitializeReturnsServerInfo() async throws {
        let body = try await rpc(id: 1, method: "initialize", params: ["protocolVersion": "2024-11-05"])
        let result = body["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "lemon")
    }

    func testToolsListContainsRegisteredTools() async throws {
        let body = try await rpc(id: 2, method: "tools/list", params: [:])
        let tools = (body["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("test_echo"), "echo tool should be in tools/list")
        XCTAssertTrue(names.contains("test_add"))
        XCTAssertTrue(names.contains("test_throws"))
        // Each tool entry must carry the MCP-required fields.
        for entry in tools {
            XCTAssertNotNil(entry["name"])
            XCTAssertNotNil(entry["description"])
            XCTAssertNotNil(entry["inputSchema"])
        }
    }

    func testToolsCallEchoesArguments() async throws {
        let body = try await rpc(id: 3, method: "tools/call",
                                 params: ["name": "test_echo",
                                          "arguments": ["foo": "bar", "n": 42]])
        let content = ((body["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        let text = content?["text"] as? String ?? ""
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["foo"] as? String, "bar")
        XCTAssertEqual(parsed?["n"] as? Int, 42)
    }

    func testToolsCallAddIntegers() async throws {
        let body = try await rpc(id: 4, method: "tools/call",
                                 params: ["name": "test_add",
                                          "arguments": ["a": 7, "b": 35]])
        let text = ((body["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["sum"] as? Int, 42)
    }

    func testToolsCallUnknownToolReturnsIsError() async throws {
        let body = try await rpc(id: 5, method: "tools/call",
                                 params: ["name": "no_such_tool", "arguments": [:]])
        // Unknown tool → JSON-RPC error in the response, not a tool isError.
        let error = body["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    func testThrowingToolReturnsIsErrorContent() async throws {
        let body = try await rpc(id: 6, method: "tools/call",
                                 params: ["name": "test_throws", "arguments": [:]])
        let result = body["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("intentional test failure"),
                      "error text should surface the underlying MCPError message; got: \(text)")
    }

    func testUnknownMethodReturnsJSONRPCError() async throws {
        let body = try await rpc(id: 7, method: "does/not/exist", params: [:])
        let error = body["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    func testMalformedJSONReturnsParseError() async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{this is not json".utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = body["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32700)
    }

    // MARK: - Helpers

    private struct HTTPResult { let status: Int; let body: Data }

    private func get(path: String) async throws -> HTTPResult {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        return HTTPResult(status: (resp as! HTTPURLResponse).statusCode, body: data)
    }

    private func post(path: String, body: [String: Any]) async throws -> HTTPResult {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return HTTPResult(status: (resp as! HTTPURLResponse).statusCode, body: data)
    }

    private func rpc(id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        let resp = try await post(path: "/mcp",
                                  body: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        XCTAssertEqual(resp.status, 200, "RPC \(method) returned non-200")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
    }
}
