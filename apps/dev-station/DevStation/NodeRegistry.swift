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
    private let serviceOnlyRegistrationError = "Endpoint identifies as control-plane service, not a device node."
    private let reservedServiceNodeIDs: Set<String> = [
        "god-gateway",
        "gateway",
        "service:god-gateway",
        "service:token",
        "service:ops-feed",
        "service:vault",
        "strangelab-god-gateway",
        "strangelab-token",
        "strangelab-ops-feed",
        "token-server",
        "ops-feed",
        "vault-ingest"
    ]

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
            let prunedServices = pruneServiceOnlyNodes()
            pruneUnresolvableOfflineNodes()
            refreshNodes()
            if prunedServices {
                persist()
            }
        } catch {
            LogStore.logAsync(.error, "Node registry load failed: \(error.localizedDescription)")
            nodesByID = [:]
            nodes = []
        }
    }

    func register(nodeID: String, label: String?, hostname: String?, ip: String?, mac: String?, type: NodeType?, capabilities: [String]) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegistrableNodeID(trimmedID) else { return }
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
            if !isRegistrableNodeID(nodeID) {
                if nodesByID.removeValue(forKey: nodeID) != nil {
                    changed = true
                }
                setConnecting(nodeID: nodeID, connecting: false)
                continue
            }
            let normalizedState = item.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedState != "connecting" {
                setConnecting(nodeID: nodeID, connecting: false)
            }
            let existing = nodesByID[nodeID]
            let fallbackLabel = (item.hostname ?? item.ip ?? nodeID).trimmingCharacters(in: .whitespacesAndNewlines)
            var merged = existing ?? NodeRecord(
                id: nodeID,
                label: fallbackLabel.isEmpty ? nodeID : fallbackLabel,
                type: inferredNodeType(nodeID: nodeID, hostname: item.hostname),
                capabilities: [],
                lastSeen: nil,
                lastHeartbeat: nil,
                connectionState: .offline,
                isScanning: false,
                lastError: nil,
                ip: item.ip,
                hostname: item.hostname,
                mac: item.mac
            )

            if merged.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fallbackLabel.isEmpty {
                merged.label = fallbackLabel
            }
            if let host = item.hostname, !host.isEmpty { merged.hostname = host }
            if let ip = item.ip, !ip.isEmpty { merged.ip = ip }
            if let mac = item.mac, !mac.isEmpty { merged.mac = mac }
            if item.lastSeen > 0 {
                merged.lastSeen = Date(timeIntervalSince1970: TimeInterval(item.lastSeen) / 1000.0)
            }
            if let lastError = item.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
                merged.lastError = lastError
            } else if normalizedState == "online" || normalizedState == "idle" {
                merged.lastError = nil
            }

            let mapped = mapPresenceState(normalizedState)
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

    @discardableResult
    func ensureCoreNodes(presence: [String: NodePresence], fleetStatusFileURL: URL? = nil) -> Bool {
        let fleetHints = loadFleetCoreHints(fileURL: fleetStatusFileURL ?? Self.defaultFleetStatusFileURL())
        var changed = false

        for core in coreSeeds(presence: presence, fleetHints: fleetHints) {
            let id = core.id
            guard !id.isEmpty else { continue }
            if let existing = nodesByID[id] {
                var merged = existing
                if merged.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.label = core.label
                }
                if merged.type == .unknown, core.type != .unknown {
                    merged.type = core.type
                }
                if let host = core.hostname, !host.isEmpty, (merged.hostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.hostname = host
                }
                if let ip = core.ip, !ip.isEmpty, (merged.ip ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.ip = ip
                }
                if let mac = core.mac, !mac.isEmpty, (merged.mac ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.mac = mac
                }
                if !core.capabilities.isEmpty {
                    merged.capabilities = Array(Set(merged.capabilities + core.capabilities)).sorted()
                }
                if merged.lastSeen == nil, let seen = core.lastSeen {
                    merged.lastSeen = seen
                }
                if merged.lastHeartbeat == nil, let heartbeat = core.lastHeartbeat {
                    merged.lastHeartbeat = heartbeat
                }
                if merged.connectionState == .offline, core.connectionState != .offline {
                    merged.connectionState = core.connectionState
                }
                if !merged.isScanning, core.isScanning {
                    merged.isScanning = true
                }
                if let error = core.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    merged.lastError = error
                }
                if merged != existing {
                    nodesByID[id] = merged
                    changed = true
                }
            } else {
                nodesByID[id] = core
                changed = true
            }
        }

        if changed {
            refreshNodes()
            persist()
        }
        return changed
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

    func remove(nodeID: String) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        if nodesByID.removeValue(forKey: trimmedID) != nil {
            refreshNodes()
            persist()
        }
        setConnecting(nodeID: trimmedID, connecting: false)
    }

    func removeAll() {
        guard !nodesByID.isEmpty else { return }
        nodesByID.removeAll()
        connectingNodeIDs.removeAll()
        refreshNodes()
        persist()
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
        guard isRegistrableNodeID(nodeID) else {
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
        guard isRegistrableNodeID(resolvedID) else { return nil }

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
                return registerFallbackHost(trimmed, preferredLabel: preferredLabel)
            }
            let text = String(data: data, encoding: .utf8)
            guard let payload = WhoamiParser.parse(text) else {
                return registerFallbackHost(trimmed, preferredLabel: preferredLabel)
            }
            if let resolvedID = payload.resolvedNodeID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !resolvedID.isEmpty,
               !isRegistrableNodeID(resolvedID) {
                return ManualRegisterResult(nodeID: nil, error: serviceOnlyRegistrationError)
            }
            guard let nodeID = registerFromWhoami(host: trimmed, payload: payload, preferredLabel: preferredLabel) else {
                return registerFallbackHost(trimmed, preferredLabel: preferredLabel)
            }
            return ManualRegisterResult(nodeID: nodeID, error: nil)
        } catch {
            return registerFallbackHost(trimmed, preferredLabel: preferredLabel)
        }
    }

    private func registerFallbackHost(_ host: String, preferredLabel: String?) -> ManualRegisterResult {
        let preferred = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (!preferred.isEmpty ? preferred : host)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegistrableNodeID(id) else {
            return ManualRegisterResult(nodeID: nil, error: serviceOnlyRegistrationError)
        }
        let label = !preferred.isEmpty ? preferred : id
        let record = NodeRecord(
            id: id,
            label: label,
            type: .unknown,
            capabilities: [],
            lastSeen: Date(),
            lastHeartbeat: nil,
            connectionState: .idle,
            isScanning: false,
            lastError: nil,
            ip: host,
            hostname: nil,
            mac: nil
        )
        upsert(record, allowStateUpdate: true)
        return ManualRegisterResult(nodeID: id, error: nil)
    }

    private func upsert(_ record: NodeRecord, allowStateUpdate: Bool) {
        let trimmedID = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegistrableNodeID(trimmedID) else {
            if nodesByID.removeValue(forKey: trimmedID) != nil {
                refreshNodes()
                persist()
            }
            return
        }
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
        _ = pruneServiceOnlyNodes()
        nodes = nodesByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func persist() {
        do {
            _ = pruneServiceOnlyNodes()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let persistedNodes = nodesByID.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            nodes = persistedNodes
            let payload = NodeRegistryPayload(nodes: persistedNodes)
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
            Task { @MainActor [weak self] in
                self?.updateStaleness()
            }
        }
    }

    private func updateStaleness() {
        let now = Date()
        var changed = false
        for (id, record) in nodesByID {
            if !isRegistrableNodeID(id) {
                nodesByID.removeValue(forKey: id)
                changed = true
                continue
            }
            if isCoreNodeID(id) { continue }
            guard let lastSeen = record.lastSeen else { continue }
            if now.timeIntervalSince(lastSeen) > offlineThreshold, record.connectionState != .offline, record.connectionState != .error {
                var updated = record
                updated.connectionState = .offline
                nodesByID[id] = updated
                changed = true
            }
        }
        if changed {
            pruneUnresolvableOfflineNodes()
            refreshNodes()
            persist()
        }
    }

    private func pruneUnresolvableOfflineNodes() {
        let now = Date()
        nodesByID = nodesByID.filter { _, record in
            let host = (record.ip ?? record.hostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty { return true }
            if let mac = record.mac?.trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty { return true }
            guard record.connectionState == .offline else { return true }
            let age = now.timeIntervalSince(record.lastSeen ?? .distantPast)
            let unresolved = (record.lastError ?? "").localizedCaseInsensitiveContains("no ip/hostname")
            if unresolved && age > 300 {
                return false
            }
            return true
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

    private func inferredNodeType(nodeID: String, hostname: String?) -> NodeType {
        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = (hostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id == "exec-pi-aux" || id == "pi-aux" || host.contains("pi-aux") || host == "aux" {
            return .piAux
        }
        if id == "mac16" || id.hasPrefix("mac") || host.hasPrefix("mac") {
            return .mac
        }
        return .unknown
    }

    private func coreSeeds(presence: [String: NodePresence], fleetHints: [String: FleetCoreHint]) -> [NodeRecord] {
        coreDefinitions.map { definition in
            let item = presence[definition.id]
            let hint = fleetHints[definition.id]
            let label = definition.label
            let hostname = preferredHost(
                presenceHost: item?.hostname,
                fleetHost: hint?.host,
                fallbackHost: definition.hostname
            )
            let mapped: (connectionState: NodeConnectionState?, isScanning: Bool?) =
                item.map { mapPresenceState($0.state) } ?? (connectionState: nil, isScanning: nil)
            let connectionState: NodeConnectionState = {
                if let mappedState = mapped.connectionState, mappedState != .offline {
                    return mappedState
                }
                if hint?.ok == true {
                    return .connected
                }
                if hint?.reachable == true {
                    return .idle
                }
                if let mappedState = mapped.connectionState {
                    return mappedState
                }
                return .offline
            }()
            let isScanning = mapped.isScanning ?? false
            let caps = item.flatMap { capabilitiesFromPresence($0.capabilities) } ?? []
            let lastSeen: Date? = {
                if let ts = item?.lastSeen, ts > 0 {
                    return Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
                }
                if hint?.ok == true || hint?.reachable == true {
                    return Date()
                }
                return nil
            }()
            let lastError = item?.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NodeRecord(
                id: definition.id,
                label: label,
                type: definition.type,
                capabilities: caps,
                lastSeen: lastSeen,
                lastHeartbeat: lastSeen,
                connectionState: connectionState,
                isScanning: isScanning,
                lastError: lastError?.isEmpty == true ? nil : lastError,
                ip: item?.ip,
                hostname: hostname,
                mac: item?.mac
            )
        }
    }

    private func preferredHost(presenceHost: String?, fleetHost: String?, fallbackHost: String) -> String {
        let presenceTrimmed = presenceHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !presenceTrimmed.isEmpty {
            return presenceTrimmed
        }
        let fleetTrimmed = fleetHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fleetTrimmed.isEmpty {
            return fleetTrimmed
        }
        return fallbackHost
    }

    private func loadFleetCoreHints(fileURL: URL) -> [String: FleetCoreHint] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = object["targets"] as? [[String: Any]] else {
            return [:]
        }

        var hints: [String: FleetCoreHint] = [:]
        for target in targets {
            let name = ((target["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let nodeID = coreNodeID(fromTargetName: name) else { continue }
            let services: [[String: Any]] = (target["services"] as? [[String: Any]]) ?? []
            let actions: [String] = (target["actions"] as? [String]) ?? []
            let serviceHosts: [String] = services.compactMap { service in
                guard let detail = service["detail"] as? String else { return nil }
                return parseHost(from: detail)
            }
            let actionAliases: [String] = actions.compactMap { action in
                let prefix = "ssh-target:"
                guard action.hasPrefix(prefix) else { return nil }
                return String(action.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let aliasHost = actionAliases.compactMap { canonicalHost(forAlias: $0) }.first
            let host = serviceHosts.first ?? aliasHost
            let reachable = target["reachable"] as? Bool
            let ok = target["ok"] as? Bool
            hints[nodeID] = FleetCoreHint(host: host, reachable: reachable, ok: ok)
        }
        return hints
    }

    private func coreNodeID(fromTargetName name: String) -> String? {
        if name.contains("aux") {
            return "exec-pi-aux"
        }
        if name.contains("logger") || name.contains("vault") {
            return "exec-pi-logger"
        }
        if name.contains("mac") {
            return "mac16"
        }
        return nil
    }

    private func parseHost(from value: String) -> String? {
        if let comps = URLComponents(string: value),
           let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(" ") {
            return nil
        }
        return trimmed
    }

    private func canonicalHost(forAlias alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "aux", "aux-5g", "aux-24g":
            return "pi-aux.local"
        case "vault", "vault-eth", "vault-wifi":
            return "pi-logger.local"
        case "mac16":
            return "mac16.local"
        case "mac8":
            return "mac8.local"
        default:
            return nil
        }
    }

    private func isCoreNodeID(_ nodeID: String) -> Bool {
        let normalized = normalizedNodeID(nodeID)
        return normalized == "exec-pi-aux" || normalized == "exec-pi-logger" || normalized == "mac16"
    }

    private func normalizedNodeID(_ nodeID: String) -> String {
        nodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isReservedServiceNodeID(_ nodeID: String) -> Bool {
        let normalized = normalizedNodeID(nodeID)
        if normalized.hasPrefix("service:") {
            return true
        }
        return reservedServiceNodeIDs.contains(normalized)
    }

    private func isRegistrableNodeID(_ nodeID: String) -> Bool {
        let normalized = normalizedNodeID(nodeID)
        return !normalized.isEmpty && !isReservedServiceNodeID(normalized)
    }

    @discardableResult
    private func pruneServiceOnlyNodes() -> Bool {
        let previousCount = nodesByID.count
        nodesByID = nodesByID.filter { key, value in
            isRegistrableNodeID(key) && isRegistrableNodeID(value.id)
        }
        let previousConnectingCount = connectingNodeIDs.count
        connectingNodeIDs = Set(connectingNodeIDs.filter { isRegistrableNodeID($0) })
        return nodesByID.count != previousCount || connectingNodeIDs.count != previousConnectingCount
    }

    static func defaultFleetStatusFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SODS/control-plane-status.json")
    }

    private func nodeType(from payload: WhoamiPayload) -> NodeType {
        if let chip = payload.chip?.lowercased() {
            if chip.contains("esp32") { return .esp32 }
        }
        return .unknown
    }

    private struct CoreNodeDefinition {
        let id: String
        let label: String
        let hostname: String
        let type: NodeType
    }

    private struct FleetCoreHint {
        let host: String?
        let reachable: Bool?
        let ok: Bool?
    }

    private var coreDefinitions: [CoreNodeDefinition] {
        [
            CoreNodeDefinition(id: "exec-pi-aux", label: "pi-aux", hostname: "pi-aux.local", type: .piAux),
            CoreNodeDefinition(id: "exec-pi-logger", label: "pi-logger", hostname: "pi-logger.local", type: .unknown),
            CoreNodeDefinition(id: "mac16", label: "mac16", hostname: "mac16.local", type: .mac)
        ]
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
