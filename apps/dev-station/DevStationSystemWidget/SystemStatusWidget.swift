import WidgetKit
import SwiftUI
import Foundation

private struct SystemWidgetSnapshot: Codable {
    let timestamp: Date
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let cpuIdlePercent: Double
    let memTotalBytes: Int64
    let memUsedBytes: Int64
    let memFreeBytes: Int64
    let memCompressedBytes: Int64
    let swapUsedBytes: Int64
    let swapTotalBytes: Int64
    let processCount: Int
}

private struct SystemStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemWidgetSnapshot?
}

private struct SystemStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemStatusEntry {
        SystemStatusEntry(
            date: Date(),
            snapshot: SystemWidgetSnapshot(
                timestamp: Date(),
                cpuUserPercent: 0,
                cpuSystemPercent: 0,
                cpuIdlePercent: 0,
                memTotalBytes: 0,
                memUsedBytes: 0,
                memFreeBytes: 0,
                memCompressedBytes: 0,
                swapUsedBytes: 0,
                swapTotalBytes: 0,
                processCount: 0
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemStatusEntry) -> Void) {
        completion(SystemStatusEntry(date: Date(), snapshot: readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemStatusEntry>) -> Void) {
        let now = Date()
        let entry = SystemStatusEntry(date: now, snapshot: readSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .second, value: 45, to: now) ?? now.addingTimeInterval(45)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func readSnapshot() -> SystemWidgetSnapshot? {
        guard let url = snapshotURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SystemWidgetSnapshot.self, from: data)
    }

    private func snapshotURL() -> URL? {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.strangelab.sods.devstation") {
            return groupURL.appendingPathComponent("system-status-snapshot.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/DevStation", isDirectory: true)
            .appendingPathComponent("system-status-snapshot.json", isDirectory: false)
    }
}

struct SystemStatusWidget: Widget {
    private let kind = "DevStationSystemStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemStatusProvider()) { entry in
            SystemStatusWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "devstation://system-manager"))
        }
        .configurationDisplayName("Dev Station Status")
        .description("Live CPU, RAM, swap, and process count from Dev Station.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SystemStatusWidgetEntryView: View {
    let entry: SystemStatusProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dev Station")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Status")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let snapshot = entry.snapshot {
                statusRow("CPU", String(format: "U %.0f%% S %.0f%%", snapshot.cpuUserPercent, snapshot.cpuSystemPercent))
                statusRow("RAM", "\(memory(snapshot.memUsedBytes)) / \(memory(snapshot.memTotalBytes))")
                statusRow("Swap", "\(memory(snapshot.swapUsedBytes)) / \(memory(snapshot.swapTotalBytes))")
                statusRow("Proc", "\(snapshot.processCount)")
                Text(snapshot.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("No snapshot")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Open Dev Station")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
