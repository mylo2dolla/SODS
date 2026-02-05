import SwiftUI

struct DashboardView: View {
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var bleScanner: BLEScanner
    @ObservedObject var piAuxStore: PiAuxStore
    @ObservedObject var entityStore: EntityStore
    @ObservedObject var sodsStore: SODSStore
    @ObservedObject var vaultTransport: VaultTransport
    let connectingNodeIDs: Set<String>
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
    let onStartScan: () -> Void
    let onStopScan: () -> Void
    let onGenerateScanReport: () -> Void
    let stationActionSections: () -> [ActionMenuSection]
    let scanActionSections: () -> [ActionMenuSection]
    let eventsActionSections: () -> [ActionMenuSection]
    let vaultActionSections: () -> [ActionMenuSection]
    let inboxActionSections: () -> [ActionMenuSection]

    @State private var showNet = true
    @State private var showBLE = true
    @State private var showRF = true
    @State private var showGPS = true
    @State private var showStationOverlay = false
    @State private var showScanSystemsOverlay = false
    @State private var showScanSummaryOverlay = false
    @State private var showPiAuxOverlay = false
    @State private var showVaultOverlay = false
    @State private var showInboxOverlay = false
    @State private var showEventsOverlay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dashboard")
                .font(.system(size: 18, weight: .semibold))

            let columns = [GridItem(.adaptive(minimum: 300), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                statusCard(title: "Station", onOpen: { showStationOverlay = true }) {
                    statusLine("Health", sodsStore.health == .connected || sodsStore.health == .degraded)
                    if let status = sodsStore.stationStatus {
                        Text("Uptime: \(uptimeLabel(ms: status.uptimeMs))")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        Text("Nodes online: \(status.nodesOnline ?? 0) / \(status.nodesTotal ?? 0)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("Uptime: Unknown")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Text("Now: \(Date().formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .popover(isPresented: $showStationOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Station", onClose: { showStationOverlay = false }, sections: stationActionSections()) {
                        stationDetailView()
                    }
                }

                statusCard(title: "Scan Systems", onOpen: { showScanSystemsOverlay = true }) {
                    statusLine("ONVIF Discovery", onvifDiscoveryEnabled)
                    statusLine("ARP Warmup", arpWarmupEnabled)
                    statusLine("Service Discovery", serviceDiscoveryEnabled)
                    statusLine("BLE Discovery", bleDiscoveryEnabled)
                    statusLine("Safe Mode", safeModeEnabled)
                    statusLine("Only Local Subnet", onlyLocalSubnet)
                }
                .popover(isPresented: $showScanSystemsOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Scan Systems", onClose: { showScanSystemsOverlay = false }, sections: scanActionSections()) {
                        scanSystemsDetailView()
                    }
                }

                statusCard(title: "Scan Summary", onOpen: { showScanSummaryOverlay = true }) {
                    let summary = scanner.scanSummary()
                    Text("Last scan: \(summary.end?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Scanning: \(scanner.isScanning ? "Yes" : "No")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Hosts found: \(entityStore.hosts.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("BLE devices: \(entityStore.blePeripherals.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .popover(isPresented: $showScanSummaryOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Scan Summary", onClose: { showScanSummaryOverlay = false }, sections: scanActionSections()) {
                        scanSummaryDetailView()
                    }
                }

                statusCard(title: "Pi-Aux Node", onOpen: { showPiAuxOverlay = true }) {
                    statusLine("Connected", piAuxStore.isRunning)
                    Text("Last event: \(piAuxStore.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Recent events (10m): \(piAuxStore.recentEventCount(window: 600))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Active nodes: \(entityStore.nodes.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    if let lastError = piAuxStore.lastError, !lastError.isEmpty {
                        Text("Last error: \(lastError)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .popover(isPresented: $showPiAuxOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Pi-Aux Node", onClose: { showPiAuxOverlay = false }, sections: scanActionSections()) {
                        piAuxDetailView()
                    }
                }

                statusCard(title: "Vault Shipping", onOpen: { showVaultOverlay = true }) {
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
                .popover(isPresented: $showVaultOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Vault Shipping", onClose: { showVaultOverlay = false }, sections: vaultActionSections()) {
                        vaultDetailView()
                    }
                }

                statusCard(title: "Inbox Retention", onOpen: { showInboxOverlay = true }) {
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
                .popover(isPresented: $showInboxOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Inbox Retention", onClose: { showInboxOverlay = false }, sections: inboxActionSections()) {
                        inboxDetailView()
                    }
                }
            }

            statusCard(title: "Nodes") {
                if entityStore.nodes.isEmpty {
                    Text("No nodes registered yet.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(entityStore.nodes) { node in
                            let presence = sodsStore.nodePresence[node.id]
                            let isScannerNode = node.capabilities.contains("scan")
                                || node.presenceState == .scanning
                                || presence?.state.lowercased() == "scanning"
                            NodeCardView(
                                node: node,
                                presence: presence,
                                eventCount: piAuxStore.recentEventCount(nodeID: node.id, window: 600),
                                actions: dashboardActions(for: node),
                                isScannerNode: isScannerNode,
                                isConnecting: connectingNodeIDs.contains(node.id),
                                onRefresh: {
                                    NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                                    sodsStore.connectNode(node.id)
                                    sodsStore.identifyNode(node.id)
                                    sodsStore.refreshStatus()
                                }
                            )
                        }
                    }
                }
            }

            statusCard(title: "Recent Events", onOpen: { showEventsOverlay = true }) {
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
            .popover(isPresented: $showEventsOverlay, arrowEdge: .bottom) {
                dashboardPopover(title: "Recent Events", onClose: { showEventsOverlay = false }, sections: eventsActionSections()) {
                    eventsDetailView(limit: 60)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCard(title: String, onOpen: (() -> Void)? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let onOpen {
                    Button("Details") { onOpen() }
                        .buttonStyle(SecondaryActionButtonStyle())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen?()
            }
            content()
        }
        .modifier(Theme.cardStyle())
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
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

    private func dashboardPopover(title: String, onClose: @escaping () -> Void, sections: [ActionMenuSection], @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ModalHeaderView(title: title, onBack: nil, onClose: onClose)
            content()
            if !sections.isEmpty {
                ActionMenuView(sections: sections)
            }
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .padding(12)
        .frame(minWidth: 320, maxWidth: 420)
        .background(Theme.panel)
    }

    private func stationDetailView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine("Health", sodsStore.health == .connected || sodsStore.health == .degraded)
            if let status = sodsStore.stationStatus {
                Text("Uptime: \(uptimeLabel(ms: status.uptimeMs))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Text("Nodes online: \(status.nodesOnline ?? 0) / \(status.nodesTotal ?? 0)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Uptime: Unknown")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Text("Now: \(Date().formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private func scanSystemsDetailView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine("ONVIF Discovery", onvifDiscoveryEnabled)
            statusLine("ARP Warmup", arpWarmupEnabled)
            statusLine("Service Discovery", serviceDiscoveryEnabled)
            statusLine("BLE Discovery", bleDiscoveryEnabled)
            statusLine("Safe Mode", safeModeEnabled)
            statusLine("Only Local Subnet", onlyLocalSubnet)
        }
    }

    private func scanSummaryDetailView() -> some View {
        let summary = scanner.scanSummary()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last scan: \(summary.end?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Scanning: \(scanner.isScanning ? "Yes" : "No")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Hosts found: \(entityStore.hosts.count)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("BLE devices: \(entityStore.blePeripherals.count)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            if !entityStore.nodes.isEmpty {
                Text("Node status")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(entityStore.nodes) { node in
                    let status = sodsStore.nodePresence[node.id]?.state ?? node.presenceState.rawValue
                    let presentation = NodePresentation.forNode(node, presence: sodsStore.nodePresence[node.id], activityScore: 0)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(presentation.displayColor))
                            .frame(width: 7, height: 7)
                        Text("\(node.label) • \(status)")
                            .font(.system(size: 10))
                            .foregroundColor(presentation.isOffline ? Theme.muted : Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func piAuxDetailView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine("Connected", piAuxStore.isRunning)
            Text("Last event: \(piAuxStore.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Recent events (10m): \(piAuxStore.recentEventCount(window: 600))")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Active nodes: \(entityStore.nodes.count)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            if let lastError = piAuxStore.lastError, !lastError.isEmpty {
                Text("Last error: \(lastError)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func vaultDetailView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
    }

    private func inboxDetailView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

    private func eventsDetailView(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

            let recent = filteredEvents(limit: limit)
            if recent.isEmpty {
                Text("No recent events")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                ScrollView {
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
                .frame(maxHeight: 240)
            }
        }
    }

    private func uptimeLabel(ms: Int?) -> String {
        guard let ms, ms > 0 else { return "Unknown" }
        let seconds = ms / 1000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func dashboardActions(for node: NodeRecord) -> [NodeAction] {
        var items: [NodeAction] = []
        let supportsScan = node.type == .mac || node.capabilities.contains("scan")
        let supportsReport = node.type == .mac || node.capabilities.contains("report")
        let supportsProbe = node.capabilities.contains("probe")
        let supportsPing = node.capabilities.contains("ping")

        if supportsScan {
            if scanner.isScanning {
                items.append(NodeAction(title: "Stop Scan", action: { onStopScan() }))
            } else {
                items.append(NodeAction(title: "Start Scan", action: { onStartScan() }))
            }
        }
        items.append(NodeAction(title: "Identify", action: { sodsStore.identifyNode(node.id) }))
        if supportsProbe {
            items.append(NodeAction(title: "Probe", action: {
                LogStore.shared.log(.info, "Probe action requested for node \(node.id)")
            }))
        }
        if supportsPing {
            items.append(NodeAction(title: "Ping", action: { piAuxStore.pingNode(node.id) }))
        }
        if supportsReport {
            items.append(NodeAction(title: "Generate Report", action: { onGenerateScanReport() }))
        }
        return items
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
