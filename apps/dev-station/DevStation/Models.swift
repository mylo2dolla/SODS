import Foundation
import AppKit
import ScannerSpectrumCore

typealias ConfidenceLevel = ScannerSpectrumCore.ConfidenceLevel

enum NodeType: String, Codable, CaseIterable {
    case mac = "mac"
    case piAux = "pi-aux"
    case esp32 = "esp32"
    case sdr = "sdr"
    case gps = "gps"
    case unknown = "unknown"
}

enum NodeFirmwareProfile: String, Codable, CaseIterable {
    case nodeAgentESP32Dev = "node-agent-esp32dev"
    case nodeAgentESP32C3 = "node-agent-esp32c3"
    case opsPortalCYD = "ops-portal-cyd"
    case p4GodButton = "sods-p4-godbutton"
    case unknown = "unknown"

    static func infer(nodeID: String, hostname: String?, capabilities: [String]) -> NodeFirmwareProfile {
        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = (hostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let capSet = Set(capabilities.map { $0.lowercased() })

        if id.hasPrefix("p4-") || id.contains("esp32-p4") || host.contains("p4") {
            return .p4GodButton
        }
        if id.contains("portal") || id.contains("cyd") || host.contains("portal") || host.contains("cyd") {
            return .opsPortalCYD
        }
        if id.contains("c3") || host.contains("c3") {
            return .nodeAgentESP32C3
        }
        if id.contains("esp32") || id.contains("node") || capSet.contains("probe") || capSet.contains("ping") {
            return .nodeAgentESP32Dev
        }
        return .unknown
    }

    var defaultCapabilities: [String] {
        switch self {
        case .nodeAgentESP32Dev, .nodeAgentESP32C3:
            return ["scan", "probe", "ping", "identify"]
        case .opsPortalCYD:
            return ["portal", "identify"]
        case .p4GodButton:
            return ["scan", "probe", "god", "identify", "frames"]
        case .unknown:
            return []
        }
    }
}

enum NodeConnectionState: String, Codable {
    case connected
    case idle
    case offline
    case error
}

enum NodePresenceState: String, Codable {
    case connected
    case idle
    case scanning
    case offline
    case error
}

enum CoreNodeStateResolver {
    private static let coreNodeIDs: Set<String> = ["exec-pi-aux", "exec-pi-logger", "mac16"]

    static func effectiveState(node: NodeRecord, presence: NodePresence?) -> NodePresenceState {
        guard let presenceState = normalizedPresenceState(presence?.state) else {
            return node.presenceState
        }
        if coreNodeIDs.contains(node.id),
           presenceState == .offline,
           isOnline(node.presenceState) {
            return node.presenceState
        }
        return presenceState
    }

    static func isOnline(_ state: NodePresenceState) -> Bool {
        switch state {
        case .connected, .idle, .scanning:
            return true
        case .offline, .error:
            return false
        }
    }

    static func isScanning(_ state: NodePresenceState) -> Bool {
        state == .scanning
    }

    static func statusLabel(for state: NodePresenceState) -> String {
        switch state {
        case .connected:
            return "Online"
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .offline:
            return "Offline"
        case .error:
            return "Error"
        }
    }

    private static func normalizedPresenceState(_ raw: String?) -> NodePresenceState? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "online", "connected":
            return .connected
        case "idle":
            return .idle
        case "scanning":
            return .scanning
        case "offline":
            return .offline
        case "error":
            return .error
        default:
            return nil
        }
    }
}

typealias ScanMode = ScannerSpectrumCore.ScanMode
typealias Provenance = ScannerSpectrumCore.Provenance

struct NodeRecord: Identifiable, Codable, Hashable {
    let id: String
    var label: String
    var type: NodeType
    var capabilities: [String]
    var lastSeen: Date?
    var lastHeartbeat: Date?
    var connectionState: NodeConnectionState
    var isScanning: Bool
    var lastError: String?
    var ip: String?
    var hostname: String?
    var mac: String?

    var presenceState: NodePresenceState {
        if connectionState == .error { return .error }
        if isScanning { return .scanning }
        switch connectionState {
        case .connected: return .connected
        case .idle: return .idle
        case .offline: return .offline
        case .error: return .error
        }
    }
}

struct NodePresentation: Hashable {
    let baseColor: NSColor
    let displayColor: NSColor
    let shouldGlow: Bool
    let isOffline: Bool
    let glowColor: NSColor
    let activityScore: Double

    @MainActor
    static func forNode(id: String, keys: [String], isOnline: Bool, activityScore: Double) -> NodePresentation {
        let identityKey = IdentityResolver.shared.resolveLabel(keys: keys) ?? id
        let base = SignalColor.deviceColor(id: identityKey)
        if isOnline {
            return NodePresentation(
                baseColor: base,
                displayColor: base,
                shouldGlow: true,
                isOffline: false,
                glowColor: base,
                activityScore: activityScore
            )
        }
        let muted = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        return NodePresentation(
            baseColor: base,
            displayColor: muted,
            shouldGlow: false,
            isOffline: true,
            glowColor: base,
            activityScore: activityScore
        )
    }

    @MainActor
    static func forNode(_ node: NodeRecord, presence: NodePresence?, activityScore: Double) -> NodePresentation {
        let keys = normalizedKeys([
            node.id,
            "node:\(node.id)",
            node.label,
            node.hostname,
            node.ip,
            node.mac,
            presence?.hostname,
            presence?.ip,
            presence?.mac
        ])
        let effectiveState = CoreNodeStateResolver.effectiveState(node: node, presence: presence)
        return NodePresentation.forNode(
            id: node.id,
            keys: keys,
            isOnline: CoreNodeStateResolver.isOnline(effectiveState),
            activityScore: activityScore
        )
    }

    @MainActor
    static func forSignalNode(_ node: SignalNode, presence: NodePresence?, activityScore: Double) -> NodePresentation {
        let keys = normalizedKeys([
            node.id,
            "node:\(node.id)",
            node.hostname,
            node.ip,
            node.mac
        ])
        let presenceOnline = isPresenceOnline(presence?.state)
        let fallbackOnline = !node.isStale
        let isOnline = presence == nil ? fallbackOnline : presenceOnline
        return NodePresentation.forNode(id: node.id, keys: keys, isOnline: isOnline, activityScore: activityScore)
    }

    static func pulse(now: Date, seed: String, speed: Double = 2.4, depth: Double = 0.12) -> Double {
        let phase = Double(abs(seed.hashValue % 360)) * 0.0174533
        return 1.0 + depth * sin(now.timeIntervalSinceReferenceDate * speed + phase)
    }

    private static func normalizedKeys(_ keys: [String?]) -> [String] {
        keys.compactMap { item in
            let trimmed = item?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func isPresenceOnline(_ state: String?) -> Bool {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !state.isEmpty else { return false }
        switch state {
        case "online", "idle", "scanning", "connected":
            return true
        default:
            return false
        }
    }
}

struct WhoamiPayload: Decodable {
    let ok: Bool?
    let nodeID: String?
    let nodeId: String?
    let id: String?
    let hostname: String?
    let ip: String?
    let mac: String?
    let label: String?
    let chip: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case nodeID = "node_id"
        case nodeId = "nodeId"
        case id
        case hostname
        case ip
        case mac
        case label
        case chip
    }

    var resolvedNodeID: String? {
        if let nodeID, !nodeID.isEmpty { return nodeID }
        if let nodeId, !nodeId.isEmpty { return nodeId }
        if let id, !id.isEmpty { return id }
        return nil
    }

    var resolvedLabel: String? {
        if let label, !label.isEmpty { return label }
        if let hostname, !hostname.isEmpty { return hostname }
        if let resolvedNodeID { return resolvedNodeID }
        return nil
    }
}

enum WhoamiParser {
    static func parse(_ text: String?) -> WhoamiPayload? {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WhoamiPayload.self, from: data)
    }
}

typealias HostConfidence = ScannerSpectrumCore.HostConfidence
typealias BLEConfidence = ScannerSpectrumCore.BLEConfidence
typealias Device = ScannerSpectrumCore.Device
typealias HostEntry = ScannerSpectrumCore.HostEntry
typealias ScanProgress = ScannerSpectrumCore.ScanProgress
typealias OnvifDiscoveryResult = ScannerSpectrumCore.OnvifDiscoveryResult
typealias BonjourService = ScannerSpectrumCore.BonjourService
typealias BLEPeripheral = ScannerSpectrumCore.BLEPeripheral
typealias BLERSSISample = ScannerSpectrumCore.BLERSSISample
typealias BLEAdFingerprint = ScannerSpectrumCore.BLEAdFingerprint
typealias BLEServiceDecoded = ScannerSpectrumCore.BLEServiceDecoded
typealias BLEEvidence = ScannerSpectrumCore.BLEEvidence

struct BLEProbeResult: Codable, Hashable {
    let fingerprintID: String
    let peripheralID: String
    let name: String?
    let alias: String?
    let lastUpdated: String
    let status: String
    let error: String
    let discoveredServices: [String]
    let manufacturerName: String?
    let modelNumber: String?
    let serialNumber: String?
    let firmwareRevision: String?
    let hardwareRevision: String?
    let systemID: String?
    let batteryLevel: Int?
    let deviceName: String?
}
