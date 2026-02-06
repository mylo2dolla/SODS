import Foundation
import AppKit
import Network

@MainActor
struct RTSPHardProbe {
    struct Report: Codable {
        let timestamp: String
        let status: String
        let reason: String?
        let ip: String
        let alias: String?
        let port: Int
        let safeMode: Bool
        let tcpReachable: Bool
        let rtspURIRedacted: String
        let attemptedVariants: [String]
        let nextLikelyCauses: [String]
    }

    static func run(device: Device, log: LogStore, safeMode: Bool, selectedIP: String) {
        let rtspURI = device.onvifRtspURI
        let rtspState = (rtspURI?.isEmpty == false) ? "present" : "missing"
        log.log(.info, "HardProbe click: ip=\(device.ip) safeMode=\(safeMode) rtspURI=\(rtspState) selectedIP=\(selectedIP)")
        let alias = SODSStore.shared.aliasOverrides[device.ip]
        let iso = LogStore.isoTimestamp()
        let baseDir = LogStore.exportSubdirectory("rtsp-hard-probe", log: log)
        let safeIP = LogStore.sanitizeFilename(device.ip)
        let folder = baseDir.appendingPathComponent("\(safeIP)-\(iso)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.log(.error, "Hard probe failed to create folder: \(error.localizedDescription)")
            return
        }

        let redacted = rtspURI.map(redact) ?? "missing"
        let (ip, port) = parseIPAndPort(rtspURI: rtspURI ?? "", fallbackIP: device.ip)
        log.log(.info, "Hard probe started ip=\(ip) folder=\(folder.path) selectedIP=\(selectedIP)")
        NSWorkspace.shared.activateFileViewerSelecting([folder])

        if safeMode || rtspURI == nil || rtspURI?.isEmpty == true {
            let reason = safeMode ? "Safe Mode enabled" : "Missing RTSP URI"
            let report = Report(
                timestamp: iso,
                status: "blocked",
                reason: reason,
                ip: ip,
                alias: alias,
                port: port,
                safeMode: safeMode,
                tcpReachable: false,
                rtspURIRedacted: redacted,
                attemptedVariants: [],
                nextLikelyCauses: [
                    "Authentication required",
                    "Wrong profile or path",
                    "Codec or transport mismatch",
                    "Camera limiting concurrent sessions"
                ]
            )
            writeReport(report, folder: folder, safeIP: safeIP, iso: iso, log: log)
            log.log(.warn, "Hard probe blocked ip=\(ip) reason=\(reason) folder=\(folder.path)")
            return
        }

        Task.detached {
            let reachable = await tcpCheck(host: ip, port: port, timeout: 0.8)
            var logFiles: [String] = []
            let vlcInstalled = FileManager.default.fileExists(atPath: "/Applications/VLC.app")
            if !vlcInstalled {
                log.log(.error, "VLC not installed; hard probe will only record diagnostics")
            } else {
                let variants: [[String]] = [
                    ["--rtsp-tcp", "--network-caching=1500", "-vvv", "--file-logging"],
                    ["--rtsp-tcp", "--network-caching=3000", "-vvv", "--file-logging"],
                    ["--rtsp-tcp", "--network-caching=3000", "--no-audio", "-vvv", "--file-logging"]
                ]
                for (idx, args) in variants.enumerated() {
                    let logName = "vlc-\(idx + 1)-\(iso).log"
                    let logURL = folder.appendingPathComponent(logName)
                    logFiles.append(logURL.path)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    var fullArgs = ["-a", "VLC", "--args"]
                    fullArgs.append(contentsOf: args)
                    fullArgs.append(contentsOf: ["--logfile", logURL.path, rtspURI ?? ""])
                    process.arguments = fullArgs
                    do {
                        try process.run()
                    } catch {
                        log.log(.error, "Hard probe VLC launch failed: \(error.localizedDescription)")
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }

            let status = vlcInstalled ? "started" : "failed"
            let reason = vlcInstalled ? nil : "VLC not installed"
            let report = Report(
                timestamp: iso,
                status: status,
                reason: reason,
                ip: ip,
                alias: alias,
                port: port,
                safeMode: safeMode,
                tcpReachable: reachable,
                rtspURIRedacted: redacted,
                attemptedVariants: logFiles,
                nextLikelyCauses: [
                    "Authentication required",
                    "Wrong profile or path",
                    "Codec or transport mismatch",
                    "Camera limiting concurrent sessions"
                ]
            )

            writeReport(report, folder: folder, safeIP: safeIP, iso: iso, log: log)
            log.log(.info, "Hard probe finished ip=\(ip) folder=\(folder.path)")
        }
    }

    static func revealFolder(for device: Device, log: LogStore) {
        let baseDir = LogStore.exportSubdirectory("rtsp-hard-probe", log: log)
        let safeIP = LogStore.sanitizeFilename(device.ip)
        if let url = latestFolder(baseDir: baseDir, prefix: safeIP) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            log.log(.warn, "No hard probe folder found for \(device.ip)")
        }
    }

    static func latestReportURL(for ip: String, log: LogStore) -> URL? {
        let baseDir = LogStore.exportSubdirectory("rtsp-hard-probe", log: log)
        let safeIP = LogStore.sanitizeFilename(ip)
        guard let folder = latestFolder(baseDir: baseDir, prefix: safeIP) else { return nil }
        return latestReport(in: folder, prefix: "HardProbe-\(safeIP)-")
    }

    private static func latestFolder(baseDir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let matches = items.filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
        let sorted = matches.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    private static func latestReport(in folder: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let matches = items.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension.lowercased() == "json" }
        let sorted = matches.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    private static func parseIPAndPort(rtspURI: String, fallbackIP: String) -> (String, Int) {
        if let url = URL(string: rtspURI), let host = url.host {
            let port = url.port ?? 554
            return (host, port)
        }
        return (fallbackIP, 554)
    }

    private static func redact(_ uri: String) -> String {
        let pattern = #"(rtsp://)([^/@:]+):([^/@]+)@"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return uri }
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        return regex.stringByReplacingMatches(in: uri, options: [], range: range, withTemplate: "$1***:***@")
    }

    nonisolated private static func writeReport(_ report: Report, folder: URL, safeIP: String, iso: String, log: LogStore) {
        let reportURL = folder.appendingPathComponent("HardProbe-\(safeIP)-\(iso).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: [.atomic])
            Task.detached {
                _ = await ArtifactStore.shared.enqueueArtifact(reportURL, log: log)
                await ArtifactStore.shared.runCleanup(log: log)
                await MainActor.run {
                    if VaultTransport.shared.autoShipAfterExport {
                        VaultTransport.shared.shipNow(log: log)
                    }
                }
            }
        } catch {
            log.log(.error, "Hard probe report write failed: \(error.localizedDescription)")
        }
    }

    private static func tcpCheck(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        let endpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: UInt16(port)) ?? 554
        let connection = NWConnection(host: endpoint, port: portEndpoint, using: .tcp)
        final class CompletionFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func complete() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let flag = CompletionFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if flag.complete() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed:
                    if flag.complete() {
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if flag.complete() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
