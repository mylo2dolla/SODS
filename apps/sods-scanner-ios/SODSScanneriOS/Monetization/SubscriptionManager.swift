import Foundation
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var entitlement: SubscriptionEntitlement = .free
    @Published private(set) var offerings: [SubscriptionOffering] = []
    @Published private(set) var statusMessage: String = "Free tier active."
    #if DEBUG
    @Published private(set) var debugProOverrideEnabled: Bool
    #endif

    private static let monthlyProductID = "com.strangelab.sods.scanner.pro.monthly"
    private static let yearlyProductID = "com.strangelab.sods.scanner.pro.yearly"
    #if DEBUG
    private static let debugOverrideKey = "SODSScanneriOS.debug.pro_override"
    #endif

    private let productIDs = [
        monthlyProductID,
        yearlyProductID
    ]

    private let graceWindow: TimeInterval = 7 * 24 * 60 * 60
    private let cache: SubscriptionCache
    private let defaults: UserDefaults

    private var productsByID: [String: Product] = [:]
    private var updatesTask: Task<Void, Never>?

    init(
        cache: SubscriptionCache = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.cache = cache
        self.defaults = defaults
        #if DEBUG
        self.debugProOverrideEnabled = defaults.bool(forKey: Self.debugOverrideKey)
        #endif
        self.updatesTask = listenForTransactionUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    func refreshEntitlement() async {
        #if DEBUG
        if debugProOverrideEnabled {
            entitlement = SubscriptionEntitlement(
                isPro: true,
                source: .debugOverride,
                verifiedAt: Date(),
                expiresAt: nil,
                graceUntil: nil
            )
            statusMessage = "Debug Pro override active."
            return
        }
        #endif

        var shouldAllowGrace = false

        do {
            try await refreshOfferings()
        } catch {
            shouldAllowGrace = true
            statusMessage = "Store unavailable. Using cached entitlement when possible."
        }

        if let transaction = await activeVerifiedTransaction() {
            applyVerifiedEntitlement(transaction)
            return
        }

        if shouldAllowGrace, let cached = applyCachedGraceIfAvailable() {
            entitlement = cached
            statusMessage = "Using offline grace access for Pro."
            return
        }

        entitlement = .free
        cache.clear()
        statusMessage = "Free tier active."
    }

    #if DEBUG
    func setDebugProOverride(_ enabled: Bool) {
        debugProOverrideEnabled = enabled
        defaults.set(enabled, forKey: Self.debugOverrideKey)
        Task { @MainActor in
            await refreshEntitlement()
        }
    }
    #endif

    func purchase(_ productID: String) async -> PurchaseResult {
        let product: Product
        if let existing = productsByID[productID] {
            product = existing
        } else {
            do {
                try await refreshOfferings()
            } catch {
                return .failed(message: "Unable to load subscriptions. Try again when online.")
            }

            guard let refreshed = productsByID[productID] else {
                return .failed(message: "Subscription product is not available.")
            }
            product = refreshed
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlement()
                    return .success(productID: transaction.productID)
                case .unverified:
                    return .failed(message: "Purchase could not be verified.")
                }
            case .pending:
                statusMessage = "Purchase pending approval."
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed(message: "Unknown purchase status.")
            }
        } catch {
            return .failed(message: "Purchase failed: \(error.localizedDescription)")
        }
    }

    func restorePurchases() async -> RestoreResult {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if entitlement.isPro {
                statusMessage = "Purchases restored."
                return .restored
            }
            statusMessage = "No active Pro subscription found."
            return .nothingToRestore
        } catch {
            let message = "Restore failed: \(error.localizedDescription)"
            statusMessage = message
            return .failed(message: message)
        }
    }

    func canUse(_ feature: ProFeature) -> Bool {
        if entitlement.isPro {
            return true
        }

        switch feature {
        case .spectrum, .databaseImport, .databaseReset, .advancedDynamicDetails:
            return false
        }
    }

    var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private func refreshOfferings() async throws {
        let products = try await Product.products(for: productIDs)
        var byID: [String: Product] = [:]
        var mapped: [SubscriptionOffering] = []

        for product in products {
            byID[product.id] = product
            mapped.append(
                SubscriptionOffering(
                    productID: product.id,
                    displayName: product.displayName,
                    priceText: product.displayPrice,
                    period: periodLabel(for: product.subscription),
                    hasIntroTrial: hasIntroTrial(product.subscription)
                )
            )
        }

        productsByID = byID
        offerings = mapped.sorted { lhs, rhs in
            sortOrder(for: lhs.productID) < sortOrder(for: rhs.productID)
        }
    }

    private func activeVerifiedTransaction() async -> Transaction? {
        var winning: Transaction?
        let now = Date()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            guard productIDs.contains(transaction.productID) else {
                continue
            }

            if transaction.revocationDate != nil {
                continue
            }

            if let expirationDate = transaction.expirationDate, expirationDate <= now {
                continue
            }

            if let existing = winning {
                let existingDate = existing.expirationDate ?? existing.purchaseDate
                let newDate = transaction.expirationDate ?? transaction.purchaseDate
                if newDate > existingDate {
                    winning = transaction
                }
            } else {
                winning = transaction
            }
        }

        return winning
    }

    private func applyVerifiedEntitlement(_ transaction: Transaction) {
        let now = Date()
        let graceUntil = now.addingTimeInterval(graceWindow)

        entitlement = SubscriptionEntitlement(
            isPro: true,
            source: .verifiedTransaction,
            verifiedAt: now,
            expiresAt: transaction.expirationDate,
            graceUntil: graceUntil
        )

        cache.save(
            SubscriptionCachePayload(
                lastVerifiedAt: now,
                expiresAt: transaction.expirationDate
            )
        )

        statusMessage = "Pro active."
    }

    private func applyCachedGraceIfAvailable() -> SubscriptionEntitlement? {
        guard let payload = cache.load() else {
            return nil
        }

        let now = Date()
        let graceUntil = payload.lastVerifiedAt.addingTimeInterval(graceWindow)
        guard now <= graceUntil else {
            cache.clear()
            return nil
        }

        return SubscriptionEntitlement(
            isPro: true,
            source: .cachedGrace,
            verifiedAt: payload.lastVerifiedAt,
            expiresAt: payload.expiresAt,
            graceUntil: graceUntil
        )
    }

    private func periodLabel(for subscription: Product.SubscriptionInfo?) -> String {
        guard let subscription else {
            return ""
        }

        let period = subscription.subscriptionPeriod
        switch period.unit {
        case .day:
            return period.value == 1 ? "per day" : "every \(period.value) days"
        case .week:
            return period.value == 1 ? "per week" : "every \(period.value) weeks"
        case .month:
            return period.value == 1 ? "per month" : "every \(period.value) months"
        case .year:
            return period.value == 1 ? "per year" : "every \(period.value) years"
        @unknown default:
            return "subscription"
        }
    }

    private func hasIntroTrial(_ subscription: Product.SubscriptionInfo?) -> Bool {
        subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    private func sortOrder(for productID: String) -> Int {
        if productID == Self.yearlyProductID {
            return 0
        }
        if productID == Self.monthlyProductID {
            return 1
        }
        return 2
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
    }
}
