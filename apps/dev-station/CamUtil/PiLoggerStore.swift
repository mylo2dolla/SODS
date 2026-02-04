import Foundation
import AppKit

@MainActor
final class SODSStore: ObservableObject {
    static let shared = SODSStore()

    @Published private(set) var events: [NormalizedEvent] = []
    @Published private(set) var nodes: [SignalNode] = []
    @Published private(set) var health: APIHealth = .offline
    @Published private(set) var lastError: String?
    @Published private(set) var lastPoll: Date?
    @Published var baseURL: String

    private let baseURLKey = "SODSBaseURL"
    private var wsTask: URLSessionWebSocketTask?
    private var pollTimer: Timer?
    private var maxEvents = 1200

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: baseURLKey), !saved.isEmpty {
            baseURL = saved
        } else {
            baseURL = "http://localhost:9123"
            defaults.set(baseURL, forKey: baseURLKey)
        }
        connect()
    }

    func updateBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        baseURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: baseURLKey)
        connect()
    }

    func connect() {
        wsTask?.cancel()
        wsTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        events.removeAll()
        connectWebSocket()
        schedulePoll()
    }

    private func schedulePoll() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.pollHealthAndNodes() }
        }
        Task { await pollHealthAndNodes() }
    }

    private func connectWebSocket() {
        guard let url = makeURL(path: "/ws/events") else { return }
        let wsURL = url.absoluteString.replacingOccurrences(of: "http", with: "ws")
        guard let finalURL = URL(string: wsURL) else { return }
        let task = URLSession.shared.webSocketTask(with: finalURL)
        wsTask = task
        task.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.health = .offline
            case .success(let message):
                self.handle(message: message)
            }
            self.receiveLoop()
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8) {
                decodeEvent(data)
            }
        case .data(let data):
            decodeEvent(data)
        @unknown default:
            break
        }
    }

    private func decodeEvent(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let event = try decoder.decode(CanonicalEvent.self, from: data)
            let normalized = NormalizedEvent(from: event)
            events.append(normalized)
            if events.count > maxEvents {
                events.removeFirst(events.count - maxEvents)
            }
            lastPoll = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pollHealthAndNodes() async {
        do {
            let healthURL = makeURL(path: "/health")
            let nodesURL = makeURL(path: "/nodes")
            guard let healthURL, let nodesURL else { return }

            async let healthReq = URLSession.shared.data(from: healthURL)
            async let nodesReq = URLSession.shared.data(from: nodesURL)

            let (healthData, _) = try await healthReq
            let (nodesData, _) = try await nodesReq

            let decoder = JSONDecoder()
            let healthPayload = try decoder.decode(SODSHealth.self, from: healthData)
            let nodesPayload = try decoder.decode(SODSNodesEnvelope.self, from: nodesData)

            health = .connected
            lastError = nil
            nodes = nodesPayload.items.map {
                SignalNode(
                    id: $0.nodeID,
                    lastSeen: Date(timeIntervalSince1970: TimeInterval($0.lastSeen / 1000)),
                    ip: $0.ip,
                    hostname: $0.hostname,
                    mac: $0.mac,
                    lastKind: $0.lastKind
                )
            }
        } catch {
            lastError = error.localizedDescription
            health = .degraded
        }
    }

    func openEndpoint(for node: SignalNode, path: String) {
        guard let ip = node.ip, !ip.isEmpty else { return }
        guard let url = URL(string: "http://\(ip)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeURL(path: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        let existingPath = components.path
        if existingPath.isEmpty || existingPath == "/" {
            components.path = path
        } else {
            components.path = existingPath + path
        }
        return components.url
    }
}

enum APIHealth: String {
    case connected
    case degraded
    case offline

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .degraded: return "Degraded"
        case .offline: return "Offline"
        }
    }

    var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .degraded: return .systemOrange
        case .offline: return .systemRed
        }
    }
}

struct SignalNode: Identifiable, Hashable {
    let id: String
    var lastSeen: Date = .distantPast
    var ip: String?
    var hostname: String?
    var mac: String?
    var lastKind: String?

    var isStale: Bool {
        Date().timeIntervalSince(lastSeen) > 60
    }
}

struct SODSHealth: Decodable {
    let ok: Bool
    let uptimeMs: Int?
    let lastIngestMs: Int?
}

struct SODSNodesEnvelope: Decodable {
    let items: [SODSNode]
}

struct SODSNode: Decodable {
    let nodeID: String
    let ip: String?
    let mac: String?
    let hostname: String?
    let lastSeen: Int
    let lastKind: String?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case ip
        case mac
        case hostname
        case lastSeen = "last_seen"
        case lastKind = "last_kind"
    }
}

struct CanonicalEvent: Decodable, Hashable {
    let id: String?
    let recvTs: Int
    let eventTs: String
    let nodeID: String
    let kind: String
    let severity: String
    let summary: String
    let data: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case recvTs = "recv_ts"
        case eventTs = "event_ts"
        case nodeID = "node_id"
        case kind
        case severity
        case summary
        case data
    }
}

struct NormalizedEvent: Identifiable, Hashable {
    let id: String
    let recvTs: Date?
    let eventTs: Date?
    let nodeID: String
    let kind: String
    let severity: String
    let summary: String
    let data: [String: JSONValue]
    let deviceID: String?
    let signal: SignalMeta

    init(from canonical: CanonicalEvent) {
        data = canonical.data
        kind = canonical.kind
        nodeID = canonical.nodeID
        severity = canonical.severity
        summary = canonical.summary
        recvTs = Date(timeIntervalSince1970: TimeInterval(canonical.recvTs / 1000))
        eventTs = DateParser.parse(canonical.eventTs)
        let strength = SignalMeta.extractStrength(from: data)
        let channel = SignalMeta.extractChannel(from: data)
        let tags = SignalMeta.tags(from: kind)
        deviceID = SignalMeta.deviceID(from: data, kind: kind, nodeID: nodeID)
        signal = SignalMeta(strength: strength, channel: channel, tags: tags)
        if let id = canonical.id, !id.isEmpty {
            self.id = id
        } else {
            self.id = NormalizedEvent.deriveID(node: nodeID, kind: kind, ts: eventTs ?? recvTs, data: data)
        }
    }

    func dataValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = data[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func deriveID(node: String, kind: String, ts: Date?, data: [String: JSONValue]) -> String {
        let base = "\(node)|\(kind)|\(ts?.timeIntervalSince1970 ?? 0)"
        let hash = data.map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: "|")
        return "derived-\(base.hashValue)-\(hash.hashValue)"
    }
}

struct SignalMeta: Hashable {
    let strength: Double?
    let channel: String?
    let tags: [String]

    static func extractStrength(from data: [String: JSONValue]) -> Double? {
        let keys = ["rssi", "RSSI", "signal", "strength", "dbm", "level"]
        for key in keys {
            if let value = data[key] {
                if let number = value.doubleValue { return number }
                if let str = value.stringValue, let number = Double(str) { return number }
            }
        }
        return nil
    }

    static func extractChannel(from data: [String: JSONValue]) -> String? {
        let keys = ["channel", "ch", "wifi_channel", "ble_channel"]
        for key in keys {
            if let value = data[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func deviceID(from data: [String: JSONValue], kind: String, nodeID: String) -> String? {
        let keys = ["device_id", "deviceId", "device", "addr", "address", "mac", "mac_address", "bssid", "ble_addr"]
        for key in keys {
            if let value = data[key]?.stringValue, !value.isEmpty {
                if kind.contains("ble") {
                    return value.hasPrefix("ble:") ? value : "ble:\(value)"
                }
                return value
            }
        }
        if nodeID != "unknown" {
            return "node:\(nodeID)"
        }
        return nil
    }

    static func tags(from kind: String) -> [String] {
        var tags: [String] = []
        if kind.contains("ble") { tags.append("ble") }
        if kind.contains("wifi") { tags.append("wifi") }
        if kind.contains("node") { tags.append("node") }
        if kind.contains("error") { tags.append("error") }
        return tags
    }
}

struct DateParser {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = iso8601.date(from: string) { return date }
        return fallback.date(from: string)
    }
}

enum JSONValue: Hashable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }
}
