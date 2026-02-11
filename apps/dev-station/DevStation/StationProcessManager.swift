import Foundation
import AppKit
import Darwin

@MainActor
final class StationProcessManager: ObservableObject {
    static let shared = StationProcessManager()

    private var process: Process?
    private var isStarting = false
    private var lastStartAttempt: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func ensureRunning(baseURL: String) {
        guard shouldManage(baseURL: baseURL) else { return }
        Task.detached {
            await self.tryEnsure(baseURL: baseURL)
        }
    }

    private func shouldManage(baseURL: String) -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        let host = (url.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "127.0.0.1" { return true }
        if host == "::1" { return true }

        // DevStation commonly uses a LAN-reachable Station URL (e.g. http://192.168.8.214:9123)
        // so other nodes can call back. If the host resolves to *this* Mac, we should still
        // manage the local Station process.
        if LocalHostInfo.shared.isLocalHost(host) { return true }

        return false
    }

    private func tryEnsure(baseURL: String) async {
        if await pingStatus(baseURL: baseURL) {
            return
        }
        await MainActor.run {
            if self.isStarting { return }
            if let last = self.lastStartAttempt, Date().timeIntervalSince(last) < 8 {
                return
            }
            self.isStarting = true
            self.lastStartAttempt = Date()
            self.startProcess(baseURL: baseURL)
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if await pingStatus(baseURL: baseURL) {
                await MainActor.run {
                    self.isStarting = false
                }
                return
            }
        }

        await MainActor.run {
            self.isStarting = false
        }
    }

    private func pingStatus(baseURL: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
        } catch {
            return false
        }
        return false
    }

    private func startProcess(baseURL: String) {
        stopProcess()
        guard let url = URL(string: baseURL) else { return }
        let port = url.port ?? 9123
        // Do not try to run Station on the Pi-Aux control plane listener port.
        // That port is owned by Dev Station (PiAuxServer) and will always EADDRINUSE.
        if port == PiAuxStore.shared.port {
            return
        }
        let piLogger = StationEndpointResolver.loggerURL(baseURL: baseURL)
        let root = sodsRootPath()
        let sodsTool = "\(root)/tools/sods"
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SODS")
        let logFile = logDir.appendingPathComponent("station.\(port).log")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "\"\(sodsTool)\" start --pi-logger \"\(piLogger)\" --port \(port)"
        ]

        let out = FileHandle(forWritingAtPath: logFile.path)
        process.standardOutput = out ?? FileHandle.nullDevice
        process.standardError = out ?? FileHandle.nullDevice

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }

    private func stopProcess() {
        process?.terminate()
        process = nil
    }

    @objc private func appWillTerminate() {
        stopProcess()
    }
}

private func sodsRootPath() -> String {
    StoragePaths.sodsRootPath()
}

private final class LocalHostInfo {
    static let shared = LocalHostInfo()

    private let lock = NSLock()
    private var cached: Set<String>?

    private init() {}

    func isLocalHost(_ host: String) -> Bool {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return false }
        let snapshot = knownLocalHosts()
        return snapshot.contains(cleaned)
    }

    private func knownLocalHosts() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var out: Set<String> = []
        out.insert("localhost")
        out.insert("127.0.0.1")
        out.insert("::1")

        // Hostnames
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !name.isEmpty {
            out.insert(name)
            out.insert("\(name).local")
        }
        if let envHost = ProcessInfo.processInfo.environment["HOSTNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !envHost.isEmpty {
            out.insert(envHost)
        }

        // Interface IPs
        for ip in LocalIPResolver.ipv4Addresses() {
            out.insert(ip.lowercased())
        }

        cached = out
        return out
    }
}

private enum LocalIPResolver {
    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoop = (flags & IFF_LOOPBACK) != 0
            if isUp, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), !isLoop {
                let addrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var ip = addrIn.sin_addr
                if inet_ntop(AF_INET, &ip, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let s = String(cString: buf)
                    if !s.isEmpty { result.append(s) }
                }
            }
            ptr = current.pointee.ifa_next
        }

        return Array(Set(result)).sorted()
    }
}
