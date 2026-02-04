import Foundation

struct DailyLogReadable: Codable {
    struct Summary: Codable {
        let date: String
        let totalLines: Int
        let info: Int
        let warn: Int
        let error: Int
        let rawRef: String
    }

    let summary: Summary
    let notes: String
}

actor DailyLogManager {
    static let shared = DailyLogManager()

    private var currentDay: String
    private var rawURL: URL
    private var counts: [LogLevel: Int] = [.info: 0, .warn: 0, .error: 0]
    private var totalLines: Int = 0

    private init() {
        let today = Self.dayString(for: Date())
        currentDay = today
        rawURL = Self.rawURL(for: today)
        Self.ensureRawFileExists(rawURL)
    }

    func append(_ line: LogLine) async {
        let day = Self.dayString(for: Date())
        if day != currentDay {
            await finalizeDay()
            currentDay = day
            rawURL = Self.rawURL(for: day)
            counts = [.info: 0, .warn: 0, .error: 0]
            totalLines = 0
            Self.ensureRawFileExists(rawURL)
        }
        appendLine(line.formatted)
        counts[line.level, default: 0] += 1
        totalLines += 1
    }

    func finalizeDay() async {
        guard totalLines > 0 else { return }
        let readable = DailyLogReadable(
            summary: .init(
                date: currentDay,
                totalLines: totalLines,
                info: counts[.info, default: 0],
                warn: counts[.warn, default: 0],
                error: counts[.error, default: 0],
                rawRef: rawURL.lastPathComponent
            ),
            notes: "Daily log summary. Raw lines are preserved in the raw log file."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(readable) {
            let readableURL = Self.readableURL(for: currentDay)
            await MainActor.run {
                _ = LogStore.writeDataReturning(data, to: readableURL, log: LogStore.shared)
            }
        }
        Task.detached {
            _ = await ArtifactStore.shared.enqueueArtifact(self.rawURL, log: LogStore.shared)
        }
    }

    private static func ensureRawFileExists(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func appendLine(_ text: String) {
        if let handle = try? FileHandle(forWritingTo: rawURL) {
            handle.seekToEndOfFile()
            if let data = (text + "\n").data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func rawURL(for day: String) -> URL {
        let filename = "SODS-DailyRaw-\(day).txt"
        return StoragePaths.reportsSubdir("daily-raw").appendingPathComponent(filename)
    }

    private static func readableURL(for day: String) -> URL {
        let filename = "SODS-DailyReadable-\(day).json"
        return StoragePaths.reportsSubdir("daily-readable").appendingPathComponent(filename)
    }
}
