import SwiftUI
import ScannerSpectrumCore

struct DeviceInfoSheet: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    let detail: SpectrumNodeDetail
    @State private var showUpgradeSheet = false

    private var hasAdvancedDetails: Bool {
        subscriptionManager.canUse(.advancedDynamicDetails)
    }

    private var blePeripheral: BLEPeripheral? {
        coordinator.bleForID(detail.id)
    }

    private var hostEntry: HostEntry? {
        coordinator.hostForID(detail.id)
    }

    private var onvifDevice: Device? {
        coordinator.deviceForID(detail.id)
    }

    private var identityType: String {
        if detail.id.hasPrefix("ble:") { return "BLE" }
        if detail.id.hasPrefix("host:") { return "LAN Host" }
        if detail.id.hasPrefix("onvif:") { return "ONVIF Device" }
        if detail.id.hasPrefix("node:") { return "Node" }
        if blePeripheral != nil { return "BLE" }
        if hostEntry != nil { return "LAN Host" }
        if onvifDevice != nil { return "ONVIF Device" }
        return "Signal Device"
    }

    private var displayName: String {
        if let blePeripheral {
            return blePeripheral.name ?? blePeripheral.fingerprint.manufacturerCompanyName ?? detail.id
        }
        if let hostEntry {
            return hostEntry.hostname ?? hostEntry.ip
        }
        if let onvifDevice {
            return onvifDevice.httpTitle ?? onvifDevice.ip
        }
        if let summary = detail.summary, !summary.isEmpty {
            return summary
        }
        return detail.id
    }

    private var eventPayloadRows: [DynamicFieldRow] {
        DynamicFieldRenderer.rows(fromJSON: detail.eventData)
    }

    private var framePayloadRows: [DynamicFieldRow] {
        DynamicFieldRenderer.rows(fromJSON: detail.frameData)
    }

    private var bleRows: [DynamicFieldRow] {
        guard let blePeripheral else { return [] }
        return DynamicFieldRenderer.rows(fromObject: blePeripheral)
    }

    private var hostRows: [DynamicFieldRow] {
        guard let hostEntry else { return [] }
        return DynamicFieldRenderer.rows(fromObject: hostEntry)
    }

    private var deviceRows: [DynamicFieldRow] {
        guard let onvifDevice else { return [] }
        return DynamicFieldRenderer.rows(fromObject: onvifDevice)
    }

    private var signalSnapshotRows: [DynamicFieldRow] {
        var rows: [DynamicFieldRow] = [
            DynamicFieldRow(key: "renderKind", value: detail.renderKind.label),
            DynamicFieldRow(key: "lastSeen", value: detail.lastSeen.formatted(date: .abbreviated, time: .standard))
        ]

        if let source = detail.source, !source.isEmpty {
            rows.append(DynamicFieldRow(key: "source", value: source))
        }
        if let channel = detail.channel, !channel.isEmpty {
            rows.append(DynamicFieldRow(key: "channel", value: channel))
        }
        if let rssi = detail.rssi {
            rows.append(DynamicFieldRow(key: "rssi", value: String(format: "%.1f dBm", rssi)))
        }
        if let confidence = detail.confidence {
            rows.append(DynamicFieldRow(key: "confidence", value: "\(Int(confidence * 100))%"))
        }
        if let avgStrength = detail.avgStrength {
            rows.append(DynamicFieldRow(key: "avgStrength", value: "\(Int(avgStrength * 100))% (\(strengthTrendLabel(avgStrength)))"))
        }
        if let avgRSSI = detail.avgRSSI {
            rows.append(DynamicFieldRow(key: "avgRSSI", value: String(format: "%.1f dBm", avgRSSI)))
        }
        if detail.inboundRatePerSec > 0.01 {
            rows.append(DynamicFieldRow(key: "inboundRate", value: String(format: "%.2f events/s", detail.inboundRatePerSec)))
        }
        if detail.outboundRatePerSec > 0.01 {
            rows.append(DynamicFieldRow(key: "outboundRate", value: String(format: "%.2f events/s", detail.outboundRatePerSec)))
        }
        if !detail.correlatedPeers.isEmpty {
            rows.append(DynamicFieldRow(key: "correlatedPeers", value: detail.correlatedPeers.prefix(6).joined(separator: ", ")))
        }
        if let summary = detail.summary, !summary.isEmpty {
            rows.append(DynamicFieldRow(key: "summary", value: summary))
        }

        return rows
    }

    private var bleEssentialsRows: [DynamicFieldRow] {
        guard let blePeripheral else { return [] }
        return [
            DynamicFieldRow(key: "name", value: blePeripheral.name ?? "Unknown"),
            DynamicFieldRow(key: "address", value: blePeripheral.id.uuidString),
            DynamicFieldRow(key: "company", value: blePeripheral.fingerprint.manufacturerCompanyName ?? "Unknown"),
            DynamicFieldRow(
                key: "confidence",
                value: "\(blePeripheral.bleConfidence.level.rawValue) (\(blePeripheral.bleConfidence.score))"
            ),
            DynamicFieldRow(key: "services", value: "\(blePeripheral.fingerprint.servicesDecoded.count)")
        ]
    }

    private var hostEssentialsRows: [DynamicFieldRow] {
        guard let hostEntry else { return [] }
        return [
            DynamicFieldRow(key: "ip", value: hostEntry.ip),
            DynamicFieldRow(key: "status", value: hostEntry.isAlive ? "Alive" : "No response"),
            DynamicFieldRow(key: "hostname", value: hostEntry.hostname ?? "Unknown"),
            DynamicFieldRow(key: "vendor", value: hostEntry.vendor ?? "Unknown"),
            DynamicFieldRow(
                key: "openPorts",
                value: hostEntry.openPorts.isEmpty ? "None" : hostEntry.openPorts.map(String.init).joined(separator: ", ")
            )
        ]
    }

    private var deviceEssentialsRows: [DynamicFieldRow] {
        guard let onvifDevice else { return [] }
        return [
            DynamicFieldRow(key: "id", value: onvifDevice.id),
            DynamicFieldRow(key: "ip", value: onvifDevice.ip),
            DynamicFieldRow(key: "vendor", value: onvifDevice.vendor ?? "Unknown"),
            DynamicFieldRow(key: "viaONVIF", value: onvifDevice.discoveredViaOnvif ? "Yes" : "No"),
            DynamicFieldRow(key: "bestRTSP", value: onvifDevice.bestRtspURI ?? "None")
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    valueRow("type", identityType)
                    valueRow("id", detail.id)
                    valueRow("name", displayName)
                }

                Section("Signal Snapshot") {
                    ForEach(signalSnapshotRows) { row in
                        valueRow(row.key, row.value)
                    }
                }

                if hasAdvancedDetails {
                    Section("Signal Event Payload") {
                        if eventPayloadRows.isEmpty {
                            Text("No event payload captured for this node yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(eventPayloadRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    Section("Signal Frame Payload") {
                        if framePayloadRows.isEmpty {
                            Text("No frame payload captured for this node yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(framePayloadRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    if !bleRows.isEmpty {
                        Section("BLE Record") {
                            ForEach(bleRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    if !hostRows.isEmpty {
                        Section("LAN Host Record") {
                            ForEach(hostRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    if !deviceRows.isEmpty {
                        Section("ONVIF / Device Record") {
                            ForEach(deviceRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }
                } else {
                    Section("Pro Features") {
                        Text("Upgrade to Pro to unlock full dynamic payloads and complete BLE/LAN/ONVIF record fields.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Upgrade to Pro") {
                            showUpgradeSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }

                    if !bleEssentialsRows.isEmpty {
                        Section("BLE Essentials") {
                            ForEach(bleEssentialsRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    if !hostEssentialsRows.isEmpty {
                        Section("LAN Essentials") {
                            ForEach(hostEssentialsRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }

                    if !deviceEssentialsRows.isEmpty {
                        Section("ONVIF Essentials") {
                            ForEach(deviceEssentialsRows) { row in
                                valueRow(row.key, row.value)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Device Info")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeView()
                .environmentObject(subscriptionManager)
        }
    }

    @ViewBuilder
    private func valueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func strengthTrendLabel(_ strength: Double) -> String {
        switch strength {
        case ..<0.4:
            return "Weak"
        case ..<0.7:
            return "Medium"
        default:
            return "Strong"
        }
    }
}
