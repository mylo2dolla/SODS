import SwiftUI
import Foundation

struct ScanningView: View {
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var bleScanner: BLEScanner
    @ObservedObject var sodsStore: SODSStore
    @ObservedObject var piAuxStore: PiAuxStore

    let nodes: [NodeRecord]
    let nodePresence: [String: NodePresence]
    let connectingNodeIDs: Set<String>

    @Binding var onvifDiscoveryEnabled: Bool
    @Binding var serviceDiscoveryEnabled: Bool
    @Binding var arpWarmupEnabled: Bool
    @Binding var bleDiscoveryEnabled: Bool
    @Binding var safeModeEnabled: Bool
    @Binding var onlyLocalSubnet: Bool
    @Binding var scopeCIDR: String
    @Binding var rangeStart: String
    @Binding var rangeEnd: String
    @Binding var showLogs: Bool
    @Binding var networkScanMode: ScanMode
    @Binding var bleScanMode: ScanMode

    let onStartNetworkScan: () -> Void
    let onStopAllScanning: () -> Void
    let onSetBLEScanning: (Bool) -> Void
    let onGenerateScanReport: () -> Void
    let onRevealLatestReport: () -> Void
    let onRestoreCoreNodes: () -> Void
    let onOpenNodes: () -> Void

    let onOpenNodeInNodes: (String) -> Void
    let onRefreshNode: (String) -> Void
    let onIdentifyNode: (String) -> Void
    let onProbeNode: (String) -> Void
    let onSetNodeScan: (String, Bool) -> Void

    private let coreNodeOrder: [String] = ["exec-pi-aux", "exec-pi-logger", "mac16"]
    private let serviceOnlyNodeIDs: Set<String> = [
        "god-gateway",
        "gateway",
        "service:god-gateway",
        "service:token",
        "service:ops-feed",
        "service:vault",
        "strangelab-god-gateway",
        "strangelab-token",
        "strangelab-ops-feed",
        "token-server",
        "ops-feed",
        "vault-ingest"
    ]

    private var scanSummary: NetworkScanner.ScanSummary {
        scanner.scanSummary()
    }

    private var coreNodeIDSet: Set<String> {
        Set(coreNodeOrder)
    }

    private var coreNodes: [NodeRecord] {
        let map = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return coreNodeOrder.compactMap { map[$0] }
    }

    private var scannerNodes: [NodeRecord] {
        nodes.filter { node in
            !coreNodeIDSet.contains(node.id) && isScannerCapable(node: node, presence: nodePresence[node.id])
        }
    }

    private var onlineCoreNodeCount: Int {
        coreNodes.filter { node in
            isNodeOnline(node: node, presence: nodePresence[node.id])
        }.count
    }

    private var onlineScannerNodeCount: Int {
        scannerNodes.filter { node in
            isNodeOnline(node: node, presence: nodePresence[node.id])
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            globalScanControlSection
            globalStatusStrip
            globalActionRow
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    coreNodeSection
                    scannerNodeSection
                }
                .padding(.bottom, 12)
            }
        }
        .padding(16)
    }

    private var globalScanControlSection: some View {
        GroupBox("Scan Control") {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("CIDR")
                            .frame(width: 50, alignment: .leading)
                            .font(.system(size: 11))
                        TextField("192.168.1.0/24", text: $scopeCIDR)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("Range")
                            .frame(width: 50, alignment: .leading)
                            .font(.system(size: 11))
                        TextField("Start", text: $rangeStart)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("End", text: $rangeEnd)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("CIDR")
                                .font(.system(size: 11))
                            TextField("192.168.1.0/24", text: $scopeCIDR)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            Text("Range")
                                .font(.system(size: 11))
                            TextField("Start", text: $rangeStart)
                                .textFieldStyle(.roundedBorder)
                            TextField("End", text: $rangeEnd)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Toggle("Only local subnet", isOn: $onlyLocalSubnet)
                    Toggle("Safe Mode", isOn: $safeModeEnabled)
                }
                .font(.system(size: 11))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                HStack(spacing: 12) {
                    Toggle("ONVIF", isOn: $onvifDiscoveryEnabled)
                    Toggle("Service Disc.", isOn: $serviceDiscoveryEnabled)
                    Toggle("ARP Warmup", isOn: $arpWarmupEnabled)
                    Toggle(
                        "BLE",
                        isOn: Binding(
                            get: { bleScanner.isScanning },
                            set: { bleDiscoveryEnabled = $0 }
                        )
                    )
                }
                .font(.system(size: 11))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Net Scan")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("Net Scan", selection: $networkScanMode) {
                            ForEach(ScanMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        Text("BLE Scan")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("BLE Scan", selection: $bleScanMode) {
                            ForEach(ScanMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Net Scan")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("Net Scan", selection: $networkScanMode) {
                            ForEach(ScanMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("BLE Scan")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("BLE Scan", selection: $bleScanMode) {
                            ForEach(ScanMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        if scanner.isScanning {
                            Button { onStopAllScanning() } label: {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .help("Stop Scan")
                            .accessibilityLabel(Text("Stop Scan"))
                        } else {
                            Button { onStartNetworkScan() } label: {
                                Image(systemName: networkScanMode == .oneShot ? "play.circle.fill" : "playpause.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .help("Start \(networkScanMode.label) Scan")
                            .accessibilityLabel(Text("Start \(networkScanMode.label) Scan"))
                        }
                        Button { onGenerateScanReport() } label: {
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Generate Scan Report")
                        .accessibilityLabel(Text("Generate Scan Report"))
                        Button { onRevealLatestReport() } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Reveal Latest Report")
                        .accessibilityLabel(Text("Reveal Latest Report"))
                        Button { onRestoreCoreNodes() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Restore Core Nodes")
                        .accessibilityLabel(Text("Restore Core Nodes"))
                        Toggle("Logs Panel", isOn: $showLogs)
                            .toggleStyle(.switch)
                            .font(.system(size: 11))
                            .tint(Theme.accent)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            if scanner.isScanning {
                                Button { onStopAllScanning() } label: {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(PrimaryActionButtonStyle())
                                .help("Stop Scan")
                                .accessibilityLabel(Text("Stop Scan"))
                            } else {
                                Button { onStartNetworkScan() } label: {
                                    Image(systemName: networkScanMode == .oneShot ? "play.circle.fill" : "playpause.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(PrimaryActionButtonStyle())
                                .help("Start \(networkScanMode.label) Scan")
                                .accessibilityLabel(Text("Start \(networkScanMode.label) Scan"))
                            }
                            Button { onGenerateScanReport() } label: {
                                Image(systemName: "doc.badge.gearshape")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Generate Scan Report")
                            .accessibilityLabel(Text("Generate Scan Report"))
                            Button { onRevealLatestReport() } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Reveal Latest Report")
                            .accessibilityLabel(Text("Reveal Latest Report"))
                        }
                        HStack(spacing: 10) {
                            Button { onRestoreCoreNodes() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Restore Core Nodes")
                            .accessibilityLabel(Text("Restore Core Nodes"))
                            Toggle("Logs Panel", isOn: $showLogs)
                                .toggleStyle(.switch)
                                .font(.system(size: 11))
                                .tint(Theme.accent)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var globalStatusStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    StatusChipView(
                        label: "Network",
                        value: scanner.isScanning ? "Running" : "Idle",
                        tint: scanner.isScanning ? Theme.accent : Theme.muted
                    )
                    StatusChipView(
                        label: "BLE",
                        value: bleScanner.isScanning ? "Running" : "Idle",
                        tint: bleScanner.isScanning ? Theme.accent : Theme.muted
                    )
                    StatusChipView(
                        label: "Last scan",
                        value: scanSummary.end?.formatted(date: .abbreviated, time: .shortened) ?? "None",
                        monospacedValue: true
                    )
                    if let progress = scanner.progress {
                        StatusChipView(
                            label: "Progress",
                            value: "\(progress.scannedHosts)/\(max(0, progress.totalHosts))",
                            monospacedValue: true
                        )
                    }
                    StatusChipView(label: "Scanner nodes", value: "\(scannerNodes.count)")
                    StatusChipView(label: "Scanner online", value: "\(onlineScannerNodeCount)")
                    StatusChipView(label: "Core nodes", value: "\(coreNodes.count)")
                    StatusChipView(label: "Core online", value: "\(onlineCoreNodeCount)")
                }
                .padding(.vertical, 2)
            }

            if let progress = scanner.progress {
                ProgressView(value: Double(progress.scannedHosts), total: Double(max(1, progress.totalHosts)))
                Text("Scanned \(progress.scannedHosts) of \(progress.totalHosts) hosts")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            if let statusMessage = scanner.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .modifier(Theme.cardStyle())
    }

    private var globalActionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                globalActionButtons
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    globalActionButtons
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var globalActionButtons: some View {
        Group {
            if scanner.isScanning {
                Button {
                    onStopAllScanning()
                } label: {
                    Label("Stop Network Scan", systemImage: "stop.circle")
                }
                .buttonStyle(SecondaryActionButtonStyle())
            } else {
                Button {
                    onStartNetworkScan()
                } label: {
                    Label("Start Network Scan", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            Button {
                onSetBLEScanning(!bleScanner.isScanning)
            } label: {
                Label(
                    bleScanner.isScanning ? "Stop BLE Scan" : "Start BLE Scan",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }
            .buttonStyle(SecondaryActionButtonStyle())

            Button {
                onGenerateScanReport()
            } label: {
                Label("Generate Report", systemImage: "doc.text")
            }
            .buttonStyle(SecondaryActionButtonStyle())

            Button {
                onOpenNodes()
            } label: {
                Label("Open Nodes", systemImage: "square.grid.2x2")
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
    }

    private var coreNodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Core Nodes", subtitle: "aux / vault / mac16")
            if coreNodes.isEmpty {
                Text("Core nodes are missing. Use Restore Core Nodes in Scanners controls above.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(coreNodes) { node in
                        nodeCard(for: node)
                    }
                }
            }
        }
        .modifier(Theme.cardStyle())
    }

    private var scannerNodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Scanner Nodes", subtitle: "\(onlineScannerNodeCount) online")
            if scannerNodes.isEmpty {
                Text("No scanner-capable nodes are available right now. You can still run global network and BLE scans above.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(scannerNodes) { node in
                        nodeCard(for: node)
                    }
                }
            }
        }
        .modifier(Theme.cardStyle())
    }

    private func nodeCard(for node: NodeRecord) -> some View {
        let presence = nodePresence[node.id]
        let isServiceNode = isServicePseudoNode(node.id)
        let supportsScan = !isServiceNode && isScannerCapable(node: node, presence: presence)
        let supportsProbe = !isServiceNode && supportsProbe(node: node)
        let supportsReport = !isServiceNode && supportsReport(node: node)

        return ScannerNodeCardView(
            node: node,
            presence: presence,
            isConnecting: connectingNodeIDs.contains(node.id),
            eventCount: piAuxStore.recentEventCount(nodeID: node.id, window: 600),
            isServicePseudoNode: isServiceNode,
            supportsScan: supportsScan,
            supportsProbe: supportsProbe,
            supportsReport: supportsReport,
            onRefresh: {
                guard !isServiceNode else { return }
                onRefreshNode(node.id)
            },
            onIdentify: {
                guard !isServiceNode else { return }
                onIdentifyNode(node.id)
            },
            onToggleNodeScan: { enabled in
                guard !isServiceNode else { return }
                onSetNodeScan(node.id, enabled)
            },
            onProbe: {
                guard !isServiceNode else { return }
                onProbeNode(node.id)
            },
            onGenerateReport: {
                guard !isServiceNode else { return }
                onGenerateScanReport()
            },
            onOpenInNodes: {
                onOpenNodeInNodes(node.id)
            }
        )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func isScannerCapable(node: NodeRecord, presence: NodePresence?) -> Bool {
        let explicitCaps = Set(node.capabilities.map { $0.lowercased() })
        if explicitCaps.contains("scan") {
            return true
        }
        if node.presenceState == .scanning {
            return true
        }
        if let state = presence?.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), state == "scanning" {
            return true
        }
        return presence?.capabilities.canScanWifi == true || presence?.capabilities.canScanBle == true
    }

    private func isNodeOnline(node: NodeRecord, presence: NodePresence?) -> Bool {
        let effectiveState = CoreNodeStateResolver.effectiveState(node: node, presence: presence)
        return CoreNodeStateResolver.isOnline(effectiveState)
    }

    private func supportsProbe(node: NodeRecord) -> Bool {
        Set(node.capabilities.map { $0.lowercased() }).contains("probe")
    }

    private func supportsReport(node: NodeRecord) -> Bool {
        Set(node.capabilities.map { $0.lowercased() }).contains("report")
    }

    private func isServicePseudoNode(_ nodeID: String) -> Bool {
        serviceOnlyNodeIDs.contains(nodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

private struct ScannerNodeCardView: View {
    let node: NodeRecord
    let presence: NodePresence?
    let isConnecting: Bool
    let eventCount: Int
    let isServicePseudoNode: Bool
    let supportsScan: Bool
    let supportsProbe: Bool
    let supportsReport: Bool

    let onRefresh: () -> Void
    let onIdentify: () -> Void
    let onToggleNodeScan: (Bool) -> Void
    let onProbe: () -> Void
    let onGenerateReport: () -> Void
    let onOpenInNodes: () -> Void

    private var effectiveState: NodePresenceState {
        CoreNodeStateResolver.effectiveState(node: node, presence: presence)
    }

    private var stateLabel: String {
        if isConnecting {
            return "Connecting"
        }
        if let state = presence?.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), state == "connecting" {
            return "Connecting"
        }
        return CoreNodeStateResolver.statusLabel(for: effectiveState)
    }

    private var isOnline: Bool {
        if isConnecting {
            return false
        }
        return CoreNodeStateResolver.isOnline(effectiveState)
    }

    private var isScanning: Bool {
        CoreNodeStateResolver.isScanning(effectiveState)
    }

    private var statusColor: Color {
        if isConnecting {
            return .orange
        }
        if isScanning {
            return Theme.accent
        }
        if isOnline {
            return .green
        }
        if lastErrorLine != nil {
            return .orange
        }
        return Theme.muted
    }

    private var lastSeenText: String {
        if let presence, presence.lastSeen > 0 {
            return Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000.0)
                .formatted(date: .abbreviated, time: .shortened)
        }
        if let stamp = node.lastSeen ?? node.lastHeartbeat {
            return stamp.formatted(date: .abbreviated, time: .shortened)
        }
        return "Not seen yet"
    }

    private var lastErrorLine: String? {
        let message = (presence?.lastError ?? node.lastError)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else { return nil }
        return message
    }

    private var capabilityLabels: [String] {
        var caps = Set(node.capabilities.map { $0.lowercased() })
        if supportsScan { caps.insert("scan") }
        if supportsProbe { caps.insert("probe") }
        if supportsReport { caps.insert("report") }

        if let presence {
            if presence.capabilities.canScanWifi == true || presence.capabilities.canScanBle == true {
                caps.insert("scan")
            }
            if presence.capabilities.canFrames == true {
                caps.insert("frames")
            }
            if presence.capabilities.canFlash == true {
                caps.insert("flash")
            }
            if presence.capabilities.canWhoami == true {
                caps.insert("identify")
            }
        }

        return caps.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(node.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(stateLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }

            Text("Node ID: \(node.id)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            Text("Last seen: \(lastSeenText)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            Text("Events (10m): \(eventCount)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            if let lastErrorLine {
                Text("Last error: \(lastErrorLine)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            if isServicePseudoNode {
                Text("Service-only entry. Managed by Stack Status.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    if capabilityLabels.isEmpty {
                        ScannerCapabilityBadge(label: "none")
                    } else {
                        ForEach(capabilityLabels, id: \.self) { cap in
                            ScannerCapabilityBadge(label: cap)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                actionButton(title: "Refresh", systemImage: "arrow.clockwise", disabled: isServicePseudoNode, action: onRefresh)
                actionButton(title: "Identify", systemImage: "scope", disabled: isServicePseudoNode, action: onIdentify)
                if supportsScan {
                    actionButton(
                        title: isScanning ? "Stop Scan" : "Start Scan",
                        systemImage: isScanning ? "stop.circle" : "dot.radiowaves.left.and.right",
                        disabled: isServicePseudoNode,
                        action: { onToggleNodeScan(!isScanning) }
                    )
                }
                if supportsProbe {
                    actionButton(title: "Probe", systemImage: "antenna.radiowaves.left.and.right", disabled: isServicePseudoNode, action: onProbe)
                }
                if supportsReport {
                    actionButton(title: "Report", systemImage: "doc.text", disabled: isServicePseudoNode, action: onGenerateReport)
                }
                actionButton(title: "Open Nodes", systemImage: "square.grid.2x2", action: onOpenInNodes)
            }
        }
        .modifier(Theme.cardStyle())
    }

    @ViewBuilder
    private func actionButton(title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(SecondaryActionButtonStyle())
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

private struct ScannerCapabilityBadge: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Theme.panelAlt)
            .overlay(
                Capsule()
                    .stroke(Theme.border.opacity(0.7), lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}
