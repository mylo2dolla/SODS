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
    let title: String?
    let description: String?
    let runner: String?
    let entry: String?
    let cwd: String?
    let timeoutMs: Int?
    let kind: String?
    let tags: [String]?
    let inputSchema: [String: AnyCodable]?
    let output: ToolOutputFormat?
    let scope: String?
    let input: String?
    let outputSchema: [String: String]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case runner
        case entry
        case cwd
        case timeoutMs = "timeout_ms"
        case kind
        case tags
        case inputSchema = "input_schema"
        case output
        case scope
        case input
        case outputSchema = "output_schema"
    }
}

struct ToolOutputFormat: Decodable {
    let format: String?
}

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else {
            value = ""
        }
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
