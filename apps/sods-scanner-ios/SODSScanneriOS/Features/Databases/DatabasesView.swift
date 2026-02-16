import SwiftUI
import UniformTypeIdentifiers

struct DatabasesView: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    @State private var showOUIImporter = false
    @State private var showBLECompanyImporter = false
    @State private var showBLEAssignedImporter = false
    @State private var showUpgradeSheet = false

    private var canImport: Bool {
        subscriptionManager.canUse(.databaseImport)
    }

    private var canReset: Bool {
        subscriptionManager.canUse(.databaseReset)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    healthCard
                    importButtons
                }
                .padding(16)
            }
            .navigationTitle("Databases")
            .fileImporter(
                isPresented: $showOUIImporter,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    coordinator.importOUI(url: url)
                }
            }
            .fileImporter(
                isPresented: $showBLECompanyImporter,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    coordinator.importBLECompany(url: url)
                }
            }
            .fileImporter(
                isPresented: $showBLEAssignedImporter,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    coordinator.importBLEAssigned(url: url)
                }
            }
            .sheet(isPresented: $showUpgradeSheet) {
                UpgradeView()
                    .environmentObject(subscriptionManager)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Database Action")
                .font(.headline)
            Text(coordinator.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var healthCard: some View {
        let bleHealth = coordinator.metadataHealth
        let ouiHealth = coordinator.ouiHealth

        return VStack(alignment: .leading, spacing: 10) {
            Text("BLE Metadata Health")
                .font(.headline)
            Text("Companies: \(bleHealth.companyCount)")
            Text("Assigned UUIDs: \(bleHealth.assignedCount)")
            Text("Service UUIDs: \(bleHealth.serviceCount)")
            Text("Parse errors: \(bleHealth.parseErrors)")
            if bleHealth.warnings.isEmpty {
                Text("Status: Healthy")
                    .foregroundStyle(.green)
            } else {
                ForEach(bleHealth.warnings, id: \.self) { warning in
                    Text("• \(warning)")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Divider()

            Text("OUI Database Health")
                .font(.headline)
            Text("Entries: \(ouiHealth.entryCount)")
            Text("Source: \(ouiHealth.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = ouiHealth.warning {
                Text("• \(warning)")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Text("Status: Healthy")
                    .foregroundStyle(.green)
            }

            Button("Reload Metadata") {
                coordinator.reloadMetadata()
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var importButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Files")
                .font(.headline)

            Button {
                if canImport {
                    showOUIImporter = true
                } else {
                    showUpgradeSheet = true
                }
            } label: {
                Label("Import OUI.txt", systemImage: canImport ? "square.and.arrow.down" : "lock.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(canImport ? .red : .gray)

            Button {
                if canImport {
                    showBLECompanyImporter = true
                } else {
                    showUpgradeSheet = true
                }
            } label: {
                Label("Import BLECompanyIDs.txt", systemImage: canImport ? "square.and.arrow.down" : "lock.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(canImport ? .red : .gray)

            Button {
                if canImport {
                    showBLEAssignedImporter = true
                } else {
                    showUpgradeSheet = true
                }
            } label: {
                Label("Import BLEAssignedNumbers.txt", systemImage: canImport ? "square.and.arrow.down" : "lock.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(canImport ? .red : .gray)

            Button {
                if canReset {
                    coordinator.resetImportedOverrides()
                } else {
                    showUpgradeSheet = true
                }
            } label: {
                Label("Reset Imported Overrides", systemImage: canReset ? "arrow.counterclockwise" : "lock.fill")
            }
            .buttonStyle(.bordered)

            if !canImport || !canReset {
                Text("Pro unlocks database import and override reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
