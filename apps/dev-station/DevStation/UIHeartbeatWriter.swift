import Foundation

@MainActor
final class UIHeartbeatWriter {
    static let shared = UIHeartbeatWriter()

    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatPath: String?

    private init() {}

    func startIfConfigured() {
        let configuredPath = ProcessInfo.processInfo.environment["SODS_UI_HEARTBEAT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let configuredPath, !configuredPath.isEmpty else {
            stop()
            return
        }
        guard heartbeatTask == nil, heartbeatPath != configuredPath else { return }

        heartbeatPath = configuredPath
        writeHeartbeat()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.intervalNanoseconds())
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.writeHeartbeat()
                }
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private static func intervalNanoseconds() -> UInt64 {
        let defaultMs: Double = 500
        let raw = ProcessInfo.processInfo.environment["SODS_UI_HEARTBEAT_INTERVAL_MS"]
        let parsed = raw.flatMap(Double.init) ?? defaultMs
        let clamped = max(200, min(2000, parsed))
        return UInt64(clamped * 1_000_000)
    }

    private func writeHeartbeat() {
        guard let heartbeatPath, !heartbeatPath.isEmpty else { return }
        let timestamp = String(format: "%.3f\n", Date().timeIntervalSince1970)
        do {
            try timestamp.write(toFile: heartbeatPath, atomically: true, encoding: .utf8)
        } catch {
            // Keep this silent; diagnostics should not interfere with operator workflow.
        }
    }
}
