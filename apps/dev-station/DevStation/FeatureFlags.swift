import Foundation

final class FeatureFlags {
    static let shared = FeatureFlags()

    private init() {}

    var simulationEnabled: Bool { true }
    var showAdvancedTools: Bool { true }
    var showBuilders: Bool { true }
    var showScratchpad: Bool { true }
    var showDevActions: Bool { true }
}
