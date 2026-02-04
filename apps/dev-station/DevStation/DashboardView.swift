import SwiftUI

struct DashboardView: View {
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var bleScanner: BLEScanner
    @ObservedObject var piAuxStore: PiAuxStore
    @ObservedObject var vaultTransport: VaultTransport
    let inboxStatus: InboxStatus
    let retentionDays: Int
    let retentionMaxGB: Int
    let onvifDiscoveryEnabled: Bool
    let serviceDiscoveryEnabled: Bool
    let arpWarmupEnabled: Bool
    let bleDiscoveryEnabled: Bool
    let safeModeEnabled: Bool
    let onlyLocalSubnet: Bool
    let onOpenNodes: () -> Void

    @State private var showNet = true
    @State private var showBLE = true
    @State private var showRF = true
    @State private var showGPS = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dashboard")
                .font(.system(size: 18, weight: .semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statusCard(title: "Scan Systems") {
                    statusLine("ONVIF Discovery", onvifDiscoveryEnabled)
                    statusLine("ARP Warmup", arpWarmupEnabled)
                    statusLine("Service Discovery", serviceDiscoveryEnabled)
                    statusLine("BLE Discovery", bleDiscoveryEnabled)
                    statusLine("Safe Mode", safeModeEnabled)
                    statusLine("Only Local Subnet", onlyLocalSubnet)
                }

                statusCard(title: "Scan Summary") {
                    let summary = scanner.scanSummary()
                    Text("Last scan: \(summary.end?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Scanning: \(scanner.isScanning ? "Yes" : "No")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Hosts found: \(scanner.allHosts.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("BLE devices: \(bleScanner.peripherals.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }

                statusCard(title: "Pi-Aux Node") {
                    statusLine("Connected", piAuxStore.isRunning)
                    Text("Last event: \(piAuxStore.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Recent events (10m): \(piAuxStore.recentEventCount(window: 600))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Active nodes: \(piAuxStore.activeNodes.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    if let lastError = piAuxStore.lastError, !lastError.isEmpty {
                        Text("Last error: \(lastError)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                statusCard(title: "Vault Shipping") {
                    statusLine("Auto-ship", vaultTransport.autoShipAfterExport)
                    Text("Queue: \(vaultTransport.queuedCount)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Last ship: \(vaultTransport.lastShipTime.isEmpty ? "None" : vaultTransport.lastShipTime)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Last result: \(vaultTransport.lastShipResult.isEmpty ? "N/A" : vaultTransport.lastShipResult)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }

                statusCard(title: "Inbox Retention") {
                    Text("Files: \(inboxStatus.fileCount)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Size: \(ByteCountFormatter.string(fromByteCount: inboxStatus.totalBytes, countStyle: .file))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Limits: \(retentionDays)d / \(retentionMaxGB) GB")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Oldest: \(inboxStatus.oldest?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Newest: \(inboxStatus.newest?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            statusCard(title: "Recent Events") {
                HStack(spacing: 10) {
                    Toggle("Net", isOn: $showNet)
                    Toggle("BLE", isOn: $showBLE)
                    Toggle("RF", isOn: $showRF)
                    Toggle("GPS", isOn: $showGPS)
                    Spacer()
                    Button("Open Nodes") { onOpenNodes() }
                        .buttonStyle(SecondaryActionButtonStyle())
                }
                .font(.system(size: 11))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

                let recent = filteredEvents(limit: 18)
                if recent.isEmpty {
                    Text("No recent events")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recent) { event in
                            HStack(spacing: 8) {
                                Text(event.timestamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textSecondary)
                                Text(event.kind.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(event.deviceID)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textSecondary)
                                Spacer()
                                Button("Go to Nodes") { onOpenNodes() }
                                    .buttonStyle(SecondaryActionButtonStyle())
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .modifier(Theme.cardStyle())
    }

    private func statusLine(_ label: String, _ enabled: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Circle()
                .fill(enabled ? Theme.accent : Theme.muted)
                .frame(width: 8, height: 8)
            Text(enabled ? "On" : "Off")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private func filteredEvents(limit: Int) -> [PiAuxEvent] {
        let events = piAuxStore.events.reversed()
        var results: [PiAuxEvent] = []
        results.reserveCapacity(limit)
        for event in events {
            if results.count >= limit { break }
            let category = eventCategory(event)
            let allowed = (category == .net && showNet) ||
                (category == .ble && showBLE) ||
                (category == .rf && showRF) ||
                (category == .gps && showGPS)
            if allowed {
                results.append(event)
            }
        }
        return results
    }

    private func eventCategory(_ event: PiAuxEvent) -> EventCategory {
        if event.tags.contains(where: { $0.lowercased().contains("gps") }) {
            return .gps
        }
        if event.tags.contains(where: { $0.lowercased().contains("rf") || $0.lowercased().contains("sdr") }) {
            return .rf
        }
        switch event.kind {
        case .ble_rssi:
            return .ble
        case .wifi_rssi:
            return .net
        case .motion, .audio_level, .temperature, .custom:
            return .net
        }
    }

    private enum EventCategory {
        case net
        case ble
        case rf
        case gps
    }
}
