import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @AppStorage("SODSScanneriOS.onboarding.completed")
    private var onboardingCompleted = false

    @State private var showOnboarding = false

    var body: some View {
        TabView {
            ScannerView()
                .tabItem {
                    Label("Scanner", systemImage: "dot.radiowaves.left.and.right")
                }

            DatabasesView()
                .tabItem {
                    Label("Databases", systemImage: "externaldrive.fill.badge.person.crop")
                }

            SpectrumView()
                .tabItem {
                    Label("Spectrum", systemImage: "waveform.path.ecg")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(subscriptionManager)
        }
        .onAppear {
            showOnboarding = !onboardingCompleted
        }
    }
}
