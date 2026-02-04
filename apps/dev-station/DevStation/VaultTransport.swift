import Foundation
import AppKit

enum VaultMethod: String, CaseIterable, Identifiable {
    case scp = "SSH_SCP"
    case rsync = "SSH_RSYNC"

    var id: String { rawValue }
}

@MainActor
final class VaultTransport: ObservableObject {
    static let shared = VaultTransport()

    @Published var host: String
    @Published var user: String
    @Published var destinationPath: String
    @Published var method: VaultMethod
    @Published var autoShipAfterExport: Bool
    @Published var lastShipTime: String = ""
    @Published var lastShipResult: String = ""
    @Published var queuedCount: Int = 0

    private init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "VaultHost") ?? "pi-logger.local"
        user = defaults.string(forKey: "VaultUser") ?? "pi"
        destinationPath = defaults.string(forKey: "VaultDestPath") ?? "/var/strangelab/vault/sods/"
        method = VaultMethod(rawValue: defaults.string(forKey: "VaultMethod") ?? "") ?? .scp
        autoShipAfterExport = defaults.object(forKey: "VaultAutoShipAfterExport") as? Bool ?? true
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "VaultHost")
        defaults.set(user, forKey: "VaultUser")
        defaults.set(destinationPath, forKey: "VaultDestPath")
        defaults.set(method.rawValue, forKey: "VaultMethod")
        defaults.set(autoShipAfterExport, forKey: "VaultAutoShipAfterExport")
    }

    func shipNow(log: LogStore) {
        Task.detached {
            await self.shipPending(log: log)
        }
    }

    func shipPending(log: LogStore) async {
        let outbox = ArtifactStore.outboxURL()
        let files = listFiles(in: outbox)
        await MainActor.run {
            self.queuedCount = files.count
            self.lastShipResult = "Shipping..."
        }
        log.log(.info, "Vault ship queued: \(files.count) files")
        for file in files {
            let dateFolder = dateFolderFor(file.url)
            let baseDest = destinationPath.appendingPathComponent(dateFolder, isDirectory: true)
            let filename = file.url.lastPathComponent
            let ensure = ensureRemoteDir(path: baseDest)
            if !ensure.success {
                let base = ensureRemoteDir(path: destinationPath)
                let retry = ensureRemoteDir(path: baseDest)
                if !(base.success && retry.success) {
                    let detail = [ensure.stderr, base.stderr, retry.stderr].filter { !$0.isEmpty }.joined(separator: " | ")
                    log.log(.error, "Vault ship error: failed to create \(baseDest) \(detail)")
                    await MainActor.run { self.lastShipResult = "Error creating remote dir" }
                    continue
                }
                await MainActor.run { self.lastShipResult = "" }
            }
            let destName = uniqueRemoteFilename(dir: baseDest, filename: filename)
            let remotePath = baseDest.appendingPathComponent(destName, isDirectory: false)
            let send = sendFile(local: file.url, remotePath: remotePath)
            if send.success {
                moveToShipped(file.url, log: log)
                log.log(.info, "Vault shipped: \(file.url.path) -> \(remotePath)")
                await MainActor.run {
                    self.lastShipTime = ISO8601DateFormatter().string(from: Date())
                    self.lastShipResult = "OK"
                }
            } else {
                let detail = send.stderr.isEmpty ? "" : " (\(send.stderr))"
                log.log(.error, "Vault ship error: \(file.url.path)\(detail)")
                await MainActor.run { self.lastShipResult = "Failed to ship one or more files" }
            }
        }
    }

    private func listFiles(in dir: URL) -> [FileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [FileEntry] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                results.append(FileEntry(url: url, mtime: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
        }
        return results
    }

    private struct FileEntry {
        let url: URL
        let mtime: Date
    }

    private func dateFolderFor(_ url: URL) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return formatter.string(from: date)
    }

    private func ensureRemoteDir(path: String) -> (success: Bool, stderr: String) {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)", "mkdir", "-p", path]
        let result = runProcess("/usr/bin/ssh", args: args)
        return (result.success, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func uniqueRemoteFilename(dir: String, filename: String) -> String {
        let remotePath = dir.appendingPathComponent(filename, isDirectory: false)
        if !remoteExists(path: remotePath) {
            return filename
        }
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        let suffix = String(UUID().uuidString.prefix(6))
        return ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
    }

    private func remoteExists(path: String) -> Bool {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)", "test", "-e", path]
        let result = runProcess("/usr/bin/ssh", args: args)
        return result.success
    }

    private func sendFile(local: URL, remotePath: String) -> (success: Bool, stderr: String) {
        switch method {
        case .scp:
            let args = ["-p", local.path, "\(user)@\(host):\(remotePath)"]
            let result = runProcess("/usr/bin/scp", args: args)
            return (result.success, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        case .rsync:
            let args = ["-a", "--times", local.path, "\(user)@\(host):\(remotePath)"]
            let result = runProcess("/usr/bin/rsync", args: args)
            return (result.success, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func moveToShipped(_ url: URL, log: LogStore) {
        let shippedDir = ArtifactStore.shippedURL()
        let dest = shippedDir.appendingPathComponent(url.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            let ext = dest.pathExtension
            let base = dest.deletingPathExtension().lastPathComponent
            let suffix = String(UUID().uuidString.prefix(6))
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            let unique = shippedDir.appendingPathComponent(name)
            try? fm.moveItem(at: url, to: unique)
            return
        }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            log.log(.error, "Failed to move to shipped: \(error.localizedDescription)")
        }
    }

    private func runProcess(_ path: String, args: [String]) -> (success: Bool, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "", error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, stdout, stderr)
    }
}

private extension String {
    func appendingPathComponent(_ component: String, isDirectory: Bool) -> String {
        if hasSuffix("/") {
            return self + component
        }
        return self + "/" + component
    }
}
