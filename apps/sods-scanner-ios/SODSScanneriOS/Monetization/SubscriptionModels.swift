import Foundation

public enum ProFeature: CaseIterable, Sendable {
    case spectrum
    case databaseImport
    case databaseReset
    case advancedDynamicDetails

    var title: String {
        switch self {
        case .spectrum:
            return "Spectrum"
        case .databaseImport:
            return "Database Import"
        case .databaseReset:
            return "Database Reset"
        case .advancedDynamicDetails:
            return "Advanced Device Details"
        }
    }
}

public enum EntitlementSource: String, Codable, Sendable {
    case none
    case verifiedTransaction
    case cachedGrace
    case debugOverride
    case debugAdminAllowlist
}

public struct SubscriptionEntitlement: Codable, Hashable, Sendable {
    public var isPro: Bool
    public var source: EntitlementSource
    public var verifiedAt: Date?
    public var expiresAt: Date?
    public var graceUntil: Date?

    public init(
        isPro: Bool,
        source: EntitlementSource,
        verifiedAt: Date?,
        expiresAt: Date?,
        graceUntil: Date?
    ) {
        self.isPro = isPro
        self.source = source
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
        self.graceUntil = graceUntil
    }

    public static let free = SubscriptionEntitlement(
        isPro: false,
        source: .none,
        verifiedAt: nil,
        expiresAt: nil,
        graceUntil: nil
    )
}

public struct SubscriptionOffering: Identifiable, Hashable, Sendable {
    public var productID: String
    public var displayName: String
    public var priceText: String
    public var period: String
    public var hasIntroTrial: Bool

    public init(
        productID: String,
        displayName: String,
        priceText: String,
        period: String,
        hasIntroTrial: Bool
    ) {
        self.productID = productID
        self.displayName = displayName
        self.priceText = priceText
        self.period = period
        self.hasIntroTrial = hasIntroTrial
    }

    public var id: String { productID }
}

public enum PurchaseResult: Sendable {
    case success(productID: String)
    case pending
    case cancelled
    case failed(message: String)
}

public enum RestoreResult: Sendable {
    case restored
    case nothingToRestore
    case failed(message: String)
}
