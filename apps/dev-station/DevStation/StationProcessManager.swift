import Foundation
import AppKit

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
        let host = url.host ?? ""
        return host == "localhost" || host == "127.0.0.1"
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
        let piLogger = StationEndpointResolver.loggerURL(baseURL: baseURL)
        let root = sodsRootPath()
        let sodsTool = "\(root)/tools/sods"
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SODS")
        let logFile = logDir.appendingPathComponent("station.log")
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
