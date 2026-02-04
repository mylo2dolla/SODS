import Foundation

actor ArtifactStore {
    static let shared = ArtifactStore()

    private let fm = FileManager.default

    private init() {
        Self.ensureDirectories()
    }

    static func inboxURL() -> URL {
        StoragePaths.inboxBase()
    }

    static func outboxURL() -> URL {
        StoragePaths.ensureSubdir(base: StoragePaths.shipperBase(), name: "outbox")
    }

    static func shippedURL() -> URL {
        StoragePaths.ensureSubdir(base: StoragePaths.shipperBase(), name: "shipped")
    }

    static func stateURL() -> URL {
        StoragePaths.shipperBase()
    }

    static func ensureDirectories() {
        let dirs = [inboxURL(), outboxURL(), shippedURL(), stateURL()]
        let fm = FileManager.default
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func enqueueArtifact(_ url: URL, log: LogStore) async -> URL? {
        Self.ensureDirectories()
        let filename = url.lastPathComponent
        let outboxDest = uniqueDestination(in: ArtifactStore.outboxURL(), filename: filename)
        do {
            try fm.copyItem(at: url, to: outboxDest)
            log.log(.info, "Enqueued artifact to outbox: \(outboxDest.path)")
            return outboxDest
        } catch {
            log.log(.error, "Failed to enqueue artifact \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    func runCleanup(log: LogStore) async {
        Self.ensureDirectories()
        let defaults = UserDefaults.standard
        let days = max(1, defaults.integer(forKey: "inboxRetentionDays") == 0 ? 14 : defaults.integer(forKey: "inboxRetentionDays"))
        let maxGB = max(1, defaults.integer(forKey: "inboxMaxGB") == 0 ? 10 : defaults.integer(forKey: "inboxMaxGB"))
        let referenced = await MainActor.run { CaseManager.shared.referencedInboxFiles() }
        InboxRetention.shared.prune(days: days, maxGB: maxGB, referenced: referenced, log: log)
    }

    private func uniqueDestination(in dir: URL, filename: String) -> URL {
        var candidate = dir.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        let suffix = String(UUID().uuidString.prefix(8))
        let newName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        candidate = dir.appendingPathComponent(newName)
        return candidate
    }

}
