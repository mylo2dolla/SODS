import Combine
import SODSAppCore

enum SODSScannerBootstrap {
    @MainActor
    static func makeDependencies() -> (ScanCoordinator, SubscriptionManager) {
        let subscriptionManager = SubscriptionManager()
        let coordinator = ScanCoordinator()
        coordinator.bindProEntitlement(
            initialIsPro: subscriptionManager.entitlement.isPro,
            updates: subscriptionManager.$entitlement.map(\.isPro).eraseToAnyPublisher()
        )
        return (coordinator, subscriptionManager)
    }
}
