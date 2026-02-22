import Foundation
import ScannerSpectrumCore

public enum StationClientError: Error, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidResponse
    case http(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Station base URL."
        case .invalidResponse:
            return "Station response is not a valid HTTP response."
        case .http(let statusCode, let body):
            if body.isEmpty {
                return "Station request failed with HTTP \(statusCode)."
            }
            return "Station request failed with HTTP \(statusCode): \(body)"
        }
    }
}

public struct StationStatusEnvelope: Codable, Hashable, Sendable {
    public struct Station: Codable, Hashable, Sendable {
        public let ok: Bool
        public let uptime_ms: Int?
        public let last_ingest_ms: Int?
        public let last_error: String?
        public let pi_logger: String?
        public let nodes_total: Int?
        public let nodes_online: Int?
        public let tools: Int?
    }

    public let station: Station
    public let logger: [String: JSONValue]?
}

public struct StationNodeListResponse: Codable, Hashable, Sendable {
    public let items: [StationNode]
}

public struct StationNode: Codable, Hashable, Sendable, Identifiable {
    public let node_id: String
    public let state: String
    public let state_reason: String?
    public let presence_source: String?
    public let last_seen: Int?
    public let last_seen_age_ms: Int?
    public let last_error: String?
    public let ip: String?
    public let mac: String?
    public let hostname: String?
    public let confidence: Double?
    public let capabilities: [String: JSONValue]?
    public let provenance_id: String?

    public var id: String { node_id }
}

public struct StationToolRegistryResponse: Codable, Hashable, Sendable {
    public struct Tool: Codable, Hashable, Sendable, Identifiable {
        public let name: String
        public let title: String?
        public let description: String?
        public let runner: String?
        public let kind: String?
        public let tags: [String]?
        public let scope: String?

        public var id: String { name }
    }

    public let tools: [Tool]
}

public struct StationPresetRegistryResponse: Codable, Hashable, Sendable {
    public let presets: [StationPreset]
}

public struct StationPreset: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String?
    public let tool: String?
    public let input: [String: JSONValue]?
}

public struct StationRunbookRegistryResponse: Codable, Hashable, Sendable {
    public let runbooks: [StationRunbook]
}

public struct StationRunbook: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let description: String?
    public let steps: [StationRunbookStep]?
}

public struct StationRunbookStep: Codable, Hashable, Sendable {
    public let id: String?
    public let tool: String?
    public let input: [String: JSONValue]?
}

public struct StationRecentEventsResponse: Codable, Hashable, Sendable {
    public let items: [StationRecentEvent]
}

public struct StationRecentEvent: Codable, Hashable, Sendable, Identifiable {
    public let event_ts: String?
    public let recv_ts: String?
    public let kind: String
    public let node_id: String
    public let summary: String?
    public let data: [String: JSONValue]?

    public var id: String {
        "\(kind)|\(node_id)|\(event_ts ?? recv_ts ?? "unknown")"
    }
}

public final class StationAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let authToken: String?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, session: URLSession = .shared, authToken: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func status() async throws -> StationStatusEnvelope {
        try await request(path: "/api/status")
    }

    public func capabilities(client: PlatformClientType) async throws -> AppCapabilitiesResponse {
        try await request(path: "/api/app/capabilities?client=\(client.rawValue)")
    }

    public func nodes() async throws -> StationNodeListResponse {
        try await request(path: "/api/nodes")
    }

    public func tools() async throws -> StationToolRegistryResponse {
        try await request(path: "/api/tools")
    }

    public func runbooks() async throws -> StationRunbookRegistryResponse {
        try await request(path: "/api/runbooks")
    }

    public func presets() async throws -> StationPresetRegistryResponse {
        try await request(path: "/api/presets")
    }

    public func recentEvents(limit: Int = 50) async throws -> StationRecentEventsResponse {
        let clamped = max(1, min(200, limit))
        return try await request(path: "/api/events/recent?limit=\(clamped)")
    }

    public func runTool(name: String, input: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let requestBody = RunToolRequest(name: name, input: input)
        return try await request(path: "/api/tool/run", method: "POST", body: requestBody)
    }

    public func runRunbook(name: String, input: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let requestBody = RunbookRequest(name: name, input: input)
        return try await request(path: "/api/runbook/run", method: "POST", body: requestBody)
    }

    public func runPreset(id: String) async throws -> [String: JSONValue] {
        let requestBody = PresetRequest(id: id)
        return try await request(path: "/api/preset/run", method: "POST", body: requestBody)
    }

    private func request<T: Decodable>(path: String, method: String = "GET") async throws -> T {
        try await request(path: path, method: method, bodyData: nil)
    }

    private func request<T: Decodable, B: Encodable>(path: String, method: String, body: B) async throws -> T {
        let bodyData = try encoder.encode(body)
        return try await request(path: path, method: method, bodyData: bodyData)
    }

    private func request<T: Decodable>(path: String, method: String, bodyData: Data?) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw StationClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StationClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw StationClientError.http(statusCode: httpResponse.statusCode, body: text)
        }

        return try decoder.decode(T.self, from: data)
    }
}

private struct RunToolRequest: Encodable {
    let name: String
    let input: [String: JSONValue]
}

private struct RunbookRequest: Encodable {
    let name: String
    let input: [String: JSONValue]
}

private struct PresetRequest: Encodable {
    let id: String
}
