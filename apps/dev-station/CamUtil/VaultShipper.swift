import Foundation
import CryptoKit
import AppKit

struct VaultManifestRecord: Codable, Hashable {
    let path: String
    let size: Int64
    let mtime: Double
    let sha256: String
}

@MainActor
final class VaultShipper: ObservableObject {
    static let shared = VaultShipper()

    @Published var host: String
    @Published var user: String
    @Published var basePath: String
    @Published var autoShip: Bool
    @Published var intervalMinutes: Int
    @Published var lastSuccess: String = ""
    @Published var lastError: String = ""
    @Published var status: String = "Idle"

    private var timer: Timer?
    private let manifestURL: URL
    private var shippedHashes: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "VaultHost") ?? "pi-logger.local"
        user = defaults.string(forKey: "VaultUser") ?? "pi"
        basePath = defaults.string(forKey: "VaultBasePath") ?? "/mnt/vault/StrangeLab/"
        autoShip = defaults.object(forKey: "VaultAutoShip") as? Bool ?? true
        intervalMinutes = defaults.object(forKey: "VaultInterval") as? Int ?? 5
        manifestURL = StoragePaths.shipperBase().appendingPathComponent("manifest.jsonl")
        loadManifest()
        configureTimer()
    }

    func updateSettings() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "VaultHost")
        defaults.set(user, forKey: "VaultUser")
        defaults.set(basePath, forKey: "VaultBasePath")
        defaults.set(autoShip, forKey: "VaultAutoShip")
        defaults.set(intervalMinutes, forKey: "VaultInterval")
        configureTimer()
    }

    func testConnection(log: LogStore) {
        status = "Testing..."
        let result = runProcess("/usr/bin/ssh", args: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)", "echo", "ok"])
        if result.success {
            status = "Connected"
            lastError = ""
            log.log(.info, "Vault connection OK")
        } else {
            status = "Error"
            lastError = result.stderr
            log.log(.error, "Vault connection failed: \(result.stderr)")
        }
    }

    func shipNow(log: LogStore) {
        Task.detached {
            await self.shipAll(log: log)
        }
    }

    func shipCase(caseIndex: CaseIndex, log: LogStore) {
        Task.detached {
            let base = StoragePaths.workspaceSubdir("cases")
            let dir = base.appendingPathComponent(caseIndex.id)
            await self.shipPaths([dir], log: log)
        }
    }

    func revealShipperState() {
        NSWorkspace.shared.open(StoragePaths.shipperBase())
    }

    private func configureTimer() {
        timer?.invalidate()
        guard autoShip else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, intervalMinutes) * 60), repeats: true) { _ in
            Task { @MainActor in
                LogStore.shared.log(.info, "Vault auto-ship tick")
            }
            Task.detached { [weak self] in
                guard let self else { return }
                await self.shipAll(log: LogStore.shared)
            }
        }
    }

    private func shipAll(log: LogStore) async {
        let roots = [StoragePaths.inboxBase(), StoragePaths.workspaceBase(), StoragePaths.reportsBase()]
        await shipPaths(roots, log: log)
    }

    private func shipPaths(_ roots: [URL], log: LogStore) async {
        status = "Shipping..."
        let files = collectFiles(roots: roots)
        log.log(.info, "Vault ship queued: \(files.count) files")
        var shippedCount = 0
        for file in files {
            guard let record = makeRecord(file) else { continue }
            let key = record.sha256
            if shippedHashes.contains(key) {
                log.log(.info, "Vault skipped (already shipped): \(record.path)")
                continue
            }
            let relative = relativePath(file)
            let destDir = basePath.appending(relative.dir)
            let destPath = basePath.appending(relative.full)
            let ok = ensureRemoteDir(destDir)
            if !ok {
                log.log(.error, "Vault ship error: failed to create \(destDir)")
                lastError = "Failed to create remote directory"
                status = "Error"
                continue
            }
            if sendFile(file, destPath: destPath) {
                appendManifest(record)
                shippedHashes.insert(key)
                shippedCount += 1
                log.log(.info, "Vault shipped: \(record.path) -> \(destPath)")
            } else {
                log.log(.error, "Vault ship error: \(record.path)")
                lastError = "Failed to ship \(record.path)"
                status = "Error"
            }
        }
        if shippedCount > 0 {
            lastSuccess = ISO8601DateFormatter().string(from: Date())
            status = "Idle"
        } else if lastError.isEmpty {
            status = "Idle"
        }
    }

    private func collectFiles(roots: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(url)
                }
            }
        }
        return files
    }

    private func makeRecord(_ url: URL) -> VaultManifestRecord? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = Int64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let hash = sha256(of: url) else { return nil }
        return VaultManifestRecord(path: url.path, size: size, mtime: mtime, sha256: hash)
    }

    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(_ url: URL) -> (full: String, dir: String) {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("StrangeLab")
        let path = url.path
        let basePath = base.path
        let rel = path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
        let dir = (rel as NSString).deletingLastPathComponent
        return (full: rel, dir: dir)
    }

    private func ensureRemoteDir(_ path: String) -> Bool {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)", "mkdir", "-p", path]
        let result = runProcess("/usr/bin/ssh", args: args)
        return result.success
    }

    private func sendFile(_ local: URL, destPath: String) -> Bool {
        let rsyncPath = "/usr/bin/rsync"
        if FileManager.default.fileExists(atPath: rsyncPath) {
            let dest = "\(user)@\(host):\(destPath)"
            let result = runProcess(rsyncPath, args: ["-a", local.path, dest])
            return result.success
        }
        let dest = "\(user)@\(host):\(destPath)"
        let result = runProcess("/usr/bin/scp", args: [local.path, dest])
        return result.success
    }

    private func loadManifest() {
        shippedHashes.removeAll()
        guard let text = try? String(contentsOf: manifestURL) else { return }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let record = try? JSONDecoder().decode(VaultManifestRecord.self, from: data) {
                shippedHashes.insert(record.sha256)
            }
        }
    }

    private func appendManifest(_ record: VaultManifestRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        guard let line = String(data: data, encoding: .utf8) else { return }
        let entry = line + "\n"
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            if let handle = try? FileHandle(forWritingTo: manifestURL) {
                handle.seekToEndOfFile()
                handle.write(entry.data(using: .utf8) ?? Data())
                try? handle.close()
                return
            }
        }
        try? entry.write(to: manifestURL, atomically: true, encoding: .utf8)
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
    func appending(_ path: String) -> String {
        if hasSuffix("/") {
            return self + path
        }
        return self + "/" + path
    }
}
