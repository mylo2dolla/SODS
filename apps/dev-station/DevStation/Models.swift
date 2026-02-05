import Foundation

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

enum ScanMode: String, CaseIterable, Identifiable {
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

struct PlannedNode: Identifiable, Codable, Hashable {
    let id: String
    var label: String
    var type: NodeType
    var capabilities: [String]
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
    var planned: Bool

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
