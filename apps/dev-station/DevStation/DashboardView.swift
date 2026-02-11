import SwiftUI
import Foundation
import AppKit

struct DashboardView: View {
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var bleScanner: BLEScanner
    @ObservedObject var piAuxStore: PiAuxStore
    @ObservedObject var entityStore: EntityStore
    @ObservedObject var sodsStore: SODSStore
    @ObservedObject var controlPlane: ControlPlaneStore
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
    let onStartStation: () -> Void
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
    @State private var showControlPlaneOverlay = false
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

                statusCard(title: "Control Plane", onOpen: { showControlPlaneOverlay = true }) {
                    statusLine("Vault", controlPlane.vault?.ok == true)
                    statusLine("Token", controlPlane.token?.ok == true)
                    statusLine("God Gateway", controlPlane.gateway?.ok == true)
                    statusLine("Ops Feed", controlPlane.opsFeed?.ok == true)
                    controlPlaneQuickActions()
                    if let detail = firstControlPlaneDetail() {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                .popover(isPresented: $showControlPlaneOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Control Plane", onClose: { showControlPlaneOverlay = false }, sections: []) {
                        controlPlaneDetailView()
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

                statusCard(title: "Node Overview", onOpen: { showPiAuxOverlay = true }) {
                    let totalNodes = entityStore.nodes.count
                    let onlineNodes = entityStore.nodes.filter(isNodeOnline).count
                    let scannerNodes = entityStore.nodes.filter { node in
                        node.capabilities.contains("scan")
                            || node.presenceState == .scanning
                            || sodsStore.nodePresence[node.id]?.state.lowercased() == "scanning"
                    }.count

                    statusLine("Any Connected", onlineNodes > 0)
                    Text("Nodes online: \(onlineNodes) / \(totalNodes)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Scanner nodes: \(scannerNodes)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Pi-Aux relay: \(piAuxStore.isRunning ? "Running" : "Stopped")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Last relay event: \(piAuxStore.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Relay events (10m): \(piAuxStore.recentEventCount(window: 600))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    if let lastError = piAuxStore.lastError, !lastError.isEmpty {
                        Text("Last error: \(lastError)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .popover(isPresented: $showPiAuxOverlay, arrowEdge: .bottom) {
                    dashboardPopover(title: "Node Overview", onClose: { showPiAuxOverlay = false }, sections: scanActionSections()) {
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
                        ForEach(entityStore.nodes, id: \.id) { node in
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
                                stationBaseURL: sodsStore.baseURL,
                                onRefresh: {
                                    NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                                    sodsStore.connectNode(node.id)
                                    sodsStore.identifyNode(node.id)
                                    sodsStore.refreshStatus()
                                },
                                onForget: {
                                    NodeRegistry.shared.remove(nodeID: node.id)
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
                    Button { onOpenNodes() } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))
                    }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Open Nodes")
                        .accessibilityLabel(Text("Open Nodes"))
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
                                Button { onOpenNodes() } label: {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                    .buttonStyle(SecondaryActionButtonStyle())
                                    .help("Go to Nodes")
                                    .accessibilityLabel(Text("Go to Nodes"))
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
                    Button { onOpen() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Details")
                        .accessibilityLabel(Text("Details"))
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
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Close")
                    .accessibilityLabel(Text("Close"))
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
        let totalNodes = entityStore.nodes.count
        let onlineNodes = entityStore.nodes.filter(isNodeOnline).count
        let scannerNodes = entityStore.nodes.filter { node in
            node.capabilities.contains("scan")
                || node.presenceState == .scanning
                || sodsStore.nodePresence[node.id]?.state.lowercased() == "scanning"
        }.count

        return VStack(alignment: .leading, spacing: 6) {
            statusLine("Any Connected", onlineNodes > 0)
            Text("Nodes online: \(onlineNodes) / \(totalNodes)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Scanner nodes: \(scannerNodes)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Pi-Aux relay: \(piAuxStore.isRunning ? "Running" : "Stopped")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Last relay event: \(piAuxStore.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("Relay events (10m): \(piAuxStore.recentEventCount(window: 600))")
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
                Button { onOpenNodes() } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Open Nodes")
                .accessibilityLabel(Text("Open Nodes"))
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
                                Button { onOpenNodes() } label: {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(SecondaryActionButtonStyle())
                                .help("Go to Nodes")
                                .accessibilityLabel(Text("Go to Nodes"))
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
        let supportsBLEControl = node.type == .mac || node.capabilities.contains("ble")
        let supportsReport = node.type == .mac || node.capabilities.contains("report")
        let supportsProbe = node.capabilities.contains("probe")
        let hostHint = nodeEndpointHint(for: node)
        let canRouteToNode = hostHint != nil

        if supportsScan {
            if scanner.isScanning {
                items.append(NodeAction(title: "Stop Scan", action: { onStopScan() }))
            } else {
                items.append(NodeAction(title: "Start Scan", action: { onStartScan() }))
            }
        }
        if supportsBLEControl {
            items.append(NodeAction(title: bleDiscoveryEnabled ? "Stop BLE Scan" : "Start BLE Scan", action: {
                if bleDiscoveryEnabled {
                    bleScanner.stopScan()
                } else {
                    bleScanner.startScan(mode: .continuous)
                }
            }))
        }
        items.append(NodeAction(title: "Target Lock", action: {
            NotificationCenter.default.post(name: .targetLockNodeCommand, object: node.id)
        }))
        if canRouteToNode {
            items.append(NodeAction(title: "Connect Node", action: {
                NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                sodsStore.connectNode(node.id, hostHint: hostHint)
                sodsStore.identifyNode(node.id, hostHint: hostHint)
                sodsStore.refreshStatus()
                piAuxStore.connectNode(node.id)
            }))
            items.append(NodeAction(title: "Identify", action: { sodsStore.identifyNode(node.id, hostHint: hostHint) }))
        }
        if let signalNode = signalNode(for: node), signalNode.ip != nil {
            items.append(NodeAction(title: "Whoami", action: { sodsStore.openEndpoint(for: signalNode, path: "/whoami") }))
            items.append(NodeAction(title: "Health", action: { sodsStore.openEndpoint(for: signalNode, path: "/health") }))
            items.append(NodeAction(title: "Metrics", action: { sodsStore.openEndpoint(for: signalNode, path: "/metrics") }))
        }
        if supportsProbe {
            items.append(NodeAction(title: "Probe", action: {
                // Keep this as a real action: ask Station to connect+identify (updates registry + errors).
                if canRouteToNode {
                    NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                    sodsStore.connectNode(node.id, hostHint: hostHint)
                }
                sodsStore.identifyNode(node.id, hostHint: hostHint)
                sodsStore.refreshStatus()
            }))
        }
        if supportsReport {
            items.append(NodeAction(title: "Generate Report", action: { onGenerateScanReport() }))
        }
        return dedupeNodeActions(items)
    }

    private func nodeEndpointHint(for node: NodeRecord) -> String? {
        if let ip = node.ip?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { return ip }
        if let host = node.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty { return host }
        if let mac = node.mac?.trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty,
           let host = entityStore.hosts.first(where: { $0.macAddress?.caseInsensitiveCompare(mac) == .orderedSame }) {
            return host.ip
        }
        if let presence = sodsStore.nodePresence[node.id] {
            if let ip = presence.ip?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { return ip }
            if let host = presence.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty { return host }
            if let mac = presence.mac?.trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty,
               let host = entityStore.hosts.first(where: { $0.macAddress?.caseInsensitiveCompare(mac) == .orderedSame }) {
                return host.ip
            }
        }
        if let host = entityStore.hosts.first(where: {
            ($0.hostname?.caseInsensitiveCompare(node.id) == .orderedSame) || ($0.ip == node.id)
        }) {
            return host.ip
        }
        return nil
    }

    private func signalNode(for node: NodeRecord) -> SignalNode? {
        SignalNode(
            id: node.id,
            lastSeen: node.lastSeen ?? node.lastHeartbeat ?? .distantPast,
            ip: node.ip,
            hostname: node.hostname,
            mac: node.mac,
            lastKind: node.capabilities.first
        )
    }

    private func dedupeNodeActions(_ actions: [NodeAction]) -> [NodeAction] {
        var seen = Set<String>()
        var output: [NodeAction] = []
        for action in actions {
            if seen.insert(action.title).inserted {
                output.append(action)
            }
        }
        return output
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

    private func isNodeOnline(_ node: NodeRecord) -> Bool {
        if let state = sodsStore.nodePresence[node.id]?.state.lowercased() {
            switch state {
            case "online", "idle", "scanning", "connected":
                return true
            default:
                break
            }
        }
        switch node.presenceState {
        case .connected, .idle, .scanning:
            return true
        case .offline, .error:
            return false
        }
    }

    private func firstControlPlaneDetail() -> String? {
        let items: [ControlPlaneStore.CheckResult?] = [controlPlane.vault, controlPlane.token, controlPlane.gateway, controlPlane.opsFeed]
        if let bad = items.compactMap({ $0 }).first(where: { $0.ok == false }) {
            return "\(bad.label): \(bad.detail)"
        }
        if let good = items.compactMap({ $0 }).first(where: { $0.ok == true }) {
            let stamp = good.checkedAt.formatted(date: .omitted, time: .shortened)
            return "Last check: \(stamp)"
        }
        return nil
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func controlPlaneQuickActions() -> some View {
        let eps = controlPlane.endpoints()
        let vaultOk = controlPlane.vault?.ok == true
        let tokenOk = controlPlane.token?.ok == true
        let gatewayOk = controlPlane.gateway?.ok == true
        let opsOk = controlPlane.opsFeed?.ok == true

        return HStack(spacing: 8) {
            Button { controlPlane.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Retry control plane checks")
            .accessibilityLabel(Text("Retry control plane checks"))

            Button { controlPlane.probeTokenOnce() } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tokenOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Probe token server (POST /token)")
            .accessibilityLabel(Text("Probe token server"))

            Button { controlPlane.probeGatewayOnce() } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(gatewayOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Probe God Gateway (/god ritual.rollcall)")
            .accessibilityLabel(Text("Probe God Gateway"))

            Button { openURL(eps.vaultHealth) } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(vaultOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Open Vault health")
            .accessibilityLabel(Text("Open Vault health"))

            Button { openURL(eps.tokenEndpoint) } label: {
                Image(systemName: "key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tokenOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Open Token endpoint")
            .accessibilityLabel(Text("Open Token endpoint"))

            Button { openURL(eps.gatewayHealth) } label: {
                Image(systemName: "bolt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(gatewayOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Open God Gateway health")
            .accessibilityLabel(Text("Open God Gateway health"))

            Button { openURL(eps.opsFeedHealth) } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(opsOk ? Theme.muted : Theme.accent)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Open Ops Feed health")
            .accessibilityLabel(Text("Open Ops Feed health"))

            Spacer()
        }
        .padding(.top, 2)
    }

    private func controlPlaneDetailView() -> some View {
        let eps = controlPlane.endpoints()
        let items: [(label: String, result: ControlPlaneStore.CheckResult?, url: URL, icon: String)] = [
            ("Vault", controlPlane.vault, eps.vaultHealth, "archivebox"),
            ("Token", controlPlane.token, eps.tokenEndpoint, "key"),
            ("God Gateway", controlPlane.gateway, eps.gatewayHealth, "bolt"),
            ("Ops Feed", controlPlane.opsFeed, eps.opsFeedHealth, "dot.radiowaves.left.and.right"),
        ]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { controlPlane.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Retry")
                .accessibilityLabel(Text("Retry"))

                Spacer()
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Text(item.label)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Circle()
                            .fill((item.result?.ok == true) ? Theme.accent : Theme.muted)
                            .frame(width: 8, height: 8)
                        Text((item.result?.ok == true) ? "On" : "Off")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        Button { openURL(item.url) } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Open")
                        .accessibilityLabel(Text("Open"))
                    }

                    Text(item.url.absoluteString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.muted)

                    if let result = item.result {
                        Text(result.detail)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(3)
                        Text("Checked: \(result.checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.muted)
                    } else {
                        Text("Not checked yet.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(10)
                .background(Theme.panelAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .cornerRadius(10)
            }
        }
    }
}
