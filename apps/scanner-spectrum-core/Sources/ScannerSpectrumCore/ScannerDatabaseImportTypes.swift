import Foundation

public struct ScannerDatabaseImportResult: Hashable, Sendable {
    public let accepted: Bool
    public let message: String
    public let entryCount: Int

    public init(accepted: Bool, message: String, entryCount: Int = 0) {
        self.accepted = accepted
        self.message = message
        self.entryCount = entryCount
    }
}

public struct OUIStoreHealth: Hashable, Sendable {
    public let entryCount: Int
    public let source: String
    public let warning: String?

    public init(entryCount: Int, source: String, warning: String?) {
        self.entryCount = entryCount
        self.source = source
        self.warning = warning
    }

    public var isHealthy: Bool {
        warning == nil
    }
}
