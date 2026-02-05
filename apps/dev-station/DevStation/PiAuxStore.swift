import Foundation
import Network

enum PiAuxKind: String, Codable {
    case ble_rssi
    case wifi_rssi
    case motion
    case audio_level
    case temperature
    case custom
}

struct PiAuxEvent: Codable, Hashable, Identifiable {
    let id: UUID = UUID()
    let deviceID: String
    let timestamp: String
    let kind: PiAuxKind
    let data: [String: String]
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case deviceID
        case timestamp
        case kind
        case data
        case tags
    }
}

@MainActor
final class PiAuxStore: ObservableObject {
    static let shared = PiAuxStore()

    @Published private(set) var events: [PiAuxEvent] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastTriggerMessage: String?
    @Published private(set) var lastPingResult: String?
    @Published private(set) var lastPingError: String?
    @Published private(set) var activeNodes: [NodeRecord] = []
    @Published var plannedNodes: [PlannedNode] = []
    @Published var port: Int
    @Published var token: String

    private let maxEvents = 200
    private let tokenKey = "PiAuxToken"
    private let portKey = "PiAuxPort"
    private let plannedNodesKey = "PlannedNodes"
    private var server: PiAuxServer?
    private var activeByID: [String: NodeRecord] = [:]
    private let localNodeID = "mac-local"

    var localNodeIdentifier: String { localNodeID }
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 5
    private let offlineThreshold: TimeInterval = 30

    private init() {
        let defaults = UserDefaults.standard
        if let token = defaults.string(forKey: tokenKey), !token.isEmpty {
            self.token = token
        } else {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            self.token = token
            defaults.set(token, forKey: tokenKey)
        }
        let savedPort = defaults.integer(forKey: portKey)
        self.port = savedPort > 0 ? savedPort : 8787
        if let data = defaults.data(forKey: plannedNodesKey),
           let decoded = try? JSONDecoder().decode([PlannedNode].self, from: data) {
            self.plannedNodes = decoded
        } else {
            self.plannedNodes = []
        }
        if !plannedNodes.contains(where: { $0.id == "pi-aux" }) {
            plannedNodes.append(PlannedNode(id: "pi-aux", label: "Pi-Aux", type: .piAux, capabilities: ["ble", "wifi", "rf", "gps", "net"]))
            persistPlannedNodes()
        }
        registerLocalNode()
        mergePlannedIntoActive()
        startHeartbeatTimer()
        start()
    }

    func start() {
        stop()
        let server = PiAuxServer(
            host: "127.0.0.1",
            port: port,
            tokenProvider: { [weak self] in self?.token ?? "" },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.append(event: event)
                }
            },
            onStatus: { [weak self] running in
                Task { @MainActor in
                    self?.isRunning = running
                }
            },
            onLog: { level, message in
                LogStore.logAsync(level, message)
            }
        )
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    func connectNode(_ nodeID: String) {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var record = activeByID[trimmed] ?? NodeRecord(
            id: trimmed,
            label: trimmed,
            type: .unknown,
            capabilities: [],
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            planned: false
        )
        record.connectionState = .connected
        record.lastHeartbeat = Date()
        if record.lastSeen == nil { record.lastSeen = Date() }
        activeByID[trimmed] = record
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func setNodeScanning(nodeID: String, enabled: Bool) {
        var record = activeByID[nodeID] ?? NodeRecord(
            id: nodeID,
            label: nodeID,
            type: .unknown,
            capabilities: [],
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            planned: false
        )
        record.isScanning = enabled
        if enabled, record.connectionState == .offline {
            record.connectionState = .idle
        }
        activeByID[nodeID] = record
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.touchHeartbeat(nodeID: self.localNodeID, setConnected: true)
            self.updateConnectionStates()
        }
    }

    private func touchHeartbeat(nodeID: String, setConnected: Bool) {
        var record = activeByID[nodeID] ?? NodeRecord(
            id: nodeID,
            label: nodeID,
            type: .unknown,
            capabilities: [],
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            planned: false
        )
        record.lastHeartbeat = Date()
        if setConnected {
            record.connectionState = .connected
        }
        activeByID[nodeID] = record
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func updateConnectionStates() {
        let now = Date()
        for (id, record) in activeByID {
            var updated = record
            if let lastHeartbeat = record.lastHeartbeat {
                if now.timeIntervalSince(lastHeartbeat) > offlineThreshold {
                    if updated.connectionState != .error {
                        updated.connectionState = .offline
                    }
                } else if updated.connectionState == .offline {
                    updated.connectionState = .idle
                }
            }
            activeByID[id] = updated
        }
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func updatePort(_ newPort: Int) {
        guard newPort > 0 else { return }
        if newPort == port { return }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: portKey)
        start()
    }

    private func append(event: PiAuxEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lastUpdate = Date()
        updateActiveNode(from: event)
    }

    func recentEventCount(window: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-window)
        return events.filter { ISO8601DateFormatter().date(from: $0.timestamp) ?? .distantPast >= cutoff }.count
    }

    func recentEventCount(nodeID: String, window: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-window)
        return events.filter { event in
            let date = ISO8601DateFormatter().date(from: event.timestamp) ?? .distantPast
            guard date >= cutoff else { return false }
            let extracted = extractNodeID(from: event) ?? event.deviceID
            return extracted == nodeID
        }.count
    }

    func triggerScan() -> Bool {
        let message = "Node does not expose scan trigger endpoint."
        lastTriggerMessage = message
        lastError = message
        LogStore.logAsync(.warn, message)
        return false
    }

    func addPlannedNode(id: String, label: String, type: NodeType, capabilities: [String]) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if plannedNodes.contains(where: { $0.id == trimmed }) {
            return
        }
        plannedNodes.append(PlannedNode(id: trimmed, label: label.isEmpty ? trimmed : label, type: type, capabilities: capabilities))
        persistPlannedNodes()
        mergePlannedIntoActive()
    }

    func removePlannedNode(_ node: PlannedNode) {
        plannedNodes.removeAll { $0.id == node.id }
        persistPlannedNodes()
    }

    func updatePlannedNode(_ node: PlannedNode) {
        if let idx = plannedNodes.firstIndex(where: { $0.id == node.id }) {
            plannedNodes[idx] = node
            persistPlannedNodes()
            mergePlannedIntoActive()
        }
    }

    func pingNode(_ nodeID: String) {
        let message = "Node does not expose ping endpoint."
        lastError = message
        LogStore.logAsync(.warn, message)
    }

    func testPing() {
        lastPingResult = nil
        lastPingError = nil
        let pingURL = endpointURL.replacingOccurrences(of: "/api/v1/events", with: "/api/v1/ping")
        guard let url = URL(string: pingURL) else {
            lastPingError = "Invalid endpoint URL."
            LogStore.logAsync(.warn, "Ping failed: invalid endpoint URL")
            return
        }
        Task.detached {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    self.lastPingResult = "HTTP \(status) \(body)"
                    self.lastPingError = nil
                }
                LogStore.logAsync(.info, "Ping OK: HTTP \(status)")
            } catch {
                await MainActor.run {
                    self.lastPingError = error.localizedDescription
                    self.lastPingResult = nil
                }
                LogStore.logAsync(.warn, "Ping failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshLocalNodeHeartbeat() {
        touchHeartbeat(nodeID: localNodeID, setConnected: true)
        mergePlannedIntoActive()
    }

    private func persistPlannedNodes() {
        if let data = try? JSONEncoder().encode(plannedNodes) {
            UserDefaults.standard.set(data, forKey: plannedNodesKey)
        }
    }

    private func updateActiveNode(from event: PiAuxEvent) {
        guard let nodeID = extractNodeID(from: event) else { return }
        let now = Date()
        var record = activeByID[nodeID] ?? NodeRecord(
            id: nodeID,
            label: nodeID,
            type: .unknown,
            capabilities: [],
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            planned: false
        )
        let planned = plannedNodes.first(where: { $0.id == nodeID })
        if let planned {
            record.label = planned.label
            record.type = planned.type
            record.capabilities = planned.capabilities
            record.planned = true
        }
        if let label = extractLabel(from: event), planned == nil {
            record.label = label
        }
        if let type = extractNodeType(from: event), planned == nil || record.type == .unknown {
            record.type = type
        }
        let caps = extractCapabilities(from: event)
        if !caps.isEmpty {
            record.capabilities = Array(Set(record.capabilities + caps)).sorted()
        }
        record.lastSeen = now
        if record.connectionState != .error {
            record.connectionState = .connected
        }
        record.lastHeartbeat = now
        activeByID[nodeID] = record
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func mergePlannedIntoActive() {
        for planned in plannedNodes {
            if activeByID[planned.id] == nil {
                activeByID[planned.id] = NodeRecord(
                    id: planned.id,
                    label: planned.label,
                    type: planned.type,
                    capabilities: planned.capabilities,
                    lastSeen: nil,
                    lastHeartbeat: nil,
                    connectionState: .idle,
                    isScanning: false,
                    lastError: nil,
                    planned: true
                )
            } else {
                var existing = activeByID[planned.id]
                existing?.label = planned.label
                existing?.type = planned.type
                existing?.capabilities = planned.capabilities
                existing?.planned = true
                if let updated = existing {
                    activeByID[planned.id] = updated
                }
            }
        }
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func registerLocalNode() {
        let record = NodeRecord(
            id: localNodeID,
            label: "Dev Station",
            type: .mac,
            capabilities: ["net", "ble", "scan", "report"],
            lastSeen: Date(),
            lastHeartbeat: Date(),
            connectionState: .connected,
            isScanning: false,
            lastError: nil,
            planned: true
        )
        activeByID[localNodeID] = record
    }

    private func extractNodeID(from event: PiAuxEvent) -> String? {
        if let direct = event.data["nodeId"] ?? event.data["node_id"] {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in event.tags {
            if tag.lowercased().hasPrefix("nodeid:") {
                return String(tag.dropFirst("nodeid:".count))
            }
            if tag.lowercased().hasPrefix("nodeid=") {
                return String(tag.dropFirst("nodeid=".count))
            }
        }
        return event.deviceID.isEmpty ? nil : event.deviceID
    }

    private func extractLabel(from event: PiAuxEvent) -> String? {
        if let label = event.data["nodeLabel"] ?? event.data["label"] {
            return label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in event.tags {
            if tag.lowercased().hasPrefix("label:") {
                return String(tag.dropFirst("label:".count))
            }
        }
        return nil
    }

    private func extractNodeType(from event: PiAuxEvent) -> NodeType? {
        if let raw = event.data["nodeType"] ?? event.data["type"] {
            return parseNodeType(raw)
        }
        for tag in event.tags {
            if tag.lowercased().hasPrefix("nodetype:") {
                return parseNodeType(String(tag.dropFirst("nodetype:".count)))
            }
            if tag.lowercased().hasPrefix("type:") {
                return parseNodeType(String(tag.dropFirst("type:".count)))
            }
        }
        return nil
    }

    private func parseNodeType(_ raw: String) -> NodeType {
        switch raw.lowercased() {
        case "mac", "dev-station", "devstation", "station", "sods":
            return .mac
        case "pi-aux", "piaux", "pi":
            return .piAux
        case "esp32", "esp", "c3", "p4":
            return .esp32
        case "sdr":
            return .sdr
        case "gps":
            return .gps
        default:
            return .unknown
        }
    }

    private func extractCapabilities(from event: PiAuxEvent) -> [String] {
        var caps: [String] = []
        if let raw = event.data["capabilities"] {
            caps.append(contentsOf: raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        for tag in event.tags {
            let lower = tag.lowercased()
            if lower.hasPrefix("cap:") {
                caps.append(String(tag.dropFirst("cap:".count)))
            }
        }
        return caps.filter { !$0.isEmpty }
    }

    var endpointURL: String {
        "http://127.0.0.1:\(port)/api/v1/events"
    }
}

final class PiAuxServer {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let tokenProvider: () -> String
    private let onEvent: (PiAuxEvent) -> Void
    private let onStatus: (Bool) -> Void
    private let onLog: (LogLevel, String) -> Void
    private let queue = DispatchQueue(label: "PiAuxServer.queue", qos: .utility)

    private var listener: NWListener?

    init(host: String, port: Int, tokenProvider: @escaping () -> String, onEvent: @escaping (PiAuxEvent) -> Void, onStatus: @escaping (Bool) -> Void, onLog: @escaping (LogLevel, String) -> Void) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8787
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
        self.onStatus = onStatus
        self.onLog = onLog
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: port)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus(true)
                    self?.onLog(.info, "Pi-Aux server listening on 127.0.0.1:\(self?.port.rawValue ?? 0)")
                case .failed(let error):
                    self?.onStatus(false)
                    self?.onLog(.error, "Pi-Aux server failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.onStatus(false)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            onStatus(false)
            onLog(.error, "Pi-Aux server start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        if case let NWEndpoint.hostPort(host, _) = connection.endpoint {
            let hostString = host.debugDescription
            if hostString != "127.0.0.1" && hostString != "::1" && hostString != "localhost" {
                onLog(.warn, "Pi-Aux rejected non-local connection from \(hostString)")
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        let handler = PiAuxConnectionHandler(
            connection: connection,
            tokenProvider: tokenProvider,
            onEvent: onEvent,
            onLog: onLog
        )
        handler.start()
    }
}

final class PiAuxConnectionHandler {
    private let connection: NWConnection
    private let tokenProvider: () -> String
    private let onEvent: (PiAuxEvent) -> Void
    private let onLog: (LogLevel, String) -> Void
    private var buffer = Data()

    init(connection: NWConnection, tokenProvider: @escaping () -> String, onEvent: @escaping (PiAuxEvent) -> Void, onLog: @escaping (LogLevel, String) -> Void) {
        self.connection = connection
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
        self.onLog = onLog
    }

    func start() {
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let response = self.tryHandleRequest() {
                self.send(response)
                return
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receiveNext()
        }
    }

    private func tryHandleRequest() -> Data? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        let bodyStart = headerRange.upperBound
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return response(status: 400, body: "Invalid headers")
        }
        let lines = headerText.split(separator: "\r\n")
        guard let requestLine = lines.first else { return response(status: 400, body: "Bad request") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return response(status: 400, body: "Bad request") }
        let method = parts[0].uppercased()
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBody = buffer.count - bodyStart
        if availableBody < contentLength { return nil }
        let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        if method == "GET" && path == "/api/v1/ping" {
            return response(status: 200, body: "OK")
        }
        if method != "POST" || path != "/api/v1/events" {
            return response(status: 404, body: "Not found")
        }
        let token = headers["x-sods-token"] ?? ""
        if token != tokenProvider() {
            onLog(.warn, "Pi-Aux rejected request: invalid token")
            return response(status: 401, body: "Unauthorized")
        }

        do {
            let decoder = JSONDecoder()
            let event = try decoder.decode(PiAuxEvent.self, from: bodyData)
            onEvent(event)
            onLog(.info, "Pi-Aux event received: \(event.kind.rawValue) device=\(event.deviceID)")
            return response(status: 200, body: "OK")
        } catch {
            onLog(.warn, "Pi-Aux invalid JSON: \(error.localizedDescription)")
            return response(status: 400, body: "Invalid JSON")
        }
    }

    private func response(status: Int, body: String) -> Data {
        let text = "HTTP/1.1 \(status) OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        return Data(text.utf8)
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
