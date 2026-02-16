import Foundation
import CoreBluetooth

public enum ConfidenceLevel: String, Codable, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

public enum ScanMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case oneShot
    case continuous

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .oneShot:
            return "One-shot"
        case .continuous:
            return "Continuous"
        }
    }
}

public struct Provenance: Hashable, Codable, Sendable {
    public let source: String
    public let mode: ScanMode
    public let timestamp: Date

    public init(source: String, mode: ScanMode, timestamp: Date) {
        self.source = source
        self.mode = mode
        self.timestamp = timestamp
    }

    public var label: String {
        let stamp = timestamp.formatted(date: .abbreviated, time: .shortened)
        return "\(source) • \(mode.label) • \(stamp)"
    }
}

public struct HostConfidence: Codable, Hashable, Sendable {
    public var score: Int
    public var level: ConfidenceLevel
    public var reasons: [String]

    public init(score: Int, level: ConfidenceLevel, reasons: [String]) {
        self.score = score
        self.level = level
        self.reasons = reasons
    }
}

public struct BLEConfidence: Codable, Hashable, Sendable {
    public var score: Int
    public var level: ConfidenceLevel
    public var reasons: [String]

    public init(score: Int, level: ConfidenceLevel, reasons: [String]) {
        self.score = score
        self.level = level
        self.reasons = reasons
    }
}

public struct BonjourService: Codable, Hashable, Sendable {
    public let name: String
    public let type: String
    public let port: Int
    public let txt: [String]

    public init(name: String, type: String, port: Int, txt: [String]) {
        self.name = name
        self.type = type
        self.port = port
        self.txt = txt
    }
}

public struct RTSPProbeResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let uri: String
    public let statusCode: Int?
    public let server: String?
    public let hasVideo: Bool
    public let codecHints: [String]
    public let success: Bool
    public let error: String?

    public init(
        id: UUID = UUID(),
        uri: String,
        statusCode: Int?,
        server: String?,
        hasVideo: Bool,
        codecHints: [String],
        success: Bool,
        error: String?
    ) {
        self.id = id
        self.uri = uri
        self.statusCode = statusCode
        self.server = server
        self.hasVideo = hasVideo
        self.codecHints = codecHints
        self.success = success
        self.error = error
    }
}

public struct Device: Identifiable, Hashable, Sendable {
    public let id: String
    public let ip: String
    public var openPorts: [Int]
    public var httpTitle: String?
    public var macAddress: String?
    public var vendor: String?
    public var hostConfidence: HostConfidence
    public var vendorConfidenceScore: Int
    public var vendorConfidenceReasons: [String]
    public var discoveredViaOnvif: Bool
    public var onvifXAddrs: [String]
    public var onvifTypes: String?
    public var onvifScopes: String?
    public var onvifRtspURI: String?
    public var onvifRequiresAuth: Bool
    public var onvifLastError: String?
    public var username: String
    public var password: String
    public var rtspProbeInProgress: Bool
    public var rtspProbeResults: [RTSPProbeResult]
    public var bestRtspURI: String?
    public var lastRtspProbeSummary: String?

    public init(
        id: String,
        ip: String,
        openPorts: [Int],
        httpTitle: String?,
        macAddress: String?,
        vendor: String?,
        hostConfidence: HostConfidence,
        vendorConfidenceScore: Int,
        vendorConfidenceReasons: [String],
        discoveredViaOnvif: Bool,
        onvifXAddrs: [String],
        onvifTypes: String?,
        onvifScopes: String?,
        onvifRtspURI: String?,
        onvifRequiresAuth: Bool,
        onvifLastError: String?,
        username: String,
        password: String,
        rtspProbeInProgress: Bool,
        rtspProbeResults: [RTSPProbeResult],
        bestRtspURI: String?,
        lastRtspProbeSummary: String?
    ) {
        self.id = id
        self.ip = ip
        self.openPorts = openPorts
        self.httpTitle = httpTitle
        self.macAddress = macAddress
        self.vendor = vendor
        self.hostConfidence = hostConfidence
        self.vendorConfidenceScore = vendorConfidenceScore
        self.vendorConfidenceReasons = vendorConfidenceReasons
        self.discoveredViaOnvif = discoveredViaOnvif
        self.onvifXAddrs = onvifXAddrs
        self.onvifTypes = onvifTypes
        self.onvifScopes = onvifScopes
        self.onvifRtspURI = onvifRtspURI
        self.onvifRequiresAuth = onvifRequiresAuth
        self.onvifLastError = onvifLastError
        self.username = username
        self.password = password
        self.rtspProbeInProgress = rtspProbeInProgress
        self.rtspProbeResults = rtspProbeResults
        self.bestRtspURI = bestRtspURI
        self.lastRtspProbeSummary = lastRtspProbeSummary
    }

    public var isCameraLikely: Bool {
        openPorts.contains(554) || openPorts.contains(3702)
    }

    public var suggestedRTSPURL: String {
        "rtsp://\(ip):554/"
    }
}

public struct HostEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let ip: String
    public var isAlive: Bool
    public var openPorts: [Int]
    public var hostname: String?
    public var macAddress: String?
    public var vendor: String?
    public var vendorConfidenceScore: Int
    public var vendorConfidenceReasons: [String]
    public var hostConfidence: HostConfidence
    public var ssdpServer: String?
    public var ssdpLocation: String?
    public var ssdpST: String?
    public var ssdpUSN: String?
    public var bonjourServices: [BonjourService]
    public var httpStatus: Int?
    public var httpServer: String?
    public var httpAuth: String?
    public var httpTitle: String?
    public var provenance: Provenance?

    public init(
        id: String,
        ip: String,
        isAlive: Bool,
        openPorts: [Int],
        hostname: String?,
        macAddress: String?,
        vendor: String?,
        vendorConfidenceScore: Int,
        vendorConfidenceReasons: [String],
        hostConfidence: HostConfidence,
        ssdpServer: String?,
        ssdpLocation: String?,
        ssdpST: String?,
        ssdpUSN: String?,
        bonjourServices: [BonjourService],
        httpStatus: Int?,
        httpServer: String?,
        httpAuth: String?,
        httpTitle: String?,
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.ip = ip
        self.isAlive = isAlive
        self.openPorts = openPorts
        self.hostname = hostname
        self.macAddress = macAddress
        self.vendor = vendor
        self.vendorConfidenceScore = vendorConfidenceScore
        self.vendorConfidenceReasons = vendorConfidenceReasons
        self.hostConfidence = hostConfidence
        self.ssdpServer = ssdpServer
        self.ssdpLocation = ssdpLocation
        self.ssdpST = ssdpST
        self.ssdpUSN = ssdpUSN
        self.bonjourServices = bonjourServices
        self.httpStatus = httpStatus
        self.httpServer = httpServer
        self.httpAuth = httpAuth
        self.httpTitle = httpTitle
        self.provenance = provenance
    }

    public var evidence: String {
        let tags = evidenceTags
        return tags.isEmpty ? "None" : tags.joined(separator: "+")
    }

    public var evidenceTags: [String] {
        var tags: [String] = []
        if macAddress != nil { tags.append("ARP") }
        if !openPorts.isEmpty { tags.append("Ports") }
        return tags
    }

    public var hostnameSortKey: String {
        hostname ?? ""
    }

    public var ipNumeric: UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return 0 }
        return (UInt32(parts[0]) << 24) | (UInt32(parts[1]) << 16) | (UInt32(parts[2]) << 8) | UInt32(parts[3])
    }
}

public struct ScanProgress: Sendable {
    public var scannedHosts: Int
    public var totalHosts: Int

    public init(scannedHosts: Int, totalHosts: Int) {
        self.scannedHosts = scannedHosts
        self.totalHosts = totalHosts
    }
}

public struct OnvifDiscoveryResult: Hashable, Sendable {
    public let ip: String
    public let xaddrs: [String]
    public let types: String?
    public let scopes: String?

    public init(ip: String, xaddrs: [String], types: String?, scopes: String?) {
        self.ip = ip
        self.xaddrs = xaddrs
        self.types = types
        self.scopes = scopes
    }
}

public struct BLERSSISample: Hashable, Codable, Sendable {
    public let timestamp: Date
    public let smoothedRSSI: Double

    public init(timestamp: Date, smoothedRSSI: Double) {
        self.timestamp = timestamp
        self.smoothedRSSI = smoothedRSSI
    }
}

public struct BLEServiceDecoded: Hashable, Codable, Sendable {
    public let uuid: String
    public let name: String
    public let type: String
    public let source: String

    public init(uuid: String, name: String, type: String, source: String) {
        self.uuid = uuid
        self.name = name
        self.type = type
        self.source = source
    }
}

public struct BLEAdFingerprint: Hashable, Codable, Sendable {
    public var localName: String?
    public var isConnectable: Bool?
    public var txPower: Int?
    public var serviceUUIDs: [String]
    public var manufacturerCompanyID: UInt16?
    public var manufacturerCompanyName: String?
    public var manufacturerAssignmentDate: String?
    public var manufacturerDataPrefixHex: String?
    public var beaconHint: String?
    public var servicesDecoded: [BLEServiceDecoded]
    public var unknownServices: [String]

    public init(
        localName: String?,
        isConnectable: Bool?,
        txPower: Int?,
        serviceUUIDs: [String],
        manufacturerCompanyID: UInt16?,
        manufacturerCompanyName: String?,
        manufacturerAssignmentDate: String?,
        manufacturerDataPrefixHex: String?,
        beaconHint: String?,
        servicesDecoded: [BLEServiceDecoded],
        unknownServices: [String]
    ) {
        self.localName = localName
        self.isConnectable = isConnectable
        self.txPower = txPower
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerCompanyID = manufacturerCompanyID
        self.manufacturerCompanyName = manufacturerCompanyName
        self.manufacturerAssignmentDate = manufacturerAssignmentDate
        self.manufacturerDataPrefixHex = manufacturerDataPrefixHex
        self.beaconHint = beaconHint
        self.servicesDecoded = servicesDecoded
        self.unknownServices = unknownServices
    }
}

public struct BLEPeripheral: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String?
    public var rssi: Int
    public var smoothedRSSI: Double
    public var rssiHistory: [BLERSSISample]
    public var serviceUUIDs: [String]
    public var manufacturerDataHex: String?
    public var fingerprint: BLEAdFingerprint
    public var fingerprintID: String
    public var bleConfidence: BLEConfidence
    public var lastSeen: Date
    public var provenance: Provenance?

    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        smoothedRSSI: Double,
        rssiHistory: [BLERSSISample],
        serviceUUIDs: [String],
        manufacturerDataHex: String?,
        fingerprint: BLEAdFingerprint,
        fingerprintID: String,
        bleConfidence: BLEConfidence,
        lastSeen: Date,
        provenance: Provenance?
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.smoothedRSSI = smoothedRSSI
        self.rssiHistory = rssiHistory
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
        self.fingerprint = fingerprint
        self.fingerprintID = fingerprintID
        self.bleConfidence = bleConfidence
        self.lastSeen = lastSeen
        self.provenance = provenance
    }
}

public struct BLEEvidence: Codable, Sendable {
    public let id: String
    public let name: String
    public let rssi: Int
    public let serviceUUIDs: [String]
    public let manufacturerDataHex: String
    public let manufacturerCompanyID: UInt16?
    public let manufacturerCompanyName: String?
    public let manufacturerAssignmentDate: String?
    public let servicesDecoded: [BLEServiceDecoded]
    public let unknownServices: [String]
    public let bleConfidence: BLEConfidence

    public init(
        id: String,
        name: String,
        rssi: Int,
        serviceUUIDs: [String],
        manufacturerDataHex: String,
        manufacturerCompanyID: UInt16?,
        manufacturerCompanyName: String?,
        manufacturerAssignmentDate: String?,
        servicesDecoded: [BLEServiceDecoded],
        unknownServices: [String],
        bleConfidence: BLEConfidence
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
        self.manufacturerCompanyID = manufacturerCompanyID
        self.manufacturerCompanyName = manufacturerCompanyName
        self.manufacturerAssignmentDate = manufacturerAssignmentDate
        self.servicesDecoded = servicesDecoded
        self.unknownServices = unknownServices
        self.bleConfidence = bleConfidence
    }
}

public struct ScanScope: Sendable {
    public struct Range: Sendable {
        public let start: String
        public let end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public let cidr: String
    public let ipRange: Range?
    public let onlyLocalSubnet: Bool

    public init(cidr: String, ipRange: Range?, onlyLocalSubnet: Bool) {
        self.cidr = cidr
        self.ipRange = ipRange
        self.onlyLocalSubnet = onlyLocalSubnet
    }

    public static var localDefault: ScanScope {
        ScanScope(cidr: "192.168.1.0/24", ipRange: nil, onlyLocalSubnet: true)
    }
}

public struct SignalNode: Identifiable, Hashable, Sendable {
    public let id: String
    public var lastSeen: Date = .distantPast
    public var ip: String?
    public var hostname: String?
    public var mac: String?
    public var lastKind: String?

    public init(id: String, lastSeen: Date = .distantPast, ip: String? = nil, hostname: String? = nil, mac: String? = nil, lastKind: String? = nil) {
        self.id = id
        self.lastSeen = lastSeen
        self.ip = ip
        self.hostname = hostname
        self.mac = mac
        self.lastKind = lastKind
    }

    public var isStale: Bool {
        Date().timeIntervalSince(lastSeen) > 60
    }
}

public struct NodePresence: Decodable, Hashable, Sendable {
    public let nodeID: String
    public let state: String
    public let lastSeen: Int
    public let lastSeenAgeMs: Int?
    public let lastError: String?
    public let ip: String?
    public let mac: String?
    public let hostname: String?
    public let confidence: Double?
    public let capabilities: NodeCapabilities
    public let provenanceID: String?
    public let lastKind: String?

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

    public init(nodeID: String, state: String, lastSeen: Int, lastSeenAgeMs: Int?, lastError: String?, ip: String?, mac: String?, hostname: String?, confidence: Double?, capabilities: NodeCapabilities, provenanceID: String?, lastKind: String?) {
        self.nodeID = nodeID
        self.state = state
        self.lastSeen = lastSeen
        self.lastSeenAgeMs = lastSeenAgeMs
        self.lastError = lastError
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.confidence = confidence
        self.capabilities = capabilities
        self.provenanceID = provenanceID
        self.lastKind = lastKind
    }
}

public struct NodeCapabilities: Decodable, Hashable, Sendable {
    public let canScanWifi: Bool?
    public let canScanBle: Bool?
    public let canFrames: Bool?
    public let canFlash: Bool?
    public let canWhoami: Bool?

    public init(canScanWifi: Bool?, canScanBle: Bool?, canFrames: Bool?, canFlash: Bool?, canWhoami: Bool?) {
        self.canScanWifi = canScanWifi
        self.canScanBle = canScanBle
        self.canFrames = canFrames
        self.canFlash = canFlash
        self.canWhoami = canWhoami
    }
}
