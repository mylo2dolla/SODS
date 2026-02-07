import Foundation
import SwiftUI

@MainActor
final class ModalCoordinator: ObservableObject {
    enum Sheet: Identifiable {
        case toolRegistry
        case apiInspector(endpoint: ContentView.APIEndpoint)
        case toolRunner(tool: ToolDefinition)
        case presetRunner(preset: PresetDefinition)
        case runbookRunner(runbook: RunbookDefinition)
        case toolBuilder
        case presetBuilder
        case scratchpad
        case aliasManager
        case findDevice
        case viewer(url: URL)
        case consent
        case rtspCredentials

        var id: String {
            switch self {
            case .toolRegistry: return "toolRegistry"
            case .apiInspector(let endpoint): return "apiInspector:\(endpoint.rawValue)"
            case .toolRunner(let tool): return "toolRunner:\(tool.name)"
            case .presetRunner(let preset): return "presetRunner:\(preset.id)"
            case .runbookRunner(let runbook): return "runbookRunner:\(runbook.id)"
            case .toolBuilder: return "toolBuilder"
            case .presetBuilder: return "presetBuilder"
            case .scratchpad: return "scratchpad"
            case .aliasManager: return "aliasManager"
            case .findDevice: return "findDevice"
            case .viewer(let url): return "viewer:\(url.absoluteString)"
            case .consent: return "consent"
            case .rtspCredentials: return "rtspCredentials"
            }
        }
    }

    @Published var activeSheet: Sheet?

    func present(_ sheet: Sheet) {
        activeSheet = sheet
    }

    func dismiss() {
        activeSheet = nil
    }
}
