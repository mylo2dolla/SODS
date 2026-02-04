import Foundation

final class VLCLauncher {
    static let shared = VLCLauncher()

    private let vlcPath = "/Applications/VLC.app"
    private var cachedAvailable: Bool?
    private var loggedMissing = false

    private init() {}

    func isAvailable(log: LogStore) -> Bool {
        if let cached = cachedAvailable {
            if !cached && !loggedMissing {
                loggedMissing = true
                log.log(.warn, "VLC not installed at /Applications/VLC.app")
            }
            return cached
        }
        let exists = FileManager.default.fileExists(atPath: vlcPath)
        cachedAvailable = exists
        if !exists && !loggedMissing {
            loggedMissing = true
            log.log(.warn, "VLC not installed at /Applications/VLC.app")
        }
        return exists
    }

    func open(url: String, log: LogStore, deviceIP: String) {
        guard isAvailable(log: log) else {
            log.log(.warn, "VLC unavailable: cannot open RTSP for \(deviceIP)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "VLC", url]
        do {
            try process.run()
            log.log(.info, "Launched VLC for \(deviceIP): \(url)")
        } catch {
            log.log(.error, "Failed to launch VLC for \(deviceIP): \(error.localizedDescription)")
        }
    }
}
