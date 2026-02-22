import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @State private var showUpgradeSheet = false
    #if DEBUG
    @State private var debugAdminEmailInput: String = ""
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription") {
                    SubscriptionStatusCard()

                    if !subscriptionManager.entitlement.isPro {
                        Button("Upgrade to Pro") {
                            showUpgradeSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }

                    Button("Restore Purchases") {
                        Task {
                            _ = await subscriptionManager.restorePurchases()
                        }
                    }
                    .buttonStyle(.bordered)

                    if let url = subscriptionManager.manageSubscriptionsURL {
                        Link("Manage Subscription", destination: url)
                    }
                }

                #if DEBUG
                Section("Admin (Debug)") {
                    TextField("Admin email", text: $debugAdminEmailInput)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
#endif
                        .autocorrectionDisabled()

                    Button("Apply Admin Email") {
                        subscriptionManager.setDebugAdminEmail(debugAdminEmailInput)
                    }
                    .buttonStyle(.bordered)

                    if subscriptionManager.debugAdminEmailMatched {
                        Text("Allowlisted Pro email matched.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("Enter letsdev23@icloud.com to unlock Pro in Debug.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Unlock Pro Features (Debug)",
                        isOn: Binding(
                            get: { subscriptionManager.debugProOverrideEnabled },
                            set: { subscriptionManager.setDebugProOverride($0) }
                        )
                    )

                    Button("Refresh Entitlement") {
                        Task {
                            await subscriptionManager.refreshEntitlement()
                        }
                    }
                    .buttonStyle(.bordered)

                    Text("Debug-only local override for testing. This is not a real purchase.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif

                Section("Discovery") {
                    Toggle("Enable SSDP + Bonjour", isOn: $coordinator.lanServiceDiscoveryEnabled)
                    Toggle("Enable ONVIF", isOn: $coordinator.lanOnvifEnabled)
                    Toggle("Enable ARP Warmup", isOn: $coordinator.lanArpWarmupEnabled)
                }

                Section("Capabilities") {
                    capabilityRow("Bonjour", enabled: coordinator.lanCapabilities.supportsBonjour)
                    capabilityRow("SSDP", enabled: coordinator.lanCapabilities.supportsSSDP)
                    capabilityRow("ONVIF", enabled: coordinator.lanCapabilities.supportsONVIF)
                    capabilityRow("Multicast", enabled: coordinator.lanCapabilities.multicastAvailable)
                    if !coordinator.lanCapabilities.notes.isEmpty {
                        ForEach(coordinator.lanCapabilities.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Legal") {
                    NavigationLink("Privacy Policy") {
                        LegalView(document: .privacyPolicy)
                    }
                    NavigationLink("Terms of Use") {
                        LegalView(document: .termsOfUse)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showUpgradeSheet) {
                UpgradeView()
                    .environmentObject(subscriptionManager)
            }
            .task {
                await subscriptionManager.refreshEntitlement()
                #if DEBUG
                debugAdminEmailInput = subscriptionManager.debugAdminEmail
                #endif
            }
        }
    }

    private func capabilityRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(enabled ? "Available" : "Unavailable")
                .foregroundStyle(enabled ? .green : .orange)
        }
    }
}
