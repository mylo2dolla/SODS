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
        let url = toolRegistryURL()
        guard let url, let data = try? Data(contentsOf: url) else {
            tools = []
            policyNote = nil
            return
        }
        do {
            let payload = try JSONDecoder().decode(ToolRegistryPayload.self, from: data)
            tools = payload.tools
            policyNote = payload.policy?.notes
        } catch {
            tools = []
            policyNote = nil
        }
    }

    private func toolRegistryURL() -> URL? {
        let root = sodsRootPath()
        return URL(fileURLWithPath: "\(root)/docs/tool-registry.json")
    }

    private func sodsRootPath() -> String {
        if let env = ProcessInfo.processInfo.environment["SODS_ROOT"], !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/sods/SODS"
    }
}
