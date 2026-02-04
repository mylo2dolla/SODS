import Foundation
import AppKit

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let timestamp: String
    let level: LogLevel
    let message: String

    var formatted: String {
        "\(timestamp) [\(level.rawValue)] \(message)"
    }
}

struct AuditLog: Codable {
    struct Evidence: Codable {
        let ip: String
        let mac: String
        let vendor: String
        let vendorConfidenceScore: Int
        let vendorConfidenceReasons: [String]
        let hostConfidence: HostConfidence
        let services: [String]
        let ports: [Int]
        let hostname: String?
        let ssdpServer: String
        let ssdpLocation: String
        let ssdpST: String
        let ssdpUSN: String
        let bonjourServices: [BonjourService]
        let httpStatus: Int?
        let httpServer: String
        let httpAuth: String
        let httpTitle: String
    }

    let exportedAt: String
    let scanScope: String
    let startTime: String
    let endTime: String
    let totalIPs: Int
    let aliveCount: Int
    let interestingCount: Int
    let evidences: [Evidence]
    let bleDevices: [BLEEvidence]
    let bleProbeResults: [BLEProbeResult]
    let piAuxEvidence: [PiAuxEvent]
    let logLines: [String]
}

struct ReadableAuditLog: Codable {
    struct Meta: Codable {
        let isoTimestamp: String
        let appVersion: String
        let buildNumber: String
    }

    struct Summary: Codable {
        let totalHosts: Int
        let aliveHosts: Int
        let interestingHosts: Int
        let evidenceCount: Int
        let highConfidenceHosts: Int
        let bleDevices: Int
        let piAuxEvents: Int
        let topHosts: [String]
        let topBLE: [String]
        let warnings: Int
        let errors: Int
    }

    struct RawRef: Codable {
        let filename: String
    }

    let meta: Meta
    let rawRef: RawRef
    let summary: Summary
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var lines: [LogLine] = []

    private let maxLines = 500
    private let formatter: DateFormatter

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.formatter = formatter
    }

    nonisolated func log(_ level: LogLevel, _ message: String) {
        Task { @MainActor in
            self.append(level, message)
        }
    }

    nonisolated static func logAsync(_ level: LogLevel, _ message: String) {
        Task { @MainActor in
            LogStore.shared.append(level, message)
        }
    }

    func clear() {
        lines.removeAll()
    }

    func copyAllText() -> String {
        lines.map { $0.formatted }.joined(separator: "\n")
    }

    func exportAuditLog(_ audit: AuditLog) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(audit)
            let iso = LogStore.isoTimestamp()
            let auditFilename = "SODS-Audit-\(iso).json"
            let auditURL = LogStore.exportURL(subdir: "logs", filename: auditFilename, log: self)
            _ = LogStore.writeDataReturning(data, to: auditURL, log: self)

            let rawFilename = "SODS-AuditRaw-\(iso).json"
            let rawURL = LogStore.exportURL(subdir: "audit-raw", filename: rawFilename, log: self)
            _ = LogStore.writeDataReturning(data, to: rawURL, log: self)

            let readable = LogStore.makeReadableAudit(audit: audit, rawFilename: rawFilename)
            let readableData = try encoder.encode(readable)
            let readableFilename = "SODS-AuditReadable-\(iso).json"
            let readableURL = LogStore.exportURL(subdir: "audit-readable", filename: readableFilename, log: self)
            if let url = LogStore.writeDataReturning(readableData, to: readableURL, log: self) {
                let summary = [
                    "Audit export readable",
                    "Total hosts: \(readable.summary.totalHosts)",
                    "Alive: \(readable.summary.aliveHosts)",
                    "Interesting: \(readable.summary.interestingHosts)",
                    "High confidence: \(readable.summary.highConfidenceHosts)",
                    "BLE devices: \(readable.summary.bleDevices)"
                ].joined(separator: "\n")
                LogStore.copyExportSummaryToClipboard(path: url.path, summary: summary)
                self.log(.info, "Audit export copied to clipboard")
            }
        } catch {
            self.log(.error, "Failed to export audit log: \(error.localizedDescription)")
        }
    }

    private func append(_ level: LogLevel, _ message: String) {
        let line = LogLine(timestamp: formatter.string(from: Date()), level: level, message: message)
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        Task.detached {
            await DailyLogManager.shared.append(line)
        }
    }

    private func isoTimestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    static func exportBaseDirectory(log: LogStore? = nil) -> URL {
        StoragePaths.reportsBase()
    }

    static func exportSubdirectory(_ name: String, log: LogStore? = nil) -> URL {
        let target = exportTarget(for: name)
        switch target.base {
        case .inbox:
            return StoragePaths.inboxSubdir(target.subpath)
        case .workspace:
            return StoragePaths.workspaceSubdir(target.subpath)
        case .reports:
            return StoragePaths.reportsSubdir(target.subpath)
        case .shipper:
            return StoragePaths.shipperBase()
        }
    }

    static func exportURL(subdir: String, filename: String, log: LogStore? = nil) -> URL {
        exportSubdirectory(subdir, log: log).appendingPathComponent(filename)
    }

    private enum ExportBase {
        case inbox
        case workspace
        case reports
        case shipper
    }

    private struct ExportTarget {
        let base: ExportBase
        let subpath: String
    }

    private static func exportTarget(for subdir: String) -> ExportTarget {
        switch subdir {
        case "evidence-raw":
            return ExportTarget(base: .inbox, subpath: "evidence-raw")
        case "ble-raw":
            return ExportTarget(base: .inbox, subpath: "ble-raw")
        case "logs-raw":
            return ExportTarget(base: .inbox, subpath: "logs-raw")
        case "audit-raw":
            return ExportTarget(base: .inbox, subpath: "audit-raw")
        case "rtsp-hard-probe":
            return ExportTarget(base: .inbox, subpath: "rtsp-hard-probe")
        case "ble-probes":
            return ExportTarget(base: .inbox, subpath: "ble-raw")
        case "daily-raw":
            return ExportTarget(base: .reports, subpath: "daily-raw")
        case "daily-readable":
            return ExportTarget(base: .reports, subpath: "daily-readable")
        case "device-report-raw":
            return ExportTarget(base: .reports, subpath: "device-raw")
        case "device-report-readable":
            return ExportTarget(base: .reports, subpath: "device-readable")
        case "scan-report-raw":
            return ExportTarget(base: .reports, subpath: "scan-raw")
        case "scan-report-readable":
            return ExportTarget(base: .reports, subpath: "scan-readable")
        case "audit-readable":
            return ExportTarget(base: .reports, subpath: "audit-readable")
        case "session-raw":
            return ExportTarget(base: .reports, subpath: "session-raw")
        case "session-readable":
            return ExportTarget(base: .reports, subpath: "session-readable")
        case "logs":
            return ExportTarget(base: .reports, subpath: "audit-raw")
        case "evidence-readable":
            return ExportTarget(base: .reports, subpath: "device-readable")
        case "ble-readable":
            return ExportTarget(base: .reports, subpath: "device-readable")
        case "logs-readable":
            return ExportTarget(base: .reports, subpath: "scan-readable")
        default:
            return ExportTarget(base: .reports, subpath: subdir)
        }
    }

    static func isoTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    static func writeData(_ data: Data, to url: URL, log: LogStore? = nil) {
        do {
            try data.write(to: url, options: [.atomic])
            log?.log(.info, "Exported file to \(url.path)")
            revealAndOpen(url)
        } catch {
            log?.log(.error, "Export failed: \(error.localizedDescription)")
        }
    }

    static func writeString(_ text: String, to url: URL, log: LogStore? = nil) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            log?.log(.info, "Exported file to \(url.path)")
            revealAndOpen(url)
            postExport(url, log: log)
        } catch {
            log?.log(.error, "Export failed: \(error.localizedDescription)")
        }
    }

    static func writeDataReturning(_ data: Data, to url: URL, log: LogStore? = nil) -> URL? {
        do {
            try data.write(to: url, options: [.atomic])
            log?.log(.info, "Exported file to \(url.path)")
            revealAndOpen(url)
            postExport(url, log: log)
            return url
        } catch {
            log?.log(.error, "Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func writeStringReturning(_ text: String, to url: URL, log: LogStore? = nil) -> URL? {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            log?.log(.info, "Exported file to \(url.path)")
            revealAndOpen(url)
            postExport(url, log: log)
            return url
        } catch {
            log?.log(.error, "Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func postExport(_ url: URL, log: LogStore?) {
        let logger = log ?? LogStore.shared
        Task.detached {
            _ = await ArtifactStore.shared.enqueueArtifact(url, log: logger)
            await ArtifactStore.shared.runCleanup(log: logger)
            await MainActor.run {
                if VaultTransport.shared.autoShipAfterExport {
                    VaultTransport.shared.shipNow(log: logger)
                }
            }
        }
    }

    static func revealAndOpen(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSWorkspace.shared.open(url)
    }

    static func copyExportSummaryToClipboard(path: String, summary: String) {
        let lines = summary.split(separator: "\n").prefix(10).joined(separator: "\n")
        let text = "Path: \(path)\n\(lines)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func latestAuditURL(log: LogStore? = nil) -> URL? {
        let dir = exportSubdirectory("logs", log: log)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let audits = items.filter { $0.lastPathComponent.hasPrefix("SODS-Audit-") && $0.pathExtension.lowercased() == "json" }
        let sorted = audits.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    static func latestReadableAuditURL(log: LogStore? = nil) -> URL? {
        let dir = exportSubdirectory("audit-readable", log: log)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let audits = items.filter { $0.lastPathComponent.hasPrefix("SODS-AuditReadable-") && $0.pathExtension.lowercased() == "json" }
        let sorted = audits.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    static func latestReadableScanReportURL(log: LogStore? = nil) -> URL? {
        let dir = exportSubdirectory("scan-report-readable", log: log)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let reports = items.filter { $0.lastPathComponent.hasPrefix("SODS-ScanReportReadable-") && $0.pathExtension.lowercased() == "json" }
        let sorted = reports.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    static func sanitizeFilename(_ value: String) -> String {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        return value.map { allowed.contains($0) ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    static func makeReadableAudit(audit: AuditLog, rawFilename: String) -> ReadableAuditLog {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let high = audit.evidences.filter { $0.hostConfidence.level == .high }.count
        let warnings = audit.logLines.filter { $0.contains("[WARN]") }.count
        let errors = audit.logLines.filter { $0.contains("[ERROR]") }.count
        let topHosts = audit.evidences
            .sorted { $0.hostConfidence.score > $1.hostConfidence.score }
            .prefix(5)
            .map { "\($0.ip) \(String($0.hostConfidence.level.rawValue)) (\($0.hostConfidence.score))" }
        let topBLE = audit.bleDevices
            .sorted { $0.rssi > $1.rssi }
            .prefix(5)
            .map { "\($0.name) (\($0.rssi) dBm)" }
        return ReadableAuditLog(
            meta: .init(isoTimestamp: isoTimestamp(), appVersion: version, buildNumber: build),
            rawRef: .init(filename: rawFilename),
            summary: .init(
                totalHosts: audit.totalIPs,
                aliveHosts: audit.aliveCount,
                interestingHosts: audit.interestingCount,
                evidenceCount: audit.evidences.count,
                highConfidenceHosts: high,
                bleDevices: audit.bleDevices.count,
                piAuxEvents: audit.piAuxEvidence.count,
                topHosts: topHosts,
                topBLE: topBLE,
                warnings: warnings,
                errors: errors
            )
        )
    }
}
