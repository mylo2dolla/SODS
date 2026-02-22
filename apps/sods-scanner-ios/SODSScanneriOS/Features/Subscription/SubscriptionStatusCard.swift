import SwiftUI

struct SubscriptionStatusCard: View {
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Plan")
                .font(.headline)

            HStack {
                Label(subscriptionManager.entitlement.isPro ? "Pro" : "Free", systemImage: subscriptionManager.entitlement.isPro ? "star.fill" : "person")
                    .foregroundStyle(subscriptionManager.entitlement.isPro ? .yellow : .secondary)
                Spacer()
                Text(subscriptionManager.entitlement.source.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let expiresAt = subscriptionManager.entitlement.expiresAt {
                Text("Renews/Expires: \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let graceUntil = subscriptionManager.entitlement.graceUntil,
               subscriptionManager.entitlement.source == .cachedGrace {
                Text("Offline grace until \(graceUntil.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(subscriptionManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
