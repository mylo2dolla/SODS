import Foundation

struct RunbookStep: Decodable, Identifiable {
    let id: String
    let tool: String
    let input: [String: AnyCodable]?

    var display: String { "\(id) • \(tool)" }
}

struct RunbookParallel: Decodable, Identifiable {
    let parallel: [RunbookStep]
    let id: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parallel = try container.decode([RunbookStep].self, forKey: .parallel)
        id = "parallel-" + UUID().uuidString
    }

    enum CodingKeys: String, CodingKey {
        case parallel
    }
}

enum RunbookStepEntry: Decodable, Identifiable {
    case single(RunbookStep)
    case parallel(RunbookParallel)

    var id: String {
        switch self {
        case .single(let step): return step.id
        case .parallel(let group): return group.id
        }
    }

    var label: String {
        switch self {
        case .single(let step): return step.display
        case .parallel: return "parallel group"
        }
    }

    var steps: [RunbookStep] {
        switch self {
        case .single(let step): return [step]
        case .parallel(let group): return group.parallel
        }
    }

    init(from decoder: Decoder) throws {
        if let group = try? RunbookParallel(from: decoder) {
            self = .parallel(group)
            return
        }
        let step = try RunbookStep(from: decoder)
        self = .single(step)
    }
}

struct RunbookDefinition: Decodable, Identifiable {
    let id: String
    let title: String?
    let description: String?
    let kind: String?
    let vars: [String: AnyCodable]?
    let steps: [RunbookStepEntry]?
    let tags: [String]?
    let ui: PresetUI?
    let inputSchema: [String: AnyCodable]?

    var name: String { title ?? id }

    enum CodingKeys: String, CodingKey {
        case id, title, description, kind, vars, steps, tags, ui
        case inputSchema = "input_schema"
    }
}

struct RunbookRegistryPayload: Decodable {
    let version: String?
    let runbooks: [RunbookDefinition]
}

@MainActor
final class RunbookRegistry: ObservableObject {
    static let shared = RunbookRegistry()

    @Published private(set) var runbooks: [RunbookDefinition] = []

    private init() {
        reload()
    }

    func reload() {
        Task {
            if let payload = await fetchRemote() {
                runbooks = payload.runbooks
            } else {
                runbooks = []
            }
        }
    }

    private func fetchRemote() async -> RunbookRegistryPayload? {
        let baseURL = stationBaseURL()
        guard let url = URL(string: "\(baseURL)/api/runbooks") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return try JSONDecoder().decode(RunbookRegistryPayload.self, from: data)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func stationBaseURL() -> String {
        StationEndpointResolver.stationBaseURL()
    }
}
