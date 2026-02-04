import Foundation

struct InboxStatus {
    let totalBytes: Int64
    let fileCount: Int
    let oldest: Date?
    let newest: Date?
}

final class InboxRetention {
    static let shared = InboxRetention()
    private init() {}

    func currentStatus() -> InboxStatus {
        let files = listInboxFiles()
        let total = files.reduce(0) { $0 + $1.size }
        let oldest = files.map { $0.mtime }.min()
        let newest = files.map { $0.mtime }.max()
        return InboxStatus(totalBytes: total, fileCount: files.count, oldest: oldest, newest: newest)
    }

    func prune(days: Int, maxGB: Int, referenced: Set<String>, log: LogStore) {
        let files = listInboxFiles()
        guard !files.isEmpty else { return }
        let maxBytes = Int64(maxGB) * 1024 * 1024 * 1024
        let now = Date()
        let retentionDate = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let protectRecentDate = Calendar.current.date(byAdding: .hour, value: -24, to: now) ?? now

        var totalBytes = files.reduce(0) { $0 + $1.size }
        let sorted = files.sorted { $0.mtime < $1.mtime }

        for file in sorted {
            if referenced.contains(file.url.path) {
                log.log(.info, "Prune skipped (referenced): \(file.url.path)")
                continue
            }
            let isRecent = file.mtime >= protectRecentDate
            let beyondRetention = file.mtime < retentionDate
            let overSize = totalBytes > maxBytes

            if isRecent && !overSize {
                continue
            }
            if !beyondRetention && !overSize {
                continue
            }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalBytes -= file.size
                log.log(.info, "Pruned inbox file: \(file.url.path)")
            } catch {
                log.log(.error, "Failed to prune \(file.url.path): \(error.localizedDescription)")
            }
            if totalBytes <= maxBytes && !beyondRetention {
                continue
            }
        }
    }

    private struct InboxFile {
        let url: URL
        let size: Int64
        let mtime: Date
    }

    private func listInboxFiles() -> [InboxFile] {
        let base = StoragePaths.inboxBase()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [InboxFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date.distantPast
            results.append(InboxFile(url: url, size: size, mtime: mtime))
        }
        return results
    }
}
