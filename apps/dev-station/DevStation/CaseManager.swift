import Foundation
import AppKit

struct CaseIndex: Codable, Identifiable, Hashable {
    let id: String
    let targetType: String
    let targetID: String
    let createdAt: String
    var updatedAt: String
    var confidenceLevel: String
    var confidenceScore: Int
    var references: [String]
}

@MainActor
final class CaseManager: ObservableObject {
    static let shared = CaseManager()

    @Published private(set) var cases: [CaseIndex] = []

    private init() {
        refreshCases()
    }

    func refreshCases() {
        let base = StoragePaths.workspaceSubdir("cases")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            cases = []
            return
        }
        var found: [CaseIndex] = []
        for folder in items where folder.hasDirectoryPath {
            let indexURL = folder.appendingPathComponent("case.json")
            guard let data = try? Data(contentsOf: indexURL) else { continue }
            if let index = try? JSONDecoder().decode(CaseIndex.self, from: data) {
                found.append(index)
            }
        }
        cases = found.sorted { $0.updatedAt > $1.updatedAt }
    }

    func pinHost(ip: String, scanner: NetworkScanner, log: LogStore) {
        let base = StoragePaths.workspaceSubdir("cases")
        let targetID = LogStore.sanitizeFilename(ip)
        let caseDir = base.appendingPathComponent(targetID)
        ensureDirectory(caseDir, log: log)

        let references = collectHostReferences(ip: ip, log: log)
        copyReferences(references, to: caseDir, log: log)

        let bundle = AppTruth.shared.resolveEvidence(ip: ip, scanner: scanner)
        let confidence = bundle.host?.hostConfidence ?? HostConfidence(score: 0, level: .low, reasons: [])

        let now = ISO8601DateFormatter().string(from: Date())
        let index = CaseIndex(
            id: targetID,
            targetType: "ip",
            targetID: ip,
            createdAt: now,
            updatedAt: now,
            confidenceLevel: confidence.level.rawValue,
            confidenceScore: confidence.score,
            references: references
        )
        writeIndex(index, to: caseDir, log: log)
        refreshCases()
        log.log(.info, "Pinned case for IP \(ip) with \(references.count) references")
    }

    func pinBLE(fingerprintID: String, bleScanner: BLEScanner, log: LogStore) {
        let base = StoragePaths.workspaceSubdir("cases")
        let targetID = LogStore.sanitizeFilename(fingerprintID)
        let caseDir = base.appendingPathComponent(targetID)
        ensureDirectory(caseDir, log: log)

        let references = collectBLEReferences(fingerprintID: fingerprintID, log: log)
        copyReferences(references, to: caseDir, log: log)

        let confidence = bleScanner.peripherals.first(where: { $0.fingerprintID == fingerprintID })?.bleConfidence ?? BLEConfidence(score: 0, level: .low, reasons: [])
        let now = ISO8601DateFormatter().string(from: Date())
        let index = CaseIndex(
            id: targetID,
            targetType: "ble",
            targetID: fingerprintID,
            createdAt: now,
            updatedAt: now,
            confidenceLevel: confidence.level.rawValue,
            confidenceScore: confidence.score,
            references: references
        )
        writeIndex(index, to: caseDir, log: log)
        refreshCases()
        log.log(.info, "Pinned case for BLE \(fingerprintID) with \(references.count) references")
    }

    func openCaseFolder(_ index: CaseIndex) {
        let base = StoragePaths.workspaceSubdir("cases")
        let dir = base.appendingPathComponent(index.id)
        NSWorkspace.shared.open(dir)
    }

    func generateCaseReport(_ index: CaseIndex, log: LogStore) {
        let base = StoragePaths.workspaceSubdir("cases")
        let dir = base.appendingPathComponent(index.id)
        let iso = LogStore.isoTimestamp()
        let rawURL = dir.appendingPathComponent("CaseReportRaw-\(iso).json")
        let readableURL = dir.appendingPathComponent("CaseReportReadable-\(iso).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let rawData = try encoder.encode(index)
            try rawData.write(to: rawURL, options: [.atomic])
            Task.detached {
                _ = await ArtifactStore.shared.enqueueArtifact(rawURL, log: log)
            }
            let readable: [String: Any] = [
                "summary": "Case \(index.targetID) (\(index.targetType)) with \(index.references.count) referenced artifacts.",
                "target": ["type": index.targetType, "id": index.targetID],
                "confidence": ["level": index.confidenceLevel, "score": index.confidenceScore],
                "references": index.references,
                "rawRef": rawURL.lastPathComponent
            ]
            let readableData = try JSONSerialization.data(withJSONObject: readable, options: [.prettyPrinted, .sortedKeys])
            try readableData.write(to: readableURL, options: [.atomic])
            Task.detached {
                _ = await ArtifactStore.shared.enqueueArtifact(readableURL, log: log)
            }
            LogStore.revealAndOpen(readableURL)
            log.log(.info, "Case report generated: \(readableURL.path)")
        } catch {
            log.log(.error, "Failed to generate case report: \(error.localizedDescription)")
        }
    }

    func referencedInboxFiles() -> Set<String> {
        var refs = Set<String>()
        let inboxRoot = StoragePaths.inboxBase().path
        for item in cases {
            for path in item.references {
                if path.hasPrefix(inboxRoot) {
                    refs.insert(path)
                }
            }
        }
        return refs
    }

    private func collectHostReferences(ip: String, log: LogStore) -> [String] {
        var refs: [String] = []
        let evidenceDir = StoragePaths.inboxSubdir("evidence-raw")
        if let latest = latestFile(in: evidenceDir, prefix: "SODS-EvidenceRaw-\(LogStore.sanitizeFilename(ip))-") {
            refs.append(latest.path)
        }
        let hardProbeDir = StoragePaths.inboxSubdir("rtsp-hard-probe")
        if let folder = latestFolder(in: hardProbeDir, prefix: "\(LogStore.sanitizeFilename(ip))-") {
            refs.append(folder.path)
        }
        let deviceReadableDir = StoragePaths.reportsSubdir("device-readable")
        if let latest = latestFile(in: deviceReadableDir, prefix: "SODS-DeviceReportReadable-\(LogStore.sanitizeFilename(ip))-") {
            refs.append(latest.path)
        }
        return refs
    }

    private func collectBLEReferences(fingerprintID: String, log: LogStore) -> [String] {
        var refs: [String] = []
        let safeID = LogStore.sanitizeFilename(fingerprintID)
        let bleRawDir = StoragePaths.inboxSubdir("ble-raw")
        if let latest = latestFile(in: bleRawDir, prefix: "SODS-BLERaw-\(safeID)-") {
            refs.append(latest.path)
        }
        let deviceReadableDir = StoragePaths.reportsSubdir("device-readable")
        if let latest = latestFile(in: deviceReadableDir, prefix: "SODS-BLEReadable-\(safeID)-") {
            refs.append(latest.path)
        }
        if let latest = latestFile(in: bleRawDir, prefix: "SODS-BLEProbe-\(safeID)-") {
            refs.append(latest.path)
        }
        return refs
    }

    private func copyReferences(_ refs: [String], to caseDir: URL, log: LogStore) {
        for ref in refs {
            let src = URL(fileURLWithPath: ref)
            let dest = caseDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            do {
                try FileManager.default.linkItem(at: src, to: dest)
            } catch {
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                } catch {
                    log.log(.error, "Failed to copy \(src.path) to case: \(error.localizedDescription)")
                }
            }
        }
    }

    private func writeIndex(_ index: CaseIndex, to dir: URL, log: LogStore) {
        let url = dir.appendingPathComponent("case.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.log(.error, "Failed to write case index: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ dir: URL, log: LogStore) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.log(.error, "Failed to create case directory: \(error.localizedDescription)")
        }
    }

    private func latestFile(in dir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let matches = items.filter { $0.lastPathComponent.hasPrefix(prefix) }
        let sorted = matches.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    private func latestFolder(in dir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let matches = items.filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix(prefix) }
        let sorted = matches.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }
}
