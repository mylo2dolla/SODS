import Foundation

struct EvidencePayload: Codable {
    let ip: String
    let hostname: String?
    let mac: String?
    let vendor: String?
    let vendorConfidenceScore: Int
    let vendorConfidenceReasons: [String]
    let hostConfidence: HostConfidence
    let openPorts: [Int]
    let ssdpServer: String?
    let ssdpLocation: String?
    let ssdpST: String?
    let ssdpUSN: String?
    let bonjourServices: [BonjourService]
    let httpStatus: Int?
    let httpServer: String?
    let httpAuth: String?
    let httpTitle: String?
}

struct FingerprintPayload: Codable {
    let id: String
    let name: String?
    let rssi: Int
    let fingerprint: BLEAdFingerprint
    let manufacturerDataHex: String?
    let fingerprintID: String
    let label: String
    let bleConfidence: BLEConfidence
}

func buildEvidencePayload(_ host: HostEntry) -> EvidencePayload {
    EvidencePayload(
        ip: host.ip,
        hostname: host.hostname,
        mac: host.macAddress,
        vendor: host.vendor,
        vendorConfidenceScore: host.vendorConfidenceScore,
        vendorConfidenceReasons: host.vendorConfidenceReasons,
        hostConfidence: host.hostConfidence,
        openPorts: host.openPorts,
        ssdpServer: host.ssdpServer,
        ssdpLocation: host.ssdpLocation,
        ssdpST: host.ssdpST,
        ssdpUSN: host.ssdpUSN,
        bonjourServices: host.bonjourServices,
        httpStatus: host.httpStatus,
        httpServer: host.httpServer,
        httpAuth: host.httpAuth,
        httpTitle: host.httpTitle
    )
}
