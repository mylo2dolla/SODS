import Foundation
import AppKit

enum ConfidenceLevel: String, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

enum NodeType: String, Codable, CaseIterable {
    case mac = "mac"
    case piAux = "pi-aux"
    case esp32 = "esp32"
    case sdr = "sdr"
    case gps = "gps"
    case unknown = "unknown"
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

enum ScanMode: String, CaseIterable, Identifiable, Codable {
    case oneShot
    case continuous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneShot: return "One-shot"
        case .continuous: return "Continuous"
        }
    }
}

struct Provenance: Hashable, Codable {
    let source: String
    let mode: ScanMode
    let timestamp: Date

    var label: String {
        let stamp = timestamp.formatted(date: .abbreviated, time: .shortened)
        return "\(source) • \(mode.label) • \(stamp)"
    }
}

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
        let presenceOnline = isPresenceOnline(presence?.state)
        let fallbackOnline = node.presenceState == .connected || node.presenceState == .idle || node.presenceState == .scanning
        return NodePresentation.forNode(id: node.id, keys: keys, isOnline: presenceOnline || fallbackOnline, activityScore: activityScore)
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

struct HostConfidence: Codable, Hashable {
    var score: Int
    var level: ConfidenceLevel
    var reasons: [String]
}

struct BLEConfidence: Codable, Hashable {
    var score: Int
    var level: ConfidenceLevel
    var reasons: [String]
}

struct Device: Identifiable, Hashable {
    let id: String
    let ip: String
    var openPorts: [Int]
    var httpTitle: String?
    var macAddress: String?
    var vendor: String?
    var hostConfidence: HostConfidence
    var vendorConfidenceScore: Int
    var vendorConfidenceReasons: [String]

    var discoveredViaOnvif: Bool
    var onvifXAddrs: [String]
    var onvifTypes: String?
    var onvifScopes: String?
    var onvifRtspURI: String?
    var onvifRequiresAuth: Bool
    var onvifLastError: String?
    var username: String
    var password: String
    var rtspProbeInProgress: Bool
    var rtspProbeResults: [RTSPProbeResult]
    var bestRtspURI: String?
    var lastRtspProbeSummary: String?

    var isCameraLikely: Bool {
        openPorts.contains(554) || openPorts.contains(3702)
    }

    var suggestedRTSPURL: String {
        "rtsp://\(ip):554/"
    }
}

struct HostEntry: Identifiable, Hashable {
    let id: String
    let ip: String
    var isAlive: Bool
    var openPorts: [Int]
    var hostname: String?
    var macAddress: String?
    var vendor: String?
    var vendorConfidenceScore: Int
    var vendorConfidenceReasons: [String]
    var hostConfidence: HostConfidence
    var ssdpServer: String?
    var ssdpLocation: String?
    var ssdpST: String?
    var ssdpUSN: String?
    var bonjourServices: [BonjourService]
    var httpStatus: Int?
    var httpServer: String?
    var httpAuth: String?
    var httpTitle: String?
    var provenance: Provenance? = nil

    var evidence: String {
        let tags = evidenceTags
        return tags.isEmpty ? "None" : tags.joined(separator: "+")
    }

    var evidenceTags: [String] {
        var tags: [String] = []
        if macAddress != nil { tags.append("ARP") }
        if !openPorts.isEmpty { tags.append("Ports") }
        return tags
    }

    var hostnameSortKey: String {
        hostname ?? ""
    }

    var ipNumeric: UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return 0 }
        return (UInt32(parts[0]) << 24) | (UInt32(parts[1]) << 16) | (UInt32(parts[2]) << 8) | UInt32(parts[3])
    }
}

struct ScanProgress {
    var scannedHosts: Int
    var totalHosts: Int
}

struct OnvifDiscoveryResult: Hashable {
    let ip: String
    let xaddrs: [String]
    let types: String?
    let scopes: String?
}

struct BonjourService: Codable, Hashable {
    let name: String
    let type: String
    let port: Int
    let txt: [String]
}

struct BLEPeripheral: Identifiable, Hashable {
    let id: UUID
    var name: String?
    var rssi: Int
    var smoothedRSSI: Double
    var rssiHistory: [BLERSSISample]
    var serviceUUIDs: [String]
    var manufacturerDataHex: String?
    var fingerprint: BLEAdFingerprint
    var fingerprintID: String
    var bleConfidence: BLEConfidence
    var lastSeen: Date
    var provenance: Provenance? = nil
}

struct BLERSSISample: Hashable, Codable {
    let timestamp: Date
    let smoothedRSSI: Double
}

struct BLEAdFingerprint: Hashable, Codable {
    var localName: String?
    var isConnectable: Bool?
    var txPower: Int?
    var serviceUUIDs: [String]
    var manufacturerCompanyID: UInt16?
    var manufacturerCompanyName: String?
    var manufacturerAssignmentDate: String?
    var manufacturerDataPrefixHex: String?
    var beaconHint: String?
    var servicesDecoded: [BLEServiceDecoded]
    var unknownServices: [String]
}

struct BLEServiceDecoded: Hashable, Codable {
    let uuid: String
    let name: String
    let type: String
    let source: String
}

struct BLEEvidence: Codable {
    let id: String
    let name: String
    let rssi: Int
    let serviceUUIDs: [String]
    let manufacturerDataHex: String
    let manufacturerCompanyID: UInt16?
    let manufacturerCompanyName: String?
    let manufacturerAssignmentDate: String?
    let servicesDecoded: [BLEServiceDecoded]
    let unknownServices: [String]
    let bleConfidence: BLEConfidence
}

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
