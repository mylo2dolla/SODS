import SwiftUI

struct UpgradeView: View {
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var bannerMessage: String?

    private var sortedOfferings: [SubscriptionOffering] {
        subscriptionManager.offerings.sorted { lhs, rhs in
            if lhs.productID.contains("yearly") && !rhs.productID.contains("yearly") {
                return true
            }
            if lhs.productID.contains("monthly") && !rhs.productID.contains("monthly") {
                return false
            }
            return lhs.productID < rhs.productID
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pro unlocks")
                            .font(.headline)
                        featureRow("Spectrum tab with directional aggregated pulses")
                        featureRow("Database import + reset actions")
                        featureRow("Full dynamic BLE/LAN/ONVIF payload detail sections")
                        featureRow("Extended signal history retention")
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 10) {
                        if sortedOfferings.isEmpty {
                            Text("Loading subscription options...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(sortedOfferings) { offering in
                                offeringCard(offering)
                            }
                        }
                    }

                    if let bannerMessage {
                        Text(bannerMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button("Restore Purchases") {
                            Task { await restorePurchases() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)

                        if let url = subscriptionManager.manageSubscriptionsURL {
                            Link("Manage", destination: url)
                                .buttonStyle(.bordered)
                        }
                    }

                    Text("Billing is handled by Apple. Cancel anytime in Settings > Apple ID > Subscriptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await subscriptionManager.refreshEntitlement()
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free tier stays useful")
                .font(.headline)
            Text("BLE + LAN scanning and basic details remain free. Pro unlocks advanced analysis and release-grade tools.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func featureRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(text)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func offeringCard(_ offering: SubscriptionOffering) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(offering.displayName)
                        .font(.headline)
                    Text("\(offering.priceText) \(offering.period)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if offering.productID.contains("yearly") {
                    Text("Best Value")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            if offering.hasIntroTrial || offering.productID.contains("yearly") {
                Text("Includes 7-day free trial")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                Task {
                    await purchase(offering)
                }
            } label: {
                Text("Start \(offering.displayName)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isWorking)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func purchase(_ offering: SubscriptionOffering) async {
        isWorking = true
        defer { isWorking = false }

        let result = await subscriptionManager.purchase(offering.productID)
        switch result {
        case .success:
            bannerMessage = "Pro unlocked."
            dismiss()
        case .pending:
            bannerMessage = "Purchase pending approval."
        case .cancelled:
            bannerMessage = "Purchase cancelled."
        case .failed(let message):
            bannerMessage = message
        }
    }

    private func restorePurchases() async {
        isWorking = true
        defer { isWorking = false }

        let result = await subscriptionManager.restorePurchases()
        switch result {
        case .restored:
            bannerMessage = "Restore complete. Pro is active."
        case .nothingToRestore:
            bannerMessage = "No active subscription found to restore."
        case .failed(let message):
            bannerMessage = message
        }
    }
}
