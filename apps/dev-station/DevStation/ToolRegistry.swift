import Foundation

struct ToolRegistryPolicy: Decodable {
    let passiveOnly: Bool?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case passiveOnly = "passive_only"
        case notes
    }
}

struct ToolDefinition: Decodable, Identifiable {
    let name: String
    let scope: String
    let kind: String
    let description: String
    let input: String
    let output: String
    let outputSchema: [String: String]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case scope
        case kind
        case description
        case input
        case output
        case outputSchema = "output_schema"
    }
}

struct ToolRegistryPayload: Decodable {
    let version: String?
    let policy: ToolRegistryPolicy?
    let tools: [ToolDefinition]
}

@MainActor
final class ToolRegistry: ObservableObject {
    static let shared = ToolRegistry()

    @Published private(set) var tools: [ToolDefinition] = []
    @Published private(set) var policyNote: String?

    private init() {
        reload()
    }

    func reload() {
        Task {
            if let payload = await fetchRegistry() {
                tools = payload.tools
                policyNote = payload.policy?.notes
            } else {
                tools = []
                policyNote = nil
            }
        }
    }

    private func fetchRegistry() async -> ToolRegistryPayload? {
        if let remote = await fetchRemoteRegistry() {
            return remote
        }
        let root = sodsRootPath()
        let url = URL(fileURLWithPath: "\(root)/docs/tool-registry.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ToolRegistryPayload.self, from: data)
    }

    private func fetchRemoteRegistry() async -> ToolRegistryPayload? {
        let baseURL = stationBaseURL()
        guard let url = URL(string: "\(baseURL)/api/tools") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return try JSONDecoder().decode(ToolRegistryPayload.self, from: data)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func sodsRootPath() -> String {
        if let env = ProcessInfo.processInfo.environment["SODS_ROOT"], !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/sods/SODS"
    }

    private func stationBaseURL() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "SODSBaseURL"), !saved.isEmpty {
            return saved
        }
        return "http://localhost:9123"
    }
}
