import Foundation

@MainActor
final class NodeRegistry: ObservableObject {
    static let shared = NodeRegistry()

    struct ManualRegisterResult {
        let nodeID: String?
        let error: String?
    }

    @Published private(set) var nodes: [NodeRecord] = []
    @Published private(set) var connectingNodeIDs: Set<String> = []

    private var nodesByID: [String: NodeRecord] = [:]
    private let fileURL: URL
    private let offlineThreshold: TimeInterval = 30
    private var stalenessTimer: Timer?

    private init() {
        let dir = StoragePaths.workspaceSubdir("registry")
        fileURL = dir.appendingPathComponent("nodes.json")
        load()
        startStalenessTimer()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            nodesByID = [:]
            nodes = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(NodeRegistryPayload.self, from: data)
            let records = payload.nodes
            nodesByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            refreshNodes()
        } catch {
            LogStore.logAsync(.error, "Node registry load failed: \(error.localizedDescription)")
            nodesByID = [:]
            nodes = []
        }
    }

    func register(nodeID: String, label: String?, hostname: String?, ip: String?, mac: String?, type: NodeType?, capabilities: [String]) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        let normalizedLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let record = NodeRecord(
            id: trimmedID,
            label: normalizedLabel.isEmpty ? trimmedID : normalizedLabel,
            type: type ?? .unknown,
            capabilities: capabilities,
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: .offline,
            isScanning: false,
            lastError: nil,
            ip: ip,
            hostname: hostname,
            mac: mac
        )
        upsert(record, allowStateUpdate: false)
    }

    func observe(_ record: NodeRecord) {
        upsert(record, allowStateUpdate: true)
    }

    func updateFromPresence(_ presence: [String: NodePresence]) {
        var changed = false
        for item in presence.values {
            let nodeID = item.nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nodeID.isEmpty else { continue }
            if item.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "connecting" {
                setConnecting(nodeID: nodeID, connecting: false)
            }
            guard let existing = nodesByID[nodeID] else { continue }
            let nextLabel = existing.label.isEmpty == false ? existing.label : (item.hostname ?? item.ip ?? nodeID)
            var merged = existing

            if let nextLabel, !nextLabel.isEmpty, nextLabel != merged.label {
                merged.label = nextLabel
            }
            if let host = item.hostname, !host.isEmpty { merged.hostname = host }
            if let ip = item.ip, !ip.isEmpty { merged.ip = ip }
            if let mac = item.mac, !mac.isEmpty { merged.mac = mac }
            if item.lastSeen > 0 {
                merged.lastSeen = Date(timeIntervalSince1970: TimeInterval(item.lastSeen) / 1000.0)
            }
            if let lastError = item.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
                merged.lastError = lastError
            } else if item.state == "online" || item.state == "idle" {
                merged.lastError = nil
            }

            let mapped = mapPresenceState(item.state)
            if mapped.connectionState != nil {
                merged.connectionState = mapped.connectionState ?? merged.connectionState
            }
            merged.isScanning = mapped.isScanning ?? merged.isScanning

            if let caps = capabilitiesFromPresence(item.capabilities) {
                merged.capabilities = Array(Set(merged.capabilities + caps)).sorted()
            }

            if existing != merged {
                nodesByID[nodeID] = merged
                changed = true
            }
        }
        if changed {
            refreshNodes()
            persist()
        }
    }

    func recordLastError(nodeID: String, message: String?) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        guard var record = nodesByID[trimmedID] else { return }
        let cleaned = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned?.isEmpty == false {
            record.lastError = cleaned
        }
        nodesByID[trimmedID] = record
        refreshNodes()
        persist()
        setConnecting(nodeID: trimmedID, connecting: false)
    }

    func clearLastError(nodeID: String) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        guard var record = nodesByID[trimmedID] else { return }
        if record.lastError != nil {
            record.lastError = nil
            nodesByID[trimmedID] = record
            refreshNodes()
            persist()
        }
        setConnecting(nodeID: trimmedID, connecting: false)
    }

    func setConnecting(nodeID: String, connecting: Bool) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        if connecting {
            if !connectingNodeIDs.contains(trimmedID) {
                connectingNodeIDs.insert(trimmedID)
            }
        } else {
            if connectingNodeIDs.remove(trimmedID) != nil {
                // state updated
            }
        }
    }

    func registerFromWhoami(host: String?, payload: WhoamiPayload, preferredLabel: String?) -> String? {
        guard let nodeID = payload.resolvedNodeID?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeID.isEmpty else {
            return nil
        }
        let nextLabel = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (nextLabel?.isEmpty == false ? nextLabel : payload.resolvedLabel) ?? nodeID
        let type = nodeType(from: payload)
        let record = NodeRecord(
            id: nodeID,
            label: label,
            type: type,
            capabilities: [],
            lastSeen: Date(),
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            ip: payload.ip ?? host,
            hostname: payload.hostname,
            mac: payload.mac
        )
        upsert(record, allowStateUpdate: true)
        return nodeID
    }

    @discardableResult
    func claimFromPresence(_ presence: NodePresence, preferredLabel: String?) -> NodeRecord? {
        let trimmedID = presence.nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID: String = {
            if !trimmedID.isEmpty { return trimmedID }
            let base = presence.mac?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? presence.ip?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "node"
            let stamp = presence.lastSeen > 0 ? "\(presence.lastSeen)" : "\(Int(Date().timeIntervalSince1970 * 1000))"
            return "\(base)-\(stamp)"
        }()
        guard !resolvedID.isEmpty else { return nil }

        let nextLabel = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (nextLabel?.isEmpty == false ? nextLabel : (presence.hostname ?? presence.ip ?? resolvedID)) ?? resolvedID
        let mapped = mapPresenceState(presence.state)
        var record = NodeRecord(
            id: resolvedID,
            label: label,
            type: .unknown,
            capabilities: [],
            lastSeen: nil,
            lastHeartbeat: nil,
            connectionState: mapped.connectionState ?? .offline,
            isScanning: mapped.isScanning ?? false,
            lastError: presence.lastError,
            ip: presence.ip,
            hostname: presence.hostname,
            mac: presence.mac
        )
        if presence.lastSeen > 0 {
            record.lastSeen = Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000.0)
        }
        if let caps = capabilitiesFromPresence(presence.capabilities) {
            record.capabilities = caps
        }
        upsert(record, allowStateUpdate: true)
        return nodesByID[resolvedID]
    }

    func registerFromHost(_ host: String, preferredLabel: String?) async -> ManualRegisterResult {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ManualRegisterResult(nodeID: nil, error: "Enter a host or IP address.") }
        let urlString = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: "\(urlString)/whoami") else {
            return ManualRegisterResult(nodeID: nil, error: "Invalid host.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status >= 200 && status < 300 else {
                return ManualRegisterResult(nodeID: nil, error: "Whoami failed: HTTP \(status)")
            }
            let text = String(data: data, encoding: .utf8)
            guard let payload = WhoamiParser.parse(text) else {
                return ManualRegisterResult(nodeID: nil, error: "Whoami returned unreadable payload.")
            }
            guard let nodeID = registerFromWhoami(host: trimmed, payload: payload, preferredLabel: preferredLabel) else {
                return ManualRegisterResult(nodeID: nil, error: "Whoami did not include node identity.")
            }
            return ManualRegisterResult(nodeID: nodeID, error: nil)
        } catch {
            return ManualRegisterResult(nodeID: nil, error: "Whoami failed: \(error.localizedDescription)")
        }
    }

    private func upsert(_ record: NodeRecord, allowStateUpdate: Bool) {
        let trimmedID = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        let existing = nodesByID[trimmedID]
        var merged = existing ?? record

        if record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            merged.label = record.label
        }
        if record.type != .unknown {
            merged.type = record.type
        }
        if !record.capabilities.isEmpty {
            merged.capabilities = Array(Set(merged.capabilities + record.capabilities)).sorted()
        }
        if let lastSeen = record.lastSeen { merged.lastSeen = lastSeen }
        if let lastHeartbeat = record.lastHeartbeat { merged.lastHeartbeat = lastHeartbeat }
        if allowStateUpdate {
            merged.connectionState = record.connectionState
            merged.isScanning = record.isScanning
        }
        if let lastError = record.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            merged.lastError = lastError
        }
        if let ip = record.ip, !ip.isEmpty { merged.ip = ip }
        if let hostname = record.hostname, !hostname.isEmpty { merged.hostname = hostname }
        if let mac = record.mac, !mac.isEmpty { merged.mac = mac }

        if existing == nil || existing != merged {
            nodesByID[trimmedID] = merged
            refreshNodes()
            persist()
        }
    }

    private func refreshNodes() {
        nodes = nodesByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = NodeRegistryPayload(nodes: nodes)
            let data = try encoder.encode(payload)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)
        } catch {
            LogStore.logAsync(.error, "Node registry save failed: \(error.localizedDescription)")
        }
    }

    private func startStalenessTimer() {
        stalenessTimer?.invalidate()
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateStaleness()
        }
    }

    private func updateStaleness() {
        let now = Date()
        var changed = false
        for (id, record) in nodesByID {
            guard let lastSeen = record.lastSeen else { continue }
            if now.timeIntervalSince(lastSeen) > offlineThreshold, record.connectionState != .offline, record.connectionState != .error {
                var updated = record
                updated.connectionState = .offline
                nodesByID[id] = updated
                changed = true
            }
        }
        if changed {
            refreshNodes()
            persist()
        }
    }

    private func mapPresenceState(_ state: String) -> (connectionState: NodeConnectionState?, isScanning: Bool?) {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "online":
            return (.connected, false)
        case "idle":
            return (.idle, false)
        case "scanning":
            return (.idle, true)
        case "offline":
            return (.offline, false)
        case "error":
            return (.error, false)
        default:
            return (nil, nil)
        }
    }

    private func capabilitiesFromPresence(_ caps: NodeCapabilities) -> [String]? {
        var out: [String] = []
        if caps.canScanWifi == true || caps.canScanBle == true { out.append("scan") }
        if caps.canFrames == true { out.append("frames") }
        if caps.canFlash == true { out.append("flash") }
        if caps.canWhoami == true { out.append("identify") }
        return out.isEmpty ? nil : out
    }

    private func nodeType(from payload: WhoamiPayload) -> NodeType {
        if let chip = payload.chip?.lowercased() {
            if chip.contains("esp32") { return .esp32 }
        }
        return .unknown
    }
}

struct NodeRegistryPayload: Codable {
    let version: String
    let nodes: [NodeRecord]

    init(nodes: [NodeRecord]) {
        self.version = "1.0"
        self.nodes = nodes
    }
}
