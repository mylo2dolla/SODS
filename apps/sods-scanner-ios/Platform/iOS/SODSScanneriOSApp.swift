import SwiftUI

@main
struct SODSScanneriOSApp: App {
    @StateObject private var coordinator: IOSScanCoordinator
    @StateObject private var subscriptionManager: SubscriptionManager

    init() {
        let dependencies = SODSScannerBootstrap.makeDependencies()
        _coordinator = StateObject(wrappedValue: dependencies.0)
        _subscriptionManager = StateObject(wrappedValue: dependencies.1)
    }

    var body: some Scene {
        WindowGroup {
            SODSScannerRootView()
                .environmentObject(coordinator)
                .environmentObject(subscriptionManager)
                .tint(.red)
                .task {
                    await subscriptionManager.refreshEntitlement()
                }
        }
    }
}
