import Foundation
import AppKit

@MainActor
final class SODSStore: ObservableObject {
    static let shared = SODSStore()

    @Published private(set) var events: [NormalizedEvent] = []
    @Published private(set) var frames: [SignalFrame] = []
    @Published private(set) var nodes: [SignalNode] = []
    @Published private(set) var nodePresence: [String: NodePresence] = [:]
    @Published private(set) var health: APIHealth = .offline
    @Published private(set) var lastError: String?
    @Published private(set) var lastPoll: Date?
    @Published private(set) var lastFramesAt: Date?
    @Published private(set) var stationStatus: StationStatus?
    @Published private(set) var loggerStatus: LoggerStatus?
    @Published private(set) var realFramesActive: Bool = false
    @Published var baseURL: String
    @Published private(set) var baseURLError: String?
    @Published var isRecording: Bool = false
    @Published private(set) var recordedEvents: [NormalizedEvent] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var aliasOverrides: [String: String] = [:]

    private let baseURLKey = "SODSBaseURL"

    private var wsTask: URLSessionWebSocketTask?
    private var wsFramesTask: URLSessionWebSocketTask?
    private var pollTimer: Timer?
    private var maxEvents = 1200
    private let aliasOverridesKey = "SODSAliasOverrides"

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: baseURLKey), !saved.isEmpty {
            let validated = normalizeBaseURL(saved)
            if let url = validated.url {
                baseURL = url
                baseURLError = nil
            } else {
                baseURL = "http://localhost:9123"
                baseURLError = validated.error
                defaults.set(baseURL, forKey: baseURLKey)
            }
        } else {
            baseURL = "http://localhost:9123"
            defaults.set(baseURL, forKey: baseURLKey)
        }
        StationProcessManager.shared.ensureRunning(baseURL: baseURL)
        if let saved = defaults.dictionary(forKey: aliasOverridesKey) as? [String: String] {
            aliasOverrides = saved
            IdentityResolver.shared.updateOverrides(aliasOverrides)
        }
        connect()
    }

    @discardableResult
    func updateBaseURL(_ value: String) -> Bool {
        let validated = normalizeBaseURL(value)
        guard let url = validated.url else {
            baseURLError = validated.error ?? "Invalid base URL."
            return false
        }
        baseURLError = nil
        baseURL = url
        UserDefaults.standard.set(url, forKey: baseURLKey)
        StationProcessManager.shared.ensureRunning(baseURL: baseURL)
        connect()
        return true
    }

    func connect() {
        wsTask?.cancel()
        wsTask = nil
        wsFramesTask?.cancel()
        wsFramesTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        events.removeAll()
        frames.removeAll()
        connectWebSocket()
        connectFramesWebSocket()
        schedulePoll()
    }

    private func schedulePoll() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.pollStatusAndNodes() }
        }
        Task { await pollStatusAndNodes() }
    }

    private func connectWebSocket() {
        guard let finalURL = makeWebSocketURL(path: "/ws/events") else { return }
        let task = URLSession.shared.webSocketTask(with: finalURL)
        wsTask = task
        task.resume()
        receiveLoop()
    }

    private func connectFramesWebSocket() {
        guard let finalURL = makeWebSocketURL(path: "/ws/frames") else { return }
        let task = URLSession.shared.webSocketTask(with: finalURL)
        wsFramesTask = task
        task.resume()
        receiveFramesLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
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
    }

    private func receiveFramesLoop() {
        wsFramesTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    break
                case .success(let message):
                    self.handleFrames(message: message)
                }
                self.receiveFramesLoop()
            }
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

    private func handleFrames(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8) {
                decodeFrames(data)
            }
        case .data(let data):
            decodeFrames(data)
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
            if isRecording {
                recordedEvents.append(normalized)
                if recordedEvents.count > maxEvents * 5 {
                    recordedEvents.removeFirst(recordedEvents.count - maxEvents * 5)
                }
            }
            if events.count > maxEvents {
                events.removeFirst(events.count - maxEvents)
            }
            lastPoll = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func decodeFrames(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(SignalFrameEnvelope.self, from: data)
            frames = payload.frames
            lastFramesAt = Date()
            realFramesActive = true
            scheduleRealFramesDecayCheck()
        } catch {
            // ignore frame decode errors
        }
    }

    private func scheduleRealFramesDecayCheck() {
        let timestamp = lastFramesAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.lastFramesAt == timestamp else { return }
            self.realFramesActive = false
        }
    }

    func startRecording() {
        if !isRecording {
            recordedEvents.removeAll()
            recordingStartedAt = Date()
        }
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    func clearRecording() {
        recordedEvents.removeAll()
        recordingStartedAt = nil
    }

    func saveRecording(to url: URL) -> Bool {
        let encoder = JSONEncoder()
        var lines: [String] = []
        for event in recordedEvents {
            let payload: [String: Any] = [
                "recv_ts": Int(event.recvTs?.timeIntervalSince1970 ?? 0) * 1000,
                "event_ts": isoString(from: event.eventTs),
                "node_id": event.nodeID,
                "kind": event.kind,
                "severity": event.severity,
                "summary": event.summary,
                "data": jsonObject(from: event.data)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func loadRecording(from url: URL) -> Bool {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let decoder = JSONDecoder()
            var loaded: [NormalizedEvent] = []
            for line in contents.split(separator: "\n") {
                guard let data = line.data(using: .utf8) else { continue }
                if let entry = try? decoder.decode(RecordedEventLine.self, from: data) {
                    let canonical = CanonicalEvent(
                        id: entry.id,
                        recvTs: entry.recvTs ?? 0,
                        eventTs: entry.eventTs ?? "",
                        nodeID: entry.nodeID,
                        kind: entry.kind,
                        severity: entry.severity ?? "info",
                        summary: entry.summary ?? entry.kind,
                        data: entry.data ?? [:]
                    )
                    loaded.append(NormalizedEvent(from: canonical))
                }
            }
            recordedEvents = loaded
            recordingStartedAt = Date()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func isoString(from date: Date?) -> String {
        guard let date else { return ISO8601DateFormatter().string(from: Date()) }
        return ISO8601DateFormatter().string(from: date)
    }

    private func jsonObject(from dict: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            out[key] = jsonObject(from: value)
        }
        return out
    }

    private func jsonObject(from value: JSONValue) -> Any {
        switch value {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return jsonObject(from: v)
        case .array(let v): return v.map { jsonObject(from: $0) }
        case .null: return NSNull()
        }
    }

    private func pollStatusAndNodes() async {
        do {
            let statusURL = makeURL(path: "/api/status")
            let nodesURL = makeURL(path: "/api/nodes")
            guard let statusURL, let nodesURL else { return }

            async let statusReq = URLSession.shared.data(from: statusURL)
            async let nodesReq = URLSession.shared.data(from: nodesURL)

            let (statusData, _) = try await statusReq
            let (nodesData, _) = try await nodesReq

            let decoder = JSONDecoder()
            let statusPayload = try decoder.decode(StationStatusEnvelope.self, from: statusData)
            let nodesPayload = try decoder.decode(NodePresenceEnvelope.self, from: nodesData)

            health = statusPayload.station.ok ? .connected : .degraded
            lastError = nil
            stationStatus = statusPayload.station
            loggerStatus = statusPayload.logger
            nodePresence = Dictionary(uniqueKeysWithValues: nodesPayload.items.map { ($0.nodeID, $0) })
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
            health = .offline
        }
    }

    func openEndpoint(for node: SignalNode, path: String) {
        guard let ip = node.ip, !ip.isEmpty else { return }
        guard let url = URL(string: "http://\(ip)\(path)") else { return }
        NotificationCenter.default.post(name: .sodsOpenURLInApp, object: url)
    }

    func connectNode(_ nodeID: String) {
        guard let url = makeURL(path: "/api/node/connect") else { return }
        lastError = nil
        let payload = ["node_id": nodeID]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: error.localizedDescription)
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async {
                    self?.lastError = "connect failed: no response"
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: "connect failed: no response")
                }
                return
            }
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = result["ok"] as? Bool, !ok {
                let error = result["error"] as? String ?? "connect failed"
                DispatchQueue.main.async {
                    self?.lastError = error
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: error)
                }
            } else {
                DispatchQueue.main.async {
                    NodeRegistry.shared.clearLastError(nodeID: nodeID)
                    self?.refreshStatus()
                }
            }
        }.resume()
    }

    func refreshStatus() {
        Task { await pollStatusAndNodes() }
    }

    func identifyNode(_ nodeID: String) {
        guard let url = makeURL(path: "/api/node/identify") else { return }
        let payload = ["node_id": nodeID]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: error.localizedDescription)
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async {
                    self?.lastError = "identify failed: no response"
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: "identify failed: no response")
                }
                return
            }
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = result["ok"] as? Bool, !ok {
                let error = result["error"] as? String ?? "identify failed"
                DispatchQueue.main.async {
                    self?.lastError = error
                    NodeRegistry.shared.recordLastError(nodeID: nodeID, message: error)
                }
            } else {
                DispatchQueue.main.async {
                    NodeRegistry.shared.clearLastError(nodeID: nodeID)
                }
            }
        }.resume()
    }

    func setAlias(id: String, alias: String) {
        guard let url = makeURL(path: "/api/aliases/user/set") else { return }
        let payload = ["id": id, "alias": alias]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
        aliasOverrides[id] = alias
        UserDefaults.standard.set(aliasOverrides, forKey: aliasOverridesKey)
        IdentityResolver.shared.updateOverrides(aliasOverrides)
    }

    func deleteAlias(id: String) {
        guard let url = makeURL(path: "/api/aliases/user/delete") else { return }
        let payload = ["id": id]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
        aliasOverrides.removeValue(forKey: id)
        UserDefaults.standard.set(aliasOverrides, forKey: aliasOverridesKey)
        IdentityResolver.shared.updateOverrides(aliasOverrides)
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

    private func normalizeBaseURL(_ value: String) -> (url: String?, error: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, "Base URL is required.")
        }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            return (nil, "Base URL is invalid.")
        }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return (nil, "Base URL must start with http:// or https://")
        }
        guard let host = components.host, !host.isEmpty else {
            return (nil, "Base URL must include a host.")
        }
        if components.path == "/" {
            components.path = ""
        }
        let normalized = components.url?.absoluteString ?? candidate
        if normalized.contains("rtsp://") || normalized.contains("ws://") || normalized.contains("wss://") {
            return (nil, "Base URL must use http:// or https:// only.")
        }
        return (normalized, nil)
    }

    private func makeWebSocketURL(path: String) -> URL? {
        guard let httpURL = makeURL(path: path),
              var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let scheme = components.scheme?.lowercased()
        switch scheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            lastError = "Invalid station URL scheme for WebSocket: \(httpURL.absoluteString)"
            health = .offline
            return nil
        }
        guard let finalURL = components.url else {
            lastError = "Invalid WebSocket URL: \(httpURL.absoluteString)"
            health = .offline
            return nil
        }
        return finalURL
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

struct StationStatusEnvelope: Decodable {
    let station: StationStatus
    let logger: LoggerStatus
}

struct StationStatus: Decodable {
    let ok: Bool
    let uptimeMs: Int?
    let lastIngestMs: Int?
    let lastError: String?
    let piLogger: String?
    let nodesTotal: Int?
    let nodesOnline: Int?
    let tools: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case uptimeMs = "uptime_ms"
        case lastIngestMs = "last_ingest_ms"
        case lastError = "last_error"
        case piLogger = "pi_logger"
        case nodesTotal = "nodes_total"
        case nodesOnline = "nodes_online"
        case tools
    }
}

struct LoggerStatus: Decodable {
    let ok: Bool?
    let status: String?
    let detail: JSONValue?
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

struct RecordedEventLine: Decodable {
    let id: String?
    let recvTs: Int?
    let eventTs: String?
    let nodeID: String
    let kind: String
    let severity: String?
    let summary: String?
    let data: [String: JSONValue]?

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

struct NodePresenceEnvelope: Decodable {
    let items: [NodePresence]
}

struct NodePresence: Decodable, Hashable {
    let nodeID: String
    let state: String
    let lastSeen: Int
    let lastSeenAgeMs: Int?
    let lastError: String?
    let ip: String?
    let mac: String?
    let hostname: String?
    let confidence: Double?
    let capabilities: NodeCapabilities
    let provenanceID: String?
    let lastKind: String?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case state
        case lastSeen = "last_seen"
        case lastSeenAgeMs = "last_seen_age_ms"
        case lastError = "last_error"
        case ip
        case mac
        case hostname
        case confidence
        case capabilities
        case provenanceID = "provenance_id"
        case lastKind = "last_kind"
    }
}

struct NodeCapabilities: Decodable, Hashable {
    let canScanWifi: Bool?
    let canScanBle: Bool?
    let canFrames: Bool?
    let canFlash: Bool?
    let canWhoami: Bool?
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

struct SignalFrameEnvelope: Decodable {
    let t: Int
    let frames: [SignalFrame]
}

struct SignalFrame: Decodable, Hashable {
    let t: Int
    let source: String
    let nodeID: String
    let deviceID: String
    let channel: Int
    let frequency: Int
    let rssi: Double
    let x: Double?
    let y: Double?
    let z: Double?
    let color: FrameColor
    let glow: Double?
    let persistence: Double
    let velocity: Double?
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case t, source, channel, frequency, rssi, x, y, z, color, glow, persistence, velocity, confidence
        case nodeID = "node_id"
        case deviceID = "device_id"
    }
}

struct FrameColor: Decodable, Hashable {
    let h: Double
    let s: Double
    let l: Double
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

    static func deriveID(node: String, kind: String, ts: Date?, data: [String: JSONValue]) -> String {
        let base = "\(node)|\(kind)|\(ts?.timeIntervalSince1970 ?? 0)"
        let hash = data.map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: "|")
        return "derived-\(base.hashValue)-\(hash.hashValue)"
    }
}

extension NormalizedEvent {
    init(localNodeID: String, kind: String, summary: String, data: [String: JSONValue], deviceID: String?, eventTs: Date = Date()) {
        self.nodeID = localNodeID
        self.kind = kind
        self.severity = "info"
        self.summary = summary
        self.data = data
        self.eventTs = eventTs
        self.recvTs = eventTs
        self.deviceID = deviceID
        let strength = SignalMeta.extractStrength(from: data)
        let channel = SignalMeta.extractChannel(from: data)
        let tags = SignalMeta.tags(from: kind)
        self.signal = SignalMeta(strength: strength, channel: channel, tags: tags)
        self.id = NormalizedEvent.deriveID(node: localNodeID, kind: kind, ts: eventTs, data: data)
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
