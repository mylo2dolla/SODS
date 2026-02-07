import Foundation

struct CaseSessionManifest: Codable {
    let id: String
    let startedAt: String
    let endedAt: String
    let nodes: [String]
    let sources: [String]
    let evidenceRefs: [String]
}

struct CaseSessionReadable: Codable {
    let summary: String
    let confidence: String
    let evidenceRefs: [String]
    let rawRef: String
    let aliases: [String: String]
}

@MainActor
final class CaseSessionManager: ObservableObject {
    static let shared = CaseSessionManager()

    @Published private(set) var isActive = false
    @Published private(set) var startedAt: Date?
    @Published var selectedNodes: [String] = []
    @Published var selectedSources: [String] = []

    func start(nodes: [String], sources: [String]) {
        selectedNodes = nodes
        selectedSources = sources
        startedAt = Date()
        isActive = true
        LogStore.shared.log(.info, "Case session started nodes=\(nodes.joined(separator: ",")) sources=\(sources.joined(separator: ","))")
    }

    func stop(log: LogStore) {
        guard isActive, let startedAt else { return }
        let end = Date()
        let iso = LogStore.isoTimestamp()
        let id = "Session-\(iso)"
        let refs = collectEvidenceRefs(nodes: selectedNodes)
        let manifest = CaseSessionManifest(
            id: id,
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            endedAt: ISO8601DateFormatter().string(from: end),
            nodes: selectedNodes,
            sources: selectedSources,
            evidenceRefs: refs
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let rawData = try encoder.encode(manifest)
            let rawURL = LogStore.exportURL(subdir: "session-raw", filename: "SODS-SessionRaw-\(iso).json", log: log)
            _ = LogStore.writeDataReturning(rawData, to: rawURL, log: log)
            let aliasOverrides = IdentityResolver.shared.aliasMap()
            var aliases: [String: String] = [:]
            for node in selectedNodes {
                if let alias = aliasOverrides[node] {
                    aliases[node] = alias
                }
            }
            let readable = CaseSessionReadable(
                summary: "Case session with \(selectedNodes.count) nodes and \(selectedSources.count) sources.",
                confidence: "Operator-initiated session; evidence references are raw and append-only.",
                evidenceRefs: refs,
                rawRef: rawURL.lastPathComponent,
                aliases: aliases
            )
            let readableData = try encoder.encode(readable)
            let readableURL = LogStore.exportURL(subdir: "session-readable", filename: "SODS-SessionReadable-\(iso).json", log: log)
            _ = LogStore.writeDataReturning(readableData, to: readableURL, log: log)
            log.log(.info, "Case session ended: \(readableURL.path)")
        } catch {
            log.log(.error, "Failed to write session report: \(error.localizedDescription)")
        }
        isActive = false
        self.startedAt = nil
    }

    private func collectEvidenceRefs(nodes: [String]) -> [String] {
        var refs: [String] = []
        for node in nodes {
            if node.contains(".") {
                let safe = LogStore.sanitizeFilename(node)
                let dir = StoragePaths.inboxSubdir("evidence-raw")
                if let latest = latestFile(in: dir, prefix: "SODS-EvidenceRaw-\(safe)-") {
                    refs.append(latest.path)
                }
            } else {
                let safe = LogStore.sanitizeFilename(node)
                let dir = StoragePaths.inboxSubdir("ble-raw")
                if let latest = latestFile(in: dir, prefix: "SODS-BLERaw-\(safe)-") {
                    refs.append(latest.path)
                }
            }
        }
        return refs
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
}
