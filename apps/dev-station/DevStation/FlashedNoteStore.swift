import Foundation

struct FlashedNoteRecord: Codable, Hashable, Identifiable {
    let id: String
    var note: String
    var updatedAt: Date
}

@MainActor
final class FlashedNoteStore: ObservableObject {
    static let shared = FlashedNoteStore()

    @Published private(set) var records: [String: FlashedNoteRecord] = [:]

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        fileURL = StoragePaths.workspaceSubdir("notes").appendingPathComponent("flashed-notes.json")
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func note(for key: String) -> String {
        records[normalize(key)]?.note ?? ""
    }

    func setNote(_ note: String, for key: String) {
        let normalizedKey = normalize(key)
        guard !normalizedKey.isEmpty else { return }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            records.removeValue(forKey: normalizedKey)
        } else {
            records[normalizedKey] = FlashedNoteRecord(
                id: normalizedKey,
                note: trimmed,
                updatedAt: Date()
            )
        }
        save()
    }

    func resolveKey(preferred: String?, fallbacks: [String]) -> String {
        let candidates = ([preferred] + fallbacks).compactMap { $0 }
        for raw in candidates {
            let normalized = normalize(raw)
            if normalized.isEmpty { continue }
            if records[normalized] != nil { return normalized }
        }
        for raw in candidates {
            let normalized = normalize(raw)
            if !normalized.isEmpty { return normalized }
        }
        return ""
    }

    private func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? decoder.decode([FlashedNoteRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func save() {
        let list = records.values.sorted { $0.id < $1.id }
        guard let data = try? encoder.encode(list) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogStore.logAsync(.error, "Failed to save flashed notes: \(error.localizedDescription)")
        }
    }
}

