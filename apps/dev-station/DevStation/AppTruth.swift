import Foundation

@MainActor
final class AppTruth {
    static let shared = AppTruth()

    private init() {}

    var lastExportSnapshot: ExportSnapshot?
    var lastAuditLog: AuditLog?
    var lastEvidenceByIP: [String: EvidencePayload] = [:]

    struct EvidenceBundle {
        let host: HostEntry?
        let device: Device?
        let evidencePayload: EvidencePayload?
        let exportRecord: ExportRecord?
        let auditEvidence: AuditLog.Evidence?
    }

    func resolveHost(ip: String, scanner: NetworkScanner) -> HostEntry? {
        if let host = scanner.allHosts.first(where: { $0.ip == ip }) {
            return host
        }
        if let record = lastExportSnapshot?.records.first(where: { $0.ip == ip }) {
            return HostEntry(
                id: record.ip,
                ip: record.ip,
                isAlive: record.status == "Alive",
                openPorts: record.ports,
                hostname: record.hostname.isEmpty ? nil : record.hostname,
                macAddress: record.mac.isEmpty ? nil : record.mac,
                vendor: record.vendor.isEmpty ? nil : record.vendor,
                vendorConfidenceScore: record.vendorConfidenceScore,
                vendorConfidenceReasons: record.vendorConfidenceReasons,
                hostConfidence: record.hostConfidence,
                ssdpServer: record.ssdpServer.isEmpty ? nil : record.ssdpServer,
                ssdpLocation: record.ssdpLocation.isEmpty ? nil : record.ssdpLocation,
                ssdpST: record.ssdpST.isEmpty ? nil : record.ssdpST,
                ssdpUSN: record.ssdpUSN.isEmpty ? nil : record.ssdpUSN,
                bonjourServices: record.bonjourServices,
                httpStatus: record.httpStatus,
                httpServer: record.httpServer.isEmpty ? nil : record.httpServer,
                httpAuth: record.httpAuth.isEmpty ? nil : record.httpAuth,
                httpTitle: record.httpTitle.isEmpty ? nil : record.httpTitle
            )
        }
        return nil
    }

    func resolveDevice(ip: String, scanner: NetworkScanner) -> Device? {
        if let device = scanner.devices.first(where: { $0.ip == ip }) {
            return device
        }
        return nil
    }

    func resolveEvidence(ip: String, scanner: NetworkScanner) -> EvidenceBundle {
        let host = resolveHost(ip: ip, scanner: scanner)
        let device = resolveDevice(ip: ip, scanner: scanner)
        let evidencePayload = lastEvidenceByIP[ip]
        let exportRecord = lastExportSnapshot?.records.first(where: { $0.ip == ip })
        let auditEvidence = lastAuditLog?.evidences.first(where: { $0.ip == ip })
        return EvidenceBundle(host: host, device: device, evidencePayload: evidencePayload, exportRecord: exportRecord, auditEvidence: auditEvidence)
    }

    func bestRTSPURI(ip: String, scanner: NetworkScanner) -> String? {
        let bundle = resolveEvidence(ip: ip, scanner: scanner)
        if let onvif = bundle.device?.onvifRtspURI, !onvif.isEmpty { return onvif }
        if let best = bundle.device?.bestRtspURI, !best.isEmpty { return best }
        if let success = bundle.device?.rtspProbeResults.first(where: { $0.success })?.uri { return success }
        if let record = bundle.exportRecord, !record.rtspURI.isEmpty { return record.rtspURI }
        let ports = bestPorts(ip: ip, scanner: scanner)
        if ports.contains(554) { return "rtsp://\(ip):554/" }
        return nil
    }

    func bestONVIFXAddr(ip: String, scanner: NetworkScanner) -> String? {
        let device = resolveDevice(ip: ip, scanner: scanner)
        return device?.onvifXAddrs.first
    }

    func bestHTTPURL(ip: String, scanner: NetworkScanner) -> URL? {
        let bundle = resolveEvidence(ip: ip, scanner: scanner)
        let ssdpLocation = bundle.host?.ssdpLocation
            ?? bundle.evidencePayload?.ssdpLocation
            ?? bundle.exportRecord?.ssdpLocation
            ?? bundle.auditEvidence?.ssdpLocation
        if let location = ssdpLocation,
           let url = URL(string: location),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        let ports = bestPorts(ip: ip, scanner: scanner)
        let hasHTTPS = ports.contains(443) || ports.contains(8443)
        let hasHTTP = ports.contains(80) || ports.contains(8080) || ports.contains(8000)
        if hasHTTPS {
            let port = ports.contains(443) ? 443 : 8443
            return URL(string: "https://\(ip):\(port)")
        }
        if hasHTTP {
            let port = ports.contains(80) ? 80 : (ports.contains(8080) ? 8080 : 8000)
            return URL(string: "http://\(ip):\(port)")
        }
        return nil
    }

    func bestVendor(ip: String, scanner: NetworkScanner) -> String? {
        let bundle = resolveEvidence(ip: ip, scanner: scanner)
        if let vendor = bundle.host?.vendor, !vendor.isEmpty { return vendor }
        if let vendor = bundle.evidencePayload?.vendor, !vendor.isEmpty { return vendor }
        if let vendor = bundle.exportRecord?.vendor, !vendor.isEmpty { return vendor }
        if let vendor = bundle.auditEvidence?.vendor, !vendor.isEmpty { return vendor }
        return nil
    }

    func bestPorts(ip: String, scanner: NetworkScanner) -> [Int] {
        let bundle = resolveEvidence(ip: ip, scanner: scanner)
        if let ports = bundle.host?.openPorts, !ports.isEmpty { return ports }
        if let ports = bundle.evidencePayload?.openPorts, !ports.isEmpty { return ports }
        if let ports = bundle.exportRecord?.ports, !ports.isEmpty { return ports }
        if let ports = bundle.auditEvidence?.ports, !ports.isEmpty { return ports }
        return []
    }
}
