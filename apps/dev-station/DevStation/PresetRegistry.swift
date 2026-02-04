import Foundation

struct PresetDefinition: Decodable, Identifiable {
    let id: String
    let title: String?
    let description: String?
    let kind: String
    let tool: String?
    let input: [String: AnyCodable]?
    let vars: [String: AnyCodable]?
    let steps: [AnyCodable]?
    let tags: [String]?
    let ui: PresetUI?

    var name: String { title ?? id }
}

struct PresetUI: Decodable {
    let icon: String?
    let color: String?
    let capsule: Bool?
}

struct PresetRegistryPayload: Decodable {
    let version: String?
    let presets: [PresetDefinition]
}

@MainActor
final class PresetRegistry: ObservableObject {
    static let shared = PresetRegistry()

    @Published private(set) var presets: [PresetDefinition] = []

    private init() {
        reload()
    }

    func reload() {
        Task {
            if let payload = await fetchRemote() {
                presets = payload.presets
            } else {
                presets = []
            }
        }
    }

    private func fetchRemote() async -> PresetRegistryPayload? {
        let baseURL = stationBaseURL()
        guard let url = URL(string: "\(baseURL)/api/presets") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return try JSONDecoder().decode(PresetRegistryPayload.self, from: data)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func stationBaseURL() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "SODSBaseURL"), !saved.isEmpty {
            return saved
        }
        return "http://localhost:9123"
    }
}
