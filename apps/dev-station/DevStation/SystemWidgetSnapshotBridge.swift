import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

final class SystemWidgetSnapshotBridge {
    static let shared = SystemWidgetSnapshotBridge()

    static let appGroupID = "group.com.strangelab.sods.devstation"
    static let widgetKind = "DevStationSystemStatusWidget"
    static let snapshotFilename = "system-status-snapshot.json"

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let reloadDebounceSeconds: TimeInterval
    private var lastReloadAt: Date?

    init(reloadDebounceSeconds: TimeInterval = 30) {
        self.reloadDebounceSeconds = reloadDebounceSeconds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func persist(snapshot: SystemSnapshot, forceReload: Bool) {
        guard let url = snapshotURL() else { return }
        do {
            try write(snapshot: snapshot, to: url)
            requestReload(force: forceReload)
        } catch {
            LogStore.logAsync(.warn, "System widget snapshot write failed: \(error.localizedDescription)")
        }
    }

    func snapshotURL() -> URL? {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            return groupURL.appendingPathComponent(Self.snapshotFilename, isDirectory: false)
        }
        return fallbackSnapshotURL()
    }

    func write(snapshot: SystemSnapshot, to url: URL) throws {
        let data = try encode(snapshot: snapshot)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func readSnapshot(from url: URL) throws -> SystemSnapshot {
        let data = try Data(contentsOf: url)
        return try decode(data: data)
    }

    func encode(snapshot: SystemSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    func decode(data: Data) throws -> SystemSnapshot {
        try decoder.decode(SystemSnapshot.self, from: data)
    }

    func requestReload(force: Bool) {
        #if canImport(WidgetKit)
        let now = Date()
        if !force, let lastReloadAt, now.timeIntervalSince(lastReloadAt) < reloadDebounceSeconds {
            return
        }
        self.lastReloadAt = now
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
        #endif
    }

    static func fallbackSnapshotURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/DevStation", isDirectory: true)
            .appendingPathComponent(Self.snapshotFilename, isDirectory: false)
    }

    private func fallbackSnapshotURL() -> URL {
        Self.fallbackSnapshotURL()
    }
}
