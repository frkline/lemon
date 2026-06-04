import Foundation
import Network
import os

// Localhost-only MCP server. Exposes Lemon's session state and a few control
// tools so Claude Code (or another MCP client) can observe and steer an active
// 🍋 session. Disabled by default; enabled via Settings or LEMON_ENABLE_MCP=1.
//
// Wire format: JSON-RPC 2.0 over plain HTTP/1.1. No SSE, no keep-alive — each
// request opens a connection, gets one response, closes. That's fine for the
// "Claude pokes Lemon, gets back state" loop we care about. Streaming can come
// later if a tool needs progress events.
//
// Auth: 127.0.0.1 bind only. Any process on this Mac that can reach the loopback
// can call any tool — same threat model as Lemon's running process itself.
final class LemonMCPServer: @unchecked Sendable {
    static let shared = LemonMCPServer()
    static let defaultPort: UInt16 = 8765

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    private let lock = NSLock()

    // Tool registry — name → descriptor + async handler.
    // Handler returns a pre-encoded JSON String (Sendable across actor hops),
    // which the dispatcher wraps into MCP's text content body verbatim. This
    // avoids the strict-concurrency trap of returning [String: Any] from a
    // MainActor closure (Any isn't Sendable).
    // @unchecked Sendable: inputSchema is an Any-typed JSON-Schema dict that
    // we only ever read after registration; mutation is lock-guarded.
    struct Tool: @unchecked Sendable {
        let name: String
        let description: String
        let inputSchema: [String: Any]  // JSON-Schema dict
        let handler: @Sendable (_ args: [String: Any]) async throws -> String
    }
    private var tools: [String: Tool] = [:]

    private init() {}

    func register(_ tool: Tool) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.name] = tool
    }

    private func snapshotTools() -> [Tool] {
        lock.lock(); defer { lock.unlock() }
        return tools.values.sorted { $0.name < $1.name }
    }

    private func tool(named name: String) -> Tool? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    // MARK: - Lifecycle

    func start(port requested: UInt16) throws {
        if isRunning { return }
        guard let nport = NWEndpoint.Port(rawValue: requested) else {
            throw MCPError(code: -1, message: "invalid port: \(requested)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nport)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            Logger.orchestrator.error("MCP listener bind failed on \(requested): \(error.localizedDescription)")
            throw error
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.port = requested
        self.isRunning = true
        Logger.orchestrator.info("MCP server listening on http://127.0.0.1:\(requested)/mcp")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        isRunning = false
        Logger.orchestrator.info("MCP server stopped")
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        readRequest(conn, accumulated: Data()) { [weak self] req in
            guard let self else { conn.cancel(); return }
            Task {
                let response = await self.process(request: req)
                self.write(response: response, on: conn)
            }
        }
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data, completion: @escaping @Sendable (HTTPRequest?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let error {
                Logger.orchestrator.error("MCP receive error: \(error.localizedDescription)")
                completion(nil); return
            }
            var buf = accumulated
            if let data { buf.append(data) }
            if let req = HTTPRequest.tryParse(buf) {
                completion(req); return
            }
            if isComplete {
                completion(buf.isEmpty ? nil : HTTPRequest.tryParse(buf))
                return
            }
            self?.readRequest(conn, accumulated: buf, completion: completion)
        }
    }

    private func write(response: HTTPResponse, on conn: NWConnection) {
        conn.send(content: response.serialize(), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - JSON-RPC dispatch

    private func process(request: HTTPRequest?) async -> HTTPResponse {
        guard let request else {
            return HTTPResponse(status: 400, body: Data("bad request\n".utf8))
        }
        // Liveness probe — handy for the Settings UI's "running?" indicator.
        if request.method == "GET" && request.path == "/" {
            return HTTPResponse(status: 200,
                                body: Data("{\"ok\":true,\"server\":\"lemon-mcp\"}\n".utf8),
                                contentType: "application/json")
        }
        guard request.method == "POST", request.path == "/mcp" else {
            return HTTPResponse(status: 404, body: Data("not found\n".utf8))
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return jsonRPCResponse(id: nil, error: (code: -32700, message: "parse error"))
        }
        let id = body["id"]  // may be nil for notifications
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? [String: Any] ?? [:]

        // Notifications (no id) — handle and acknowledge with an empty 200.
        // Per JSON-RPC 2.0 we shouldn't send a response body, but a 200 OK
        // with empty JSON keeps HTTP clients happy and the client ignores it.
        let isNotification = (id == nil) || (id is NSNull)

        do {
            let result = try await dispatch(method: method, params: params)
            if isNotification {
                return HTTPResponse(status: 200, body: Data("{}".utf8), contentType: "application/json")
            }
            return jsonRPCResponse(id: id, result: result)
        } catch let e as MCPError {
            return jsonRPCResponse(id: id, error: (code: e.code, message: e.message))
        } catch {
            return jsonRPCResponse(id: id, error: (code: -32603, message: error.localizedDescription))
        }
    }

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "lemon", "version": "0.1.0"]
            ]
        case "initialized", "notifications/initialized":
            return [String: Any]()  // no-op handshake completion
        case "ping":
            return [String: Any]()
        case "tools/list":
            return [
                "tools": snapshotTools().map { t -> [String: Any] in
                    ["name": t.name,
                     "description": t.description,
                     "inputSchema": t.inputSchema]
                }
            ]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError(code: -32602, message: "missing 'name' in tools/call params")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = tool(named: name) else {
                throw MCPError(code: -32601, message: "unknown tool: \(name)")
            }
            do {
                let text = try await tool.handler(args)
                return ["content": [["type": "text", "text": text]]]
            } catch {
                return [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true
                ]
            }
        default:
            throw MCPError(code: -32601, message: "method not found: \(method)")
        }
    }

    // Convenience for tool handlers that build a JSON-serializable [String: Any]
    // and need to hand back a pre-encoded String. Use from inside a MainActor.run
    // closure when the dict references actor-isolated state.
    static func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private func jsonRPCResponse(id: Any?, result: Any) -> HTTPResponse {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
        return jsonResponse(body)
    }

    private func jsonRPCResponse(id: Any?, error: (code: Int, message: String)) -> HTTPResponse {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": error.code, "message": error.message]
        ]
        return jsonResponse(body)
    }

    private func jsonResponse(_ body: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, body: data, contentType: "application/json")
    }
}

// MARK: - MCP error

struct MCPError: Error {
    let code: Int
    let message: String
}

// MARK: - Tiny HTTP/1.1 parser

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    // Returns nil if we don't yet have a complete request (caller should keep reading).
    static func tryParse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerStr = String(data: data.subdata(in: data.startIndex..<sep.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return nil }  // body still streaming
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data
    var contentType: String = "text/plain"

    func serialize() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        default:  reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
