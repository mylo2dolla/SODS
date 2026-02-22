import Foundation
import ScannerSpectrumCore

typealias NetworkScanner = ScannerSpectrumCore.LANScannerEngine
typealias ScanScope = ScannerSpectrumCore.ScanScope
typealias OnvifFetchReason = ScannerSpectrumCore.OnvifFetchReason
typealias IPv4Subnet = ScannerSpectrumCore.IPv4Subnet

extension NetworkScanner {
    func configureDevStationLogging(_ logStore: LogStore? = nil) {
        let sink = logStore ?? .shared
        configureLogger { level, message in
            switch level {
            case .info:
                sink.log(.info, message)
            case .warn:
                sink.log(.warn, message)
            case .error:
                sink.log(.error, message)
            }
        }
    }

    func buildAuditLog(logStore: LogStore? = nil) -> AuditLog? {
        let sink = logStore ?? .shared
        let summary = scanSummary()
        guard let start = summary.start, let end = summary.end else { return nil }
        let formatter = ISO8601DateFormatter()

        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) })
        let evidence: [AuditLog.Evidence] = allHosts.map { host in
            var services: [String] = []
            if host.openPorts.contains(80) || host.openPorts.contains(8080) || host.openPorts.contains(8000) {
                services.append("http")
            }
            if host.openPorts.contains(443) || host.openPorts.contains(8443) {
                services.append("https")
            }
            if host.openPorts.contains(554) {
                services.append("rtsp")
            }
            if host.openPorts.contains(3702) {
                services.append("onvif")
            }
            if let device = deviceMap[host.ip], let title = device.httpTitle, !title.isEmpty {
                services.append("http-title:\(title)")
            } else if let title = host.httpTitle, !title.isEmpty {
                services.append("http-title:\(title)")
            }
            return AuditLog.Evidence(
                ip: host.ip,
                mac: host.macAddress ?? "",
                vendor: host.vendor ?? "",
                vendorConfidenceScore: host.vendorConfidenceScore,
                vendorConfidenceReasons: host.vendorConfidenceReasons,
                hostConfidence: host.hostConfidence,
                services: services,
                ports: host.openPorts,
                hostname: host.hostname,
                ssdpServer: host.ssdpServer ?? "",
                ssdpLocation: host.ssdpLocation ?? "",
                ssdpST: host.ssdpST ?? "",
                ssdpUSN: host.ssdpUSN ?? "",
                bonjourServices: host.bonjourServices,
                httpStatus: host.httpStatus,
                httpServer: host.httpServer ?? "",
                httpAuth: host.httpAuth ?? "",
                httpTitle: host.httpTitle ?? ""
            )
        }

        return AuditLog(
            exportedAt: formatter.string(from: Date()),
            scanScope: summary.scope,
            startTime: formatter.string(from: start),
            endTime: formatter.string(from: end),
            totalIPs: summary.totalIPs,
            aliveCount: summary.aliveCount,
            interestingCount: summary.interestingCount,
            evidences: evidence,
            bleDevices: BLEScanner.shared.snapshotEvidence(),
            bleProbeResults: BLEProber.shared.snapshotProbeResults(),
            piAuxEvidence: PiAuxStore.shared.events,
            logLines: sink.lines.map { $0.formatted }
        )
    }

    func buildExportSnapshot() -> ExportSnapshot? {
        let summary = scanSummary()
        guard let start = summary.start else { return nil }
        let formatter = ISO8601DateFormatter()
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) })

        let records: [ExportRecord] = allHosts.map { host in
            let device = deviceMap[host.ip]
            return ExportRecord(
                ip: host.ip,
                status: host.isAlive ? "Alive" : "No Response",
                ports: host.openPorts,
                hostname: host.hostname ?? "",
                mac: host.macAddress ?? "",
                vendor: host.vendor ?? "",
                vendorConfidenceScore: host.vendorConfidenceScore,
                vendorConfidenceReasons: host.vendorConfidenceReasons,
                hostConfidence: host.hostConfidence,
                ssdpServer: host.ssdpServer ?? "",
                ssdpLocation: host.ssdpLocation ?? "",
                ssdpST: host.ssdpST ?? "",
                ssdpUSN: host.ssdpUSN ?? "",
                bonjourServices: host.bonjourServices,
                httpStatus: host.httpStatus,
                httpServer: host.httpServer ?? "",
                httpAuth: host.httpAuth ?? "",
                httpTitle: host.httpTitle ?? "",
                onvif: device?.discoveredViaOnvif ?? false,
                rtspURI: device?.onvifRtspURI ?? ""
            )
        }

        return ExportSnapshot(timestamp: formatter.string(from: start), records: records)
    }

    func applyManualRTSPProbeResults(forIP ip: String, results: [RTSPProbeResult]) {
        applyManualRtspProbeResults(forIP: ip, results: results)
    }
}

struct ExportRecord: Codable {
    let ip: String
    let status: String
    let ports: [Int]
    let hostname: String
    let mac: String
    let vendor: String
    let vendorConfidenceScore: Int
    let vendorConfidenceReasons: [String]
    let hostConfidence: HostConfidence
    let ssdpServer: String
    let ssdpLocation: String
    let ssdpST: String
    let ssdpUSN: String
    let bonjourServices: [BonjourService]
    let httpStatus: Int?
    let httpServer: String
    let httpAuth: String
    let httpTitle: String
    let onvif: Bool
    let rtspURI: String
}

struct ExportSnapshot: Codable {
    let timestamp: String
    let records: [ExportRecord]
}
