import Foundation
import Network
import Darwin

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
    @Published var port: Int
    @Published var token: String

    private let maxEvents = 200
    private let tokenKey = "PiAuxToken"
    private let portKey = "PiAuxPort"
    private let preferredControlNodeIDKey = "PiAuxPreferredControlNodeID"
    private var server: PiAuxServer?
    private var activeByID: [String: NodeRecord] = [:]

    var localNodeIdentifier: String { controlNodeIdentifier }
    var controlNodeIdentifier: String {
        preferredControlNodeID()
    }
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
        let candidatePort = savedPort > 0 ? savedPort : 8787
        let resolvedPort = Self.resolvePortConflict(candidatePort)
        self.port = resolvedPort
        if resolvedPort != candidatePort {
            defaults.set(resolvedPort, forKey: portKey)
            LogStore.logAsync(.warn, "Pi-Aux port \(candidatePort) conflicts with station port; using \(resolvedPort)")
        }
        startHeartbeatTimer()
        start()
    }

    func start() {
        stop()
        let advertisedHost = resolveAdvertisedHost()
        let server = PiAuxServer(
            host: "0.0.0.0",
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
            },
            advertisedHost: advertisedHost
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
        guard activeByID[trimmed] != nil else { return }
        rememberPreferredControlNodeID(trimmed)
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func setNodeScanning(nodeID: String, enabled: Bool) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        guard var record = activeByID[trimmedID] else { return }
        record.isScanning = enabled
        record.lastSeen = Date()
        if enabled, record.connectionState == .offline {
            record.connectionState = .idle
        }
        if !record.capabilities.contains("scan") {
            record.capabilities = Array(Set(record.capabilities + ["scan"])).sorted()
        }
        activeByID[trimmedID] = record
        if enabled {
            rememberPreferredControlNodeID(trimmedID)
        }
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateConnectionStates()
            }
        }
    }

    private func touchHeartbeat(nodeID: String, setConnected: Bool) {
        guard var record = activeByID[nodeID] else { return }
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
        let resolved = Self.resolvePortConflict(newPort)
        if resolved == port { return }
        port = resolved
        UserDefaults.standard.set(resolved, forKey: portKey)
        if resolved != newPort {
            lastError = "Port \(newPort) conflicts with station port. Switched to \(resolved)."
            LogStore.logAsync(.warn, "Pi-Aux port conflict: requested \(newPort), using \(resolved)")
        }
        start()
    }

    private static func resolvePortConflict(_ requestedPort: Int) -> Int {
        guard requestedPort > 0 else { return 8787 }
        let stationBase = StationEndpointResolver.stationBaseURL()
        let stationPort: Int = {
            if let components = URLComponents(string: stationBase), let p = components.port {
                return p
            }
            if stationBase.lowercased().hasPrefix("https://") { return 443 }
            return 80
        }()
        if requestedPort == stationPort {
            return stationPort == 8787 ? 8788 : 8787
        }
        return requestedPort
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
        let nodeID = controlNodeIdentifier
        guard activeByID[nodeID] != nil else { return }
        touchHeartbeat(nodeID: nodeID, setConnected: false)
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
            ip: nil,
            hostname: nil,
            mac: nil
        )
        if let label = extractLabel(from: event) {
            record.label = label
        }
        if let type = extractNodeType(from: event), record.type == .unknown {
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
        let preferred = UserDefaults.standard.string(forKey: preferredControlNodeIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preferred.isEmpty {
            rememberPreferredControlNodeID(nodeID)
        }
        activeNodes = activeByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func extractNodeID(from event: PiAuxEvent) -> String? {
        if let direct = event.data["nodeId"] ?? event.data["node_id"] {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        for tag in event.tags {
            if tag.lowercased().hasPrefix("nodeid:") {
                let value = String(tag.dropFirst("nodeid:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            if tag.lowercased().hasPrefix("nodeid=") {
                let value = String(tag.dropFirst("nodeid=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        let fallback = event.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
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
        "http://\(resolveAdvertisedHost()):\(port)/api/v1/events"
    }

    private func resolveAdvertisedHost() -> String {
        let stationBase = StationEndpointResolver.stationBaseURL()
        if let components = URLComponents(string: stationBase),
           let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            let lowered = host.lowercased()
            if lowered != "127.0.0.1" && lowered != "localhost" && lowered != "::1" {
                return host
            }
        }
        if let subnet = IPv4Subnet.active() {
            return subnet.addressString
        }
        return "127.0.0.1"
    }

    private func preferredControlNodeID() -> String {
        let preferred = UserDefaults.standard.string(forKey: preferredControlNodeIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferred.isEmpty,
           activeByID[preferred] != nil || NodeRegistry.shared.nodes.contains(where: { $0.id == preferred }) {
            return preferred
        }
        if let claimedPiAux = NodeRegistry.shared.nodes.first(where: { $0.type == .piAux }) {
            return claimedPiAux.id
        }
        if let claimedScanner = NodeRegistry.shared.nodes.first(where: { $0.capabilities.contains("scan") }) {
            return claimedScanner.id
        }
        if let activePiAux = activeByID.values
            .sorted(by: { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) })
            .first(where: { $0.type == .piAux }) {
            return activePiAux.id
        }
        if let activeScanner = activeByID.values
            .sorted(by: { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) })
            .first(where: { $0.capabilities.contains("scan") }) {
            return activeScanner.id
        }
        if let firstClaimed = NodeRegistry.shared.nodes.first {
            return firstClaimed.id
        }
        if let firstActive = activeByID.values
            .sorted(by: { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) })
            .first {
            return firstActive.id
        }
        return NodeType.unknown.rawValue
    }

    private func rememberPreferredControlNodeID(_ nodeID: String) {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: preferredControlNodeIDKey)
    }
}

final class PiAuxServer {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let tokenProvider: () -> String
    private let onEvent: (PiAuxEvent) -> Void
    private let onStatus: (Bool) -> Void
    private let onLog: (LogLevel, String) -> Void
    private let advertisedHost: String
    private let queue = DispatchQueue(label: "PiAuxServer.queue", qos: .utility)

    private var listener: NWListener?

    init(host: String, port: Int, tokenProvider: @escaping () -> String, onEvent: @escaping (PiAuxEvent) -> Void, onStatus: @escaping (Bool) -> Void, onLog: @escaping (LogLevel, String) -> Void, advertisedHost: String) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8787
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
        self.onStatus = onStatus
        self.onLog = onLog
        self.advertisedHost = advertisedHost
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
                    self?.onLog(.info, "Pi-Aux server listening on \(self?.advertisedHost ?? "127.0.0.1"):\(self?.port.rawValue ?? 0)")
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
