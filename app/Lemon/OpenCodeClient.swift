import Foundation
import os

enum OpenCodeClientError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid OpenCode response"
        case let .http(code, body):
            "OpenCode HTTP \(code): \(body.prefix(200))"
        case let .decode(msg):
            "OpenCode decode failed: \(msg)"
        }
    }
}

struct OpenCodeSessionCreateRequest: Codable {
    var model: String?
    var dir: String?
    var agent: String?
}

struct OpenCodeSessionCreateResponse: Codable {
    var id: String
}

struct OpenCodeMessageRequest: Codable {
    var content: String
    var prompt_async: Bool?
}

struct OpenCodePermissionResponse: Codable {
    var decision: String
}

final class OpenCodeClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(host: String = "127.0.0.1", port: Int = 4096, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.session = session
    }

    func docReachable() async -> Bool {
        do {
            _ = try await request("GET", path: "/doc")
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func createSession(_ requestBody: OpenCodeSessionCreateRequest) async throws -> OpenCodeSessionCreateResponse {
        let body = try JSONEncoder().encode(requestBody)
        let data = try await request("POST", path: "/session", body: body)
        return try decode(data, as: OpenCodeSessionCreateResponse.self)
    }

    func sendMessage(sessionID: String, body requestBody: OpenCodeMessageRequest) async throws {
        let body = try JSONEncoder().encode(requestBody)
        _ = try await request("POST", path: "/session/\(sessionID)/message", body: body)
    }

    func answerPermission(sessionID: String, permissionID: String, decision: OpenCodePermissionResponse) async throws {
        let body = try JSONEncoder().encode(decision)
        _ = try await request("POST", path: "/session/\(sessionID)/permissions/\(permissionID)", body: body)
    }

    private func request(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse
        }
        let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        Logger.opencode.debug("[opencode] \(method) \(path) -> \(http.statusCode) \(bodyText.prefix(200))")
        guard (200 ... 299).contains(http.statusCode) else {
            throw OpenCodeClientError.http(http.statusCode, bodyText)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenCodeClientError.decode(error.localizedDescription)
        }
    }
}
