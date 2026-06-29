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

struct OpenCodeModelReference: Codable, Equatable {
    var id: String
    var providerID: String
}

struct OpenCodeSessionCreateRequest: Encodable {
    var model: OpenCodeModelReference?
    var dir: String?
    var agent: String?

    enum CodingKeys: String, CodingKey {
        case model, agent
    }
}

struct OpenCodeSessionCreateResponse: Codable {
    var id: String
}

struct OpenCodeMessageRequest: Encodable {
    var content: String
    var prompt_async: Bool?

    enum CodingKeys: String, CodingKey {
        case parts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([OpenCodeTextPartInput(text: content)], forKey: .parts)
    }
}

private struct OpenCodeTextPartInput: Encodable {
    var type = "text"
    var text: String
}

struct OpenCodePermissionResponse: Codable {
    var decision: String
}

enum OpenCodeSessionLiveness: Equatable {
    case active
    case terminal
    case unknown
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

    func daemonReachable() async -> Bool {
        let paths = ["/doc", "/config/providers", "/provider", "/api/model"]
        for path in paths {
            guard await (try? request("GET", path: path)) == nil else { return true }
        }
        return false
    }

    func availableModelIDs() async -> [String] {
        let paths = ["/config/providers", "/provider", "/api/model", "/api/provider", "/doc"]
        var seen = Set<String>()
        var ordered: [String] = []

        for path in paths {
            guard let data = try? await request("GET", path: path) else { continue }
            let models = Self.extractModelIDs(from: data)
            for model in models where seen.insert(model).inserted {
                ordered.append(model)
            }
        }

        return ordered
    }

    @discardableResult
    func createSession(_ requestBody: OpenCodeSessionCreateRequest) async throws -> OpenCodeSessionCreateResponse {
        let body = try JSONEncoder().encode(requestBody)
        let query = requestBody.dir.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        let data = try await request("POST", path: "/session", queryItems: query, body: body)
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

    func sessionLiveness(sessionID: String) async -> OpenCodeSessionLiveness {
        do {
            let data = try await request("GET", path: "/session/\(sessionID)")
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else { return .unknown }
            return Self.classifyLiveness(payload: dict)
        } catch let OpenCodeClientError.http(code, _) where code == 404 || code == 410 {
            // Session not found / gone is terminal for Lemon tracking.
            return .terminal
        } catch {
            return .unknown
        }
    }

    static func classifyLiveness(payload: [String: Any]) -> OpenCodeSessionLiveness {
        func boolProbe(_ key: String, in dict: [String: Any]) -> Bool? {
            dict[key] as? Bool
        }
        let nested = payload["session"] as? [String: Any]

        let terminalBooleans = [
            boolProbe("done", in: payload),
            boolProbe("completed", in: payload),
            boolProbe("stopped", in: payload),
            boolProbe("failed", in: payload),
            boolProbe("done", in: nested ?? [:]),
            boolProbe("completed", in: nested ?? [:]),
            boolProbe("stopped", in: nested ?? [:]),
            boolProbe("failed", in: nested ?? [:]),
        ]
        if terminalBooleans.contains(true) {
            return .terminal
        }

        let activeBooleans = [
            boolProbe("running", in: payload),
            boolProbe("active", in: payload),
            boolProbe("running", in: nested ?? [:]),
            boolProbe("active", in: nested ?? [:]),
        ]
        if activeBooleans.contains(true) {
            return .active
        }

        let probes = [
            payload["status"],
            payload["state"],
            nested?["status"],
            nested?["state"],
        ]
        let values = probes
            .compactMap { $0 as? String }
            .map { $0.lowercased() }
        let terminalStates = [
            "done", "completed", "stopped", "failed",
            "error", "crashed", "cancelled", "aborted",
        ]
        if values.contains(where: { terminalStates.contains($0) }) {
            return .terminal
        }
        let activeStates = ["running", "active", "queued", "working", "processing"]
        if values.contains(where: { activeStates.contains($0) }) {
            return .active
        }
        return .unknown
    }

    static func extractModelIDs(from data: Data) -> [String] {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return extractModelIDs(fromJSON: json)
        }

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return extractModelIDs(fromText: text)
    }

    static func extractModelIDs(fromJSON json: Any) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        func append(providerID: String?, modelID rawModelID: String) {
            let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else { return }
            let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = if let provider, !provider.isEmpty {
                "\(provider)/\(modelID)"
            } else {
                modelID
            }
            guard OpenCodeModelConfig.providerSlug(for: display) != nil else { return }
            if seen.insert(display).inserted {
                ordered.append(display)
            }
        }

        func visitModelList(_ node: Any) {
            switch node {
            case let dict as [String: Any]:
                let providerID = dict["providerID"] as? String
                    ?? dict["providerId"] as? String
                if let id = dict["id"] as? String, let providerID {
                    append(providerID: providerID, modelID: id)
                }

                if let models = dict["models"] as? [String: Any] {
                    let ownerProvider = dict["id"] as? String ?? providerID
                    for (key, value) in models {
                        if let model = value as? [String: Any], let id = model["id"] as? String {
                            append(providerID: ownerProvider, modelID: id)
                        } else {
                            append(providerID: ownerProvider, modelID: key)
                        }
                    }
                }

                for value in dict.values {
                    visitModelList(value)
                }

            case let array as [Any]:
                for value in array {
                    visitModelList(value)
                }

            default:
                break
            }
        }

        visitModelList(json)

        func visit(_ node: Any, keyHint: String?) {
            switch node {
            case let dict as [String: Any]:
                for (key, value) in dict {
                    visit(value, keyHint: key)
                }
            case let array as [Any]:
                for value in array {
                    visit(value, keyHint: keyHint)
                }
            case let value as String:
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if isLikelyModelID(trimmed, keyHint: keyHint), seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            default:
                break
            }
        }

        visit(json, keyHint: nil)
        return ordered
    }

    static func extractModelIDs(fromText text: String) -> [String] {
        let pattern = #"\b[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._:-]*\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: full)
        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
            if isLikelyModelID(candidate, keyHint: "model"), seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }
        return ordered
    }

    private static func isLikelyModelID(_ value: String, keyHint: String?) -> Bool {
        guard let provider = OpenCodeModelConfig.providerSlug(for: value) else { return false }

        let blockedProviders: Set = [
            "application", "audio", "font", "image", "message",
            "multipart", "text", "video",
        ]
        if blockedProviders.contains(provider) { return false }

        guard let keyHint else { return true }
        let lowered = keyHint.lowercased()
        return lowered.contains("model") || lowered == "id" || lowered.contains("name")
    }

    private func request(_ method: String, path: String, queryItems: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appendingPathComponent(normalizedPath), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw OpenCodeClientError.invalidResponse
        }

        var req = URLRequest(url: url)
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
        Logger.opencode.debug("[opencode] \(method) \(path) -> \(http.statusCode)")
        guard (200 ... 299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
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
