import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    @AppStorage("SODSScanneriOS.onboarding.completed")
    private var onboardingCompleted = false

    @State private var showUpgradeSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Welcome to SODS Scanner")
                        .font(.largeTitle.bold())

                    Text("Standalone BLE + LAN discovery with dynamic metadata and live spectrum visuals.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    card(
                        title: "Permissions",
                        body: "When you start BLE scanning, iOS asks for Bluetooth permission. When you start LAN scanning, iOS asks for Local Network permission. These are required for discovery features."
                    )

                    card(
                        title: "Free Tier",
                        body: "Free includes BLE and LAN scanning, alive filtering, and basic device details with core metadata health."
                    )

                    card(
                        title: "Pro Tier",
                        body: "Pro unlocks Spectrum, database import/reset, full dynamic payload sections, and extended history retention."
                    )

                    Button("View Pro Plans") {
                        showUpgradeSheet = true
                    }
                    .buttonStyle(.bordered)

                    Button("Continue") {
                        onboardingCompleted = true
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }
            .navigationTitle("Getting Started")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showUpgradeSheet) {
                UpgradeView()
                    .environmentObject(subscriptionManager)
            }
        }
    }

    private func card(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
