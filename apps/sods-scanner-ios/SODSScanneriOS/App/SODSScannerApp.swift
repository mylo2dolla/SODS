import SwiftUI

@main
struct SODSScannerApp: App {
    @StateObject private var coordinator: IOSScanCoordinator
    @StateObject private var subscriptionManager: SubscriptionManager

    init() {
        let subscriptionManager = SubscriptionManager()
        let coordinator = IOSScanCoordinator()
        coordinator.attachSubscriptionManager(subscriptionManager)

        _subscriptionManager = StateObject(wrappedValue: subscriptionManager)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(coordinator)
                .environmentObject(subscriptionManager)
                .tint(.red)
                .task {
                    await subscriptionManager.refreshEntitlement()
                }
        }
    }
}
