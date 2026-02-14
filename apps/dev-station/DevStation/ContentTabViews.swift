import SwiftUI
import Foundation
import AppKit

struct DiscoveredNodeItem: Identifiable, Hashable {
    let id: String
    let label: String
    let lastSeen: Date?
    let presence: NodePresence
}

struct ConnectCandidate: Identifiable, Hashable {
    let id: String
    let label: String
    let isClaimed: Bool
    let lastSeen: Date?

    var displayLabel: String {
        let status = isClaimed ? "claimed" : "discovered"
        if label == id {
            return "\(id) • \(status)"
        }
        return "\(label) (\(id)) • \(status)"
    }
}

struct NodesView: View {
    @ObservedObject var store: PiAuxStore
    @ObservedObject var sodsStore: SODSStore
    let nodes: [NodeRecord]
    let nodePresence: [String: NodePresence]
    let connectingNodeIDs: Set<String>
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var flashManager: FlashServerManager
    let connectCandidates: [ConnectCandidate]
    let discoveredNodes: [DiscoveredNodeItem]
    let flashLifecycleStage: ContentView.DeviceLifecycleStage?
    let flashLifecycleTarget: FlashTarget?
    let flashLifecycleNodeID: String?
    let bleIsScanning: Bool
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
    @Binding var connectNodeID: String
    @Binding var showFlashConfirm: Bool
    let onStartScan: () -> Void
    let onStopScan: () -> Void
    let onGenerateScanReport: () -> Void
    let onRevealLatestReport: () -> Void
    let onFindDevice: () -> Void
    let onFlashStarted: (FlashTarget) -> Void
    let onFlashAwaitingHello: () -> Void
    let onFlashClaimed: (String) -> Void
    let onRestoreCoreNodes: () -> Void
    @StateObject private var nodeRegistry = NodeRegistry.shared
    @State private var portText: String = ""
    @State private var manualConnectHost: String = ""
    @State private var manualConnectLabel: String = ""
    @State private var addNodeID: String = ""
    @State private var addNodeLabel: String = ""
    @State private var addNodeIP: String = ""
    @State private var addNodeMAC: String = ""
    @State private var manualConnectError: String?
    @State private var isManualConnecting = false
    private let serviceOnlyNodeMessage = "Endpoint identifies as control-plane service, not a device node."
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                nodesColumn
                sideColumn
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: 520, alignment: .topLeading)
            }
            VStack(spacing: 12) {
                nodesColumn
                sideColumn
            }
        }
        .padding(16)
    }

    private var nodesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nodes")
                .font(.system(size: 16, weight: .semibold))

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { _, node in
                        let presence = nodePresence[node.id]
                        let isServiceNode = isServicePseudoNode(node.id)
                        let isScannerNode = node.capabilities.map { $0.lowercased() }.contains("scan")
                            || presence?.capabilities.canScanWifi == true
                            || presence?.capabilities.canScanBle == true
                            || node.presenceState == .scanning
                            || presence?.state.lowercased() == "scanning"
	                        NodeCardView(
	                            node: node,
	                            presence: presence,
	                            eventCount: store.recentEventCount(nodeID: node.id, window: 600),
	                            actions: actions(for: node),
	                            isScannerNode: isScannerNode,
                                isServicePseudoNode: isServiceNode,
	                            isConnecting: connectingNodeIDs.contains(node.id),
	                            stationBaseURL: sodsStore.baseURL,
	                            onRefresh: {
                                    guard !isServiceNode else { return }
	                                NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
	                                sodsStore.connectNode(node.id)
	                                sodsStore.identifyNode(node.id)
                                sodsStore.refreshStatus()
                            },
                            onForget: {
                                NodeRegistry.shared.remove(nodeID: node.id)
                            }
                        )
                    }
                }
                .padding(.bottom, 12)

                Text("Last \(store.events.count) Events")
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.events.suffix(50).reversed()) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.timestamp) • \(event.kind.rawValue) • \(event.deviceID)")
                                .font(.system(size: 11))
                            if !event.data.isEmpty {
                                Text(event.data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if !event.tags.isEmpty {
                                Text("tags: \(event.tags.joined(separator: ", "))")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            scanControlSection
            GroupBox("Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Endpoint: \(store.endpointURL)")
                        .font(.system(size: 12))
                    Text("Endpoint host: \(endpointHost)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    if endpointIsLocal {
                        Text("Warning: localhost endpoints cannot be reached by remote nodes.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    if let lastError = store.lastError, !lastError.isEmpty {
                        Text("Last error: \(lastError)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Text("Shared Secret:")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.token)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Text("Port:")
                            .font(.system(size: 12))
                        TextField("9123", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onAppear {
                                portText = String(store.port)
                            }
                        Button {
                            if let value = Int(portText) {
                                store.updatePort(value)
                            }
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Apply")
                        .accessibilityLabel(Text("Apply"))

                        Button {
                            store.testPing()
                        } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Test Ping")
                        .accessibilityLabel(Text("Test Ping"))
                    }
                    if let lastPing = store.lastPingResult, !lastPing.isEmpty {
                        Text("Ping: \(lastPing)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    } else if let lastPingError = store.lastPingError, !lastPingError.isEmpty {
                        Text("Ping error: \(lastPingError)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(6)
            }

            flashControlSection
            Spacer()
        }
    }

    private var scanControlSection: some View {
        GroupBox("Scan Control") {
            VStack(alignment: .leading, spacing: 8) {
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
                    Toggle("BLE", isOn: Binding(get: { bleIsScanning }, set: { bleDiscoveryEnabled = $0 }))
                }
                .font(.system(size: 11))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
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
                HStack(spacing: 10) {
                    if scanner.isScanning {
                        Button { onStopScan() } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .help("Stop Scan")
                            .accessibilityLabel(Text("Stop Scan"))
                    } else {
                        Button { onStartScan() } label: {
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
            }
            .padding(6)
        }
    }

    private var flashControlSection: some View {
        GroupBox("Node Actions") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Connect")
                        .font(.system(size: 11))
                    if connectCandidates.isEmpty {
                        Text("No discovered or claimed nodes yet.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Picker("Node", selection: $connectNodeID) {
                            ForEach(connectCandidates) { candidate in
                                Text(candidate.displayLabel).tag(candidate.id)
                            }
                        }
                        .frame(width: 320)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Text("Host/IP")
                        .font(.system(size: 11))
                    TextField("192.168.1.22", text: $manualConnectHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    TextField("Label (optional)", text: $manualConnectLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button { connectSelectedNode() } label: {
                        if isManualConnecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "link.circle")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isManualConnecting)
                    .help(isManualConnecting ? "Connecting..." : "Connect Node")
                    .accessibilityLabel(Text(isManualConnecting ? "Connecting..." : "Connect Node"))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Persist Node (Manual)")
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField("Node ID", text: $addNodeID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField("Label", text: $addNodeLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField("IP", text: $addNodeIP)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        TextField("MAC", text: $addNodeMAC)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Button {
                            addOrUpdateManualNode()
                        }
                        label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Add / Update")
                        .accessibilityLabel(Text("Add / Update"))
                    }
                    if !nodeRegistry.nodes.isEmpty {
                        Text("Claimed nodes persist in \(StoragePaths.workspaceSubdir("registry").path)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                if let manualConnectError {
                    Text(manualConnectError)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                if let lastError = sodsStore.lastError, !lastError.isEmpty {
                    Text("Connect error: \(lastError)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                if let stage = flashLifecycleStage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lifecycle: \(stage.label)")
                            .font(.system(size: 11, weight: .semibold))
                        Text(stage.detail)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                        if let target = flashLifecycleTarget {
                            Text("Target: \(target.label)")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                        }
                        if let nodeID = flashLifecycleNodeID, !nodeID.isEmpty {
                            Text("Node: \(nodeID)")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                        }
                        if stage == .discovered {
                            Text("Discovered device ready to claim.")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.accent)
                        }
                    }
                }

                if !discoveredNodes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Discovered")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(discoveredNodes) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.system(size: 11, weight: .semibold))
                                    if let lastSeen = item.lastSeen {
                                        Text("Last seen: \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textSecondary)
                                    }
                                    if let ip = item.presence.ip, !ip.isEmpty {
                                        Text("IP: \(ip)")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textSecondary)
                                    }
                                    if let mac = item.presence.mac, !mac.isEmpty {
                                        Text("MAC: \(mac)")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    claimDiscovered(item)
                                }
                                label: {
                                    Image(systemName: "checkmark.seal")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(SecondaryActionButtonStyle())
                                .help("Claim")
                                .accessibilityLabel(Text("Claim"))
                            }
                            .padding(8)
                            .background(Theme.panelAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else {
                    Text("Discovered: none (yet).")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }

                HStack(spacing: 10) {
                    Text("Flash Target")
                        .font(.system(size: 11))
                    Picker("Target", selection: $flashManager.selectedTarget) {
                        ForEach(FlashTarget.allCases) { target in
                            Label(target.label, systemImage: target.systemImage)
                                .labelStyle(.iconOnly)
                                .tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        showFlashConfirm = true
                    }
                    label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(flashManager.isStarting)
                    .help("Flash Firmware")
                    .accessibilityLabel(Text("Flash Firmware"))
                    .confirmationDialog(
                        "Flash firmware to \(flashManager.selectedTarget.label)?",
                        isPresented: $showFlashConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Flash \(flashManager.selectedTarget.label)", role: .destructive) {
                            onFlashStarted(flashManager.selectedTarget)
                            flashManager.startSelectedTarget()
                            onFlashAwaitingHello()
                            onFindDevice()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will open the station flasher for the selected target. Confirm before continuing.")
                    }

                    Button {
                        flashManager.openLocalFlasher()
                    }
                    label: {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Open Station Flasher")
                    .accessibilityLabel(Text("Open Station Flasher"))

                    if flashManager.canOpenFlasher {
                        Button {
                            flashManager.openFlasher()
                        }
                        label: {
                            Image(systemName: "safari.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Open Flasher")
                        .accessibilityLabel(Text("Open Flasher"))
                    }

                    if flashManager.isRunning {
                        Button {
                            flashManager.stop()
                        }
                        label: {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Stop Server")
                        .accessibilityLabel(Text("Stop Server"))
                    }
                    Button {
                        onFlashAwaitingHello()
                        onFindDevice()
                    }
                    label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Find Newly Flashed Device")
                    .accessibilityLabel(Text("Find Newly Flashed Device"))
                    Spacer()
                }

                if let status = flashManager.statusLine {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }

                if let detail = flashManager.detailLine {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }

                if let terminalCommand = flashManager.terminalCommand {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sandbox fallback")
                            .font(.system(size: 11, weight: .semibold))
                        Text(terminalCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(Theme.textSecondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(terminalCommand, forType: .string)
                        }
                        label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Copy Command")
                        .accessibilityLabel(Text("Copy Command"))
                    }
                }

                flashPrepSection
            }
            .padding(6)
            .onAppear { flashManager.refreshPrepStatus() }
            .onChange(of: flashManager.selectedTarget) { _ in
                flashManager.refreshPrepStatus()
            }
            .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
                autoReconnectClaimedNodes()
            }
        }
    }

    private var flashPrepSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Flash Prep")
                .font(.system(size: 12, weight: .semibold))
            if flashManager.prepStatus.isReady {
                Text("Ready: staged firmware artifacts detected.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Build/Stage required.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                ForEach(flashManager.prepStatus.missingItems, id: \.self) { item in
                    Text("Missing: \(item)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    Text(flashManager.prepStatus.buildCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(flashManager.prepStatus.buildCommand, forType: .string)
                    }
                    label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Copy")
                    .accessibilityLabel(Text("Copy"))
                    Spacer()
                }
            }
        }
    }

    private func actions(for node: NodeRecord) -> [NodeAction] {
        if isServicePseudoNode(node.id) {
            return []
        }
        var items: [NodeAction] = []
        let supportsScan = supportsScanAction(for: node)
        let supportsReport = supportsReportAction(for: node)
        let supportsProbe = supportsProbeAction(for: node)

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
                NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                sodsStore.connectNode(node.id)
                sodsStore.identifyNode(node.id)
                sodsStore.refreshStatus()
            }))
        }
        if supportsReport {
            items.append(NodeAction(title: "Generate Report", action: { onGenerateScanReport() }))
        }
        return items
    }

    private func supportsScanAction(for node: NodeRecord) -> Bool {
        if isServicePseudoNode(node.id) { return false }
        let caps = Set(node.capabilities.map { $0.lowercased() })
        if caps.contains("scan") {
            return true
        }
        if node.presenceState == .scanning {
            return true
        }
        guard let presence = nodePresence[node.id] else {
            return false
        }
        let state = presence.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if state == "scanning" {
            return true
        }
        return presence.capabilities.canScanWifi == true || presence.capabilities.canScanBle == true
    }

    private func supportsProbeAction(for node: NodeRecord) -> Bool {
        if isServicePseudoNode(node.id) { return false }
        return Set(node.capabilities.map { $0.lowercased() }).contains("probe")
    }

    private func supportsReportAction(for node: NodeRecord) -> Bool {
        if isServicePseudoNode(node.id) { return false }
        return Set(node.capabilities.map { $0.lowercased() }).contains("report")
    }

    private func isServicePseudoNode(_ nodeID: String) -> Bool {
        serviceOnlyNodeIDs.contains(nodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private var endpointHost: String {
        guard let components = URLComponents(string: store.endpointURL),
              let host = components.host else {
            return "Unknown"
        }
        return host
    }

    private var endpointIsLocal: Bool {
        let host = endpointHost.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    private func connectSelectedNode() {
        let manualHost = manualConnectHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = connectNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredLabel = manualConnectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        manualConnectError = nil
        if !manualHost.isEmpty {
            isManualConnecting = true
            Task {
                let result = await NodeRegistry.shared.registerFromHost(manualHost, preferredLabel: preferredLabel.isEmpty ? nil : preferredLabel)
                await MainActor.run {
                    isManualConnecting = false
                    if let nodeID = result.nodeID, !nodeID.isEmpty {
                        connectNodeID = nodeID
                        manualConnectHost = ""
                        manualConnectLabel = ""
                        connectRegisteredNode(nodeID)
                    } else {
                        manualConnectError = result.error ?? "Unable to verify device identity."
                    }
                }
            }
            return
        }
        let resolved = !target.isEmpty ? target : (connectCandidates.first?.id ?? "")
        guard !resolved.isEmpty else {
            manualConnectError = "No discovered or claimed node selected."
            return
        }
        if nodes.first(where: { $0.id == resolved }) == nil,
           let discovered = discoveredNodes.first(where: { $0.id == resolved }) {
            if let record = NodeRegistry.shared.claimFromPresence(discovered.presence, preferredLabel: nil) {
                connectNodeID = record.id
                onFlashClaimed(record.id)
            }
        }
        connectRegisteredNode(resolved)
    }

    private func connectRegisteredNode(_ nodeID: String) {
        if isServicePseudoNode(nodeID) {
            manualConnectError = serviceOnlyNodeMessage
            return
        }
        connectNodeID = nodeID
        NodeRegistry.shared.setConnecting(nodeID: nodeID, connecting: true)
        NodeRegistry.shared.clearLastError(nodeID: nodeID)
        sodsStore.connectNode(nodeID)
        sodsStore.identifyNode(nodeID)
        sodsStore.refreshStatus()
        store.connectNode(nodeID)
        if !bleDiscoveryEnabled {
            bleDiscoveryEnabled = true
        }
        if networkScanMode == .continuous && !scanner.isScanning {
            onStartScan()
        }
    }

    private func claimDiscovered(_ item: DiscoveredNodeItem) {
        if let record = NodeRegistry.shared.claimFromPresence(item.presence, preferredLabel: nil) {
            connectNodeID = record.id
            onFlashClaimed(record.id)
            sodsStore.identifyNode(record.id)
            sodsStore.refreshStatus()
        }
    }

    private func addOrUpdateManualNode() {
        let nodeID = addNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeID.isEmpty else {
            manualConnectError = "Node ID is required to persist a node."
            return
        }
        manualConnectError = nil
        let label = addNodeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = addNodeIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = addNodeMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        nodeRegistry.register(
            nodeID: nodeID,
            label: label.isEmpty ? nil : label,
            hostname: nil,
            ip: ip.isEmpty ? nil : ip,
            mac: mac.isEmpty ? nil : mac,
            type: .unknown,
            capabilities: []
        )
        if connectNodeID.isEmpty {
            connectNodeID = nodeID
        }
    }

    private func autoReconnectClaimedNodes() {
        guard !nodeRegistry.nodes.isEmpty else { return }
        for node in nodeRegistry.nodes {
            if isServicePseudoNode(node.id) { continue }
            if node.connectionState == .offline || node.connectionState == .error || nodePresence[node.id] == nil {
                NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                sodsStore.connectNode(node.id)
                sodsStore.identifyNode(node.id)
            }
        }
        sodsStore.refreshStatus()
    }

}

struct NodeAction: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

struct NodeCardView: View {
    let node: NodeRecord
    let presence: NodePresence?
    let eventCount: Int
    let actions: [NodeAction]
    let isScannerNode: Bool
    let isServicePseudoNode: Bool
    let isConnecting: Bool
    let stationBaseURL: String
    let onRefresh: () -> Void
    let onForget: () -> Void
    @AppStorage("TargetLockNodeID") private var targetLockNodeID: String = ""
    @StateObject private var flashedNoteStore = FlashedNoteStore.shared
    @State private var showActions = false
    @State private var showRemoveSheet = false
    @State private var noteKey = ""
    @State private var noteText = ""

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { timeline in
            let status = nodeStatus()
            let activity = min(1.0, Double(eventCount) / 40.0)
            let presentation: NodePresentation = {
                let base = NodePresentation.forNode(node, presence: presence, activityScore: activity)
                if targetLockNodeID == node.id {
                    return NodePresentation(
                        baseColor: NSColor.systemRed,
                        displayColor: NSColor.systemRed,
                        shouldGlow: true,
                        isOffline: base.isOffline,
                        glowColor: NSColor.systemRed,
                        activityScore: activity
                    )
                }
                return base
            }()
            let state = presence?.state.lowercased() ?? ""
            let isRefreshing = isConnecting || state == "connecting" || state == "scanning"
            let refreshDisabled = isRefreshing || isServicePseudoNode
            let refreshLabel: String = {
                if isServicePseudoNode {
                    return "Service-only entry; managed in Stack Status."
                }
                if isConnecting || state == "connecting" {
                    return "Connecting..."
                }
                if state == "scanning" {
                    return "Refreshing..."
                }
                return "Refresh/Reconnect"
            }()
            let secondaryColor = presentation.isOffline ? Theme.muted : Theme.textSecondary
            let pulse = NodePresentation.pulse(now: timeline.date, seed: node.id)
            let glowAlpha = presentation.shouldGlow ? (0.18 + activity * 0.18) : 0
            let glowRadius = presentation.shouldGlow ? (6 + activity * 6) * pulse : 0

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(node.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(presentation.isOffline ? Theme.muted : Theme.textPrimary)
                    Spacer()
                    Button {
                        if targetLockNodeID == node.id {
                            targetLockNodeID = ""
                        } else {
                            targetLockNodeID = node.id
                        }
                    } label: {
                        Image(systemName: targetLockNodeID == node.id ? "scope" : "scope")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(targetLockNodeID == node.id ? .white : Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background((targetLockNodeID == node.id ? Color(NSColor.systemRed) : Theme.border.opacity(0.35)))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Circle()
                        .fill(Color(presentation.displayColor))
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryColor)
                }
                Text("Node ID: \(node.id)")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                Text("Type: \(node.type.rawValue)")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                if let hostLine = hostSummary() {
                    Text(hostLine)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryColor)
                }
                Text("Last seen: \(status.lastSeenText)")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                Text("Events (10m): \(eventCount)")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                if !node.capabilities.isEmpty {
                    Text("Capabilities: \(node.capabilities.joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryColor)
                }
                Text(controlRelationship())
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                if isServicePseudoNode {
                    Text("Service-only entry. Managed by Stack Status.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                if let errorLine = lastErrorLine() {
                    Text(errorLine)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryColor)
                }

                HStack(spacing: 8) {
                    Button { onRefresh() } label: {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(refreshDisabled)
                    .help(refreshLabel)
                    .accessibilityLabel(Text(refreshLabel))

                    Button { showActions.toggle() } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(isServicePseudoNode)
                    .help("Actions")
                    .accessibilityLabel(Text("Actions"))
                    .popover(isPresented: $showActions, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                ModalHeaderView(title: "Node Actions", onBack: nil, onClose: { showActions = false })
                                if actions.isEmpty {
                                    Text("No actions available.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                } else {
                                    let columns = [GridItem(.adaptive(minimum: 40), spacing: 10)]
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                        ForEach(actions) { action in
                                            Button { action.action() } label: {
                                                Image(systemName: nodeActionSystemImage(action.title))
                                                    .font(.system(size: 13, weight: .semibold))
                                            }
                                            .buttonStyle(SecondaryActionButtonStyle())
                                            .help(action.title)
                                            .accessibilityLabel(Text(action.title))
                                        }
                                    }
                                }
                                Divider()
                                HStack(spacing: 10) {
                                    Text("Target Lock")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button {
                                        targetLockNodeID = (targetLockNodeID == node.id) ? "" : node.id
                                        showActions = false
                                    } label: {
                                        Image(systemName: "scope")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .buttonStyle(SecondaryActionButtonStyle())
                                    .help("Target Lock")
                                    .accessibilityLabel(Text("Target Lock"))
                                }
                                HStack(spacing: 10) {
                                    Text("Remove / Forget")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button {
                                        showRemoveSheet = true
                                        showActions = false
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .buttonStyle(SecondaryActionButtonStyle())
                                    .help("Remove / Forget")
                                    .accessibilityLabel(Text("Remove / Forget"))
                                }
                            }
                            .padding(12)
                            .frame(minWidth: 240)
                            .background(Theme.panel)
                        }
                    Button { showRemoveSheet = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Remove / Forget")
                    .accessibilityLabel(Text("Remove / Forget"))
                    Spacer()
                }

                EmptyView()

                DisclosureGroup("Flashed Note") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Key")
                                .font(.system(size: 11))
                                .frame(width: 34, alignment: .leading)
                            TextField("serial or node id", text: $noteKey)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                loadNodeNote()
                            }
                            label: {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Load")
                            .accessibilityLabel(Text("Load"))
                        }
                        TextEditor(text: $noteText)
                            .font(.system(size: 11))
                            .frame(minHeight: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                        HStack(spacing: 8) {
                            Button {
                                flashedNoteStore.setNote(noteText, for: noteKey)
                                loadNodeNote()
                            }
                            label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Save")
                            .accessibilityLabel(Text("Save"))

                            Button {
                                flashedNoteStore.setNote("", for: noteKey)
                                loadNodeNote()
                            }
                            label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Clear")
                            .accessibilityLabel(Text("Clear"))
                            Spacer()
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            }
            .padding(12)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .cornerRadius(12)
            .shadow(color: presentation.shouldGlow ? Color(presentation.baseColor).opacity(glowAlpha) : .clear, radius: glowRadius)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                loadNodeNote()
            }
            .onChange(of: node.id) { _ in
                loadNodeNote()
            }
        }
        .sheet(isPresented: $showRemoveSheet) {
            RemoveNodeSheet(
                node: node,
                stationBaseURL: stationBaseURL,
                hostHint: hostSummaryHostHint(),
                onForgetLocal: {
                    onForget()
                    if targetLockNodeID == node.id {
                        targetLockNodeID = ""
                    }
                },
                onClose: { showRemoveSheet = false }
            )
        }
    }

    private func nodeNoteFallbackKeys() -> [String] {
        var keys: [String] = [node.id]
        if let ip = node.ip, !ip.isEmpty { keys.append(ip) }
        if let mac = node.mac, !mac.isEmpty { keys.append(mac) }
        if let ip = presence?.ip, !ip.isEmpty { keys.append(ip) }
        if let mac = presence?.mac, !mac.isEmpty { keys.append(mac) }
        return Array(Set(keys))
    }

    private func loadNodeNote() {
        let resolved = flashedNoteStore.resolveKey(preferred: nil, fallbacks: nodeNoteFallbackKeys())
        noteKey = resolved
        noteText = flashedNoteStore.note(for: resolved)
    }

    private func nodeStatus() -> (label: String, isOnline: Bool, lastSeenText: String) {
        let lastSeen = presence?.lastSeen ?? Int((node.lastSeen ?? node.lastHeartbeat)?.timeIntervalSince1970 ?? 0) * 1000
        let lastSeenText = lastSeen > 0
        ? Date(timeIntervalSince1970: TimeInterval(lastSeen) / 1000).formatted(date: .abbreviated, time: .shortened)
        : "Not seen yet"
        if isConnecting {
            return ("Connecting", false, lastSeenText)
        }
        if let state = presence?.state.lowercased(), state == "connecting" {
            return ("Connecting", false, lastSeenText)
        }
        let effectiveState = CoreNodeStateResolver.effectiveState(node: node, presence: presence)
        return (
            CoreNodeStateResolver.statusLabel(for: effectiveState),
            CoreNodeStateResolver.isOnline(effectiveState),
            lastSeenText
        )
    }

    private func controlRelationship() -> String {
        switch node.type {
        case .piAux:
            return "Controls: ESP/SDR/GPS nodes"
        case .mac:
            return "Control: Local SODS"
        case .esp32, .sdr, .gps:
            return "Controlled by Pi-Aux"
        case .unknown:
            return "Control: Unknown"
        }
    }

    private func hostSummary() -> String? {
        let host = (presence?.hostname ?? node.hostname)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = (presence?.ip ?? node.ip)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = (presence?.mac ?? node.mac)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPart: String? = {
            if let host, !host.isEmpty { return host }
            if let ip, !ip.isEmpty { return ip }
            return nil
        }()
        var parts: [String] = []
        if let hostPart { parts.append("Host: \(hostPart)") }
        if let mac, !mac.isEmpty { parts.append("MAC: \(mac)") }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func lastErrorLine() -> String? {
        let error = (presence?.lastError ?? node.lastError)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let error, !error.isEmpty else { return nil }
        return "Last error: \(error)"
    }

    private func hostSummaryHostHint() -> String? {
        if let ip = presence?.ip?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { return ip }
        if let ip = node.ip?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { return ip }
        if let host = presence?.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty { return host }
        if let host = node.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty { return host }
        return nil
    }
}
struct CasesView: View {
    @ObservedObject var caseManager: CaseManager
    @ObservedObject var sessionManager: CaseSessionManager
    @ObservedObject var piAuxStore: PiAuxStore
    @ObservedObject var vaultTransport: VaultTransport
    @ObservedObject var entityStore: EntityStore
    let onRefresh: () -> Void
    @State private var selectedCase: CaseIndex?
    @State private var sessionNodesText: String = ""
    @State private var includeBLE = true
    @State private var includeWiFi = false
    @State private var includeRF = false
    @State private var includeGPS = false
    @State private var includeNet = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                caseList
                Divider()
                caseDetail
                    .frame(minWidth: 320)
            }
            VStack(spacing: 12) {
                caseList
                caseDetail
            }
        }
    }

    private var caseList: some View {
        List(selection: $selectedCase) {
            let aliases = IdentityResolver.shared.aliasMap()
            ForEach(caseManager.cases) { item in
                let alias = aliases[item.targetID]
                VStack(alignment: .leading, spacing: 2) {
                    if let alias, !alias.isEmpty {
                        Text("\(alias) (\(item.targetID))")
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text(item.targetID)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("\(item.targetType) • \(item.confidenceLevel) (\(item.confidenceScore))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .tag(item)
            }
        }
        .frame(minWidth: 300)
    }

    private var caseDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cases")
                .font(.system(size: 16, weight: .semibold))
            GroupBox("Case Session") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sessionManager.isActive ? "Session Active" : "Session Idle")
                        .font(.system(size: 12, weight: .semibold))
                    if let started = sessionManager.startedAt {
                        Text("Started: \(started.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    TextField("Nodes (comma-separated IDs)", text: $sessionNodesText)
                        .textFieldStyle(.roundedBorder)
                    if !entityStore.nodes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active Nodes")
                                .font(.system(size: 11, weight: .semibold))
                            let aliasOverrides = IdentityResolver.shared.aliasMap()
                            ForEach(entityStore.nodes) { node in
                                let alias = aliasOverrides[node.id]
                                let presentation = NodePresentation.forNode(node, presence: nil, activityScore: 0)
                                HStack {
                                    Circle()
                                        .fill(Color(presentation.displayColor))
                                        .frame(width: 7, height: 7)
                                    if let alias, !alias.isEmpty {
                                        Text("\(alias) (\(node.label) • \(node.id))")
                                            .font(.system(size: 11))
                                            .foregroundColor(presentation.isOffline ? Theme.muted : Theme.textPrimary)
                                    } else {
                                        Text("\(node.label) (\(node.id))")
                                            .font(.system(size: 11))
                                            .foregroundColor(presentation.isOffline ? Theme.muted : Theme.textPrimary)
                                    }
                                    Spacer()
                                    Button {
                                        appendNodeID(node.id)
                                    }
                                    label: {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .buttonStyle(SecondaryActionButtonStyle())
                                    .help("Add")
                                    .accessibilityLabel(Text("Add"))
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Toggle("BLE", isOn: $includeBLE)
                        Toggle("Wi-Fi", isOn: $includeWiFi)
                        Toggle("RF", isOn: $includeRF)
                        Toggle("GPS", isOn: $includeGPS)
                        Toggle("Net", isOn: $includeNet)
                    }
                    .font(.system(size: 11))
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    HStack {
                        Button {
                            let nodes = sessionNodesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            sessionManager.start(nodes: nodes, sources: selectedSources())
                        }
                        label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(sessionManager.isActive)
                        .help("Start Session")
                        .accessibilityLabel(Text("Start Session"))

                        Button {
                            sessionManager.stop(log: LogStore.shared)
                        }
                        label: {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!sessionManager.isActive)
                        .help("Stop Session")
                        .accessibilityLabel(Text("Stop Session"))
                    }
                }
                .padding(6)
            }
            HStack {
                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Refresh")
                .accessibilityLabel(Text("Refresh"))
                Button {
                    selectedCase = nil
                    sessionNodesText = ""
                }
                label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Clear Selection")
                .accessibilityLabel(Text("Clear Selection"))
                Spacer()
            }
            if let selectedCase {
                let alias = IdentityResolver.shared.resolveLabel(keys: [selectedCase.targetID])
                if let alias, !alias.isEmpty {
                    Text("Target: \(alias) (\(selectedCase.targetID))")
                        .font(.system(size: 12))
                } else {
                    Text("Target: \(selectedCase.targetID)")
                        .font(.system(size: 12))
                }
                Text("Type: \(selectedCase.targetType)")
                    .font(.system(size: 12))
                Text("Confidence: \(selectedCase.confidenceLevel) (\(selectedCase.confidenceScore))")
                    .font(.system(size: 12))
                Text("References: \(selectedCase.references.count)")
                    .font(.system(size: 12))

                HStack {
                    Button {
                        caseManager.openCaseFolder(selectedCase)
                    }
                    label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Open Case Folder")
                    .accessibilityLabel(Text("Open Case Folder"))

                    Button {
                        caseManager.generateCaseReport(selectedCase, log: LogStore.shared)
                    }
                    label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Generate Case Report")
                    .accessibilityLabel(Text("Generate Case Report"))

                    Button {
                        vaultTransport.shipNow(log: LogStore.shared)
                    }
                    label: {
                        Image(systemName: "paperplane")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help("Ship Now")
                    .accessibilityLabel(Text("Ship Now"))
                }
            } else {
                Text("Select a case to view details.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private func selectedSources() -> [String] {
        var sources: [String] = []
        if includeBLE { sources.append("ble") }
        if includeWiFi { sources.append("wifi") }
        if includeRF { sources.append("rf") }
        if includeGPS { sources.append("gps") }
        if includeNet { sources.append("net") }
        return sources
    }

    private func appendNodeID(_ nodeID: String) {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = sessionNodesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if existing.contains(trimmed) { return }
        if sessionNodesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionNodesText = trimmed
        } else {
            sessionNodesText += ", \(trimmed)"
        }
    }
}

struct VaultView: View {
    @ObservedObject var shipper: VaultTransport
    @Binding var inboxStatus: InboxStatus
    @Binding var retentionDays: Int
    @Binding var retentionMaxGB: Int
    let onPrune: () -> Void
    let onRevealShipper: () -> Void
    let onRevealResources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault Shipping")
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 8) {
                Circle()
                    .fill(vaultStatusColor())
                    .frame(width: 8, height: 8)
                Text(vaultStatusText())
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Queue: \(shipper.queuedCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Host")
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $shipper.host)
                    .textFieldStyle(.roundedBorder)
                Text("User")
                    .frame(width: 70, alignment: .leading)
                TextField("pi", text: $shipper.user)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Destination")
                    .frame(width: 90, alignment: .leading)
                TextField("/vault/sods/sods/", text: $shipper.destinationPath)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Method")
                    .frame(width: 90, alignment: .leading)
                Picker("Method", selection: $shipper.method) {
                    ForEach(VaultMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .frame(width: 160)
                Toggle("Auto-ship after export/report", isOn: $shipper.autoShipAfterExport)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    shipper.save()
                    shipper.shipNow(log: LogStore.shared)
                }
                label: {
                    Image(systemName: "paperplane")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Ship Now")
                .accessibilityLabel(Text("Ship Now"))

                Button {
                    onRevealShipper()
                }
                label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Reveal Shipper State")
                .accessibilityLabel(Text("Reveal Shipper State"))
            }

            Text("Status: \(shipper.lastShipResult) • Queued: \(shipper.queuedCount)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if !shipper.lastShipDetail.isEmpty {
                Text(shipper.lastShipDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if !shipper.lastShipTime.isEmpty {
                Text("Last Ship: \(shipper.lastShipTime)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Text("Auto-ship copies local artifacts to the Pi vault using SSH (SCP/rsync). Configure host/user/path for your Pi-Logger.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Divider()

            Text("Inbox Retention")
                .font(.system(size: 14, weight: .semibold))
            HStack {
                Text("Inbox: \(retentionDays) days / \(retentionMaxGB) GB")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button { onPrune() } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Prune Now")
                .accessibilityLabel(Text("Prune Now"))
                Spacer()
                Button { onRevealResources() } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Reveal Resources Folder")
                .accessibilityLabel(Text("Reveal Resources Folder"))
            }
            Text("Inbox size: \(formatBytes(inboxStatus.totalBytes)) • Files: \(inboxStatus.fileCount)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Oldest: \(formatDate(inboxStatus.oldest)) • Newest: \(formatDate(inboxStatus.newest))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(12)
        .onChange(of: shipper.host) { _ in shipper.save() }
        .onChange(of: shipper.user) { _ in shipper.save() }
        .onChange(of: shipper.destinationPath) { _ in shipper.save() }
        .onChange(of: shipper.method) { _ in shipper.save() }
        .onChange(of: shipper.autoShipAfterExport) { _ in shipper.save() }
    }

    private func vaultStatusText() -> String {
        if !shipper.lastShipResult.isEmpty {
            return "Status: \(shipper.lastShipResult) • Last: \(shipper.lastShipTime.isEmpty ? "N/A" : shipper.lastShipTime)"
        }
        return shipper.autoShipAfterExport ? "Auto-ship enabled" : "Auto-ship disabled"
    }

    private func vaultStatusColor() -> Color {
        if shipper.lastShipResult.lowercased().contains("error") || shipper.lastShipResult.lowercased().contains("fail") {
            return Theme.accent
        }
        return shipper.autoShipAfterExport ? Theme.accent : Theme.muted
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        return String(format: "%.2f GB", gb)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct BLERadarView: View {
    let peripherals: [BLEPeripheral]
    let findFingerprintID: String
    let labelProvider: (String) -> String?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: size * 0.9, height: size * 0.9)
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    .frame(width: size * 0.6, height: size * 0.6)
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    .frame(width: size * 0.3, height: size * 0.3)
                Text("You")
                    .font(.system(size: 12, weight: .semibold))
                    .position(center)

                ForEach(peripherals) { peripheral in
                    let distance = distanceFactor(for: peripheral.smoothedRSSI)
                    let angle = angleFor(peripheral.fingerprintID)
                    let radius = (size * 0.45) * distance
                    let x = center.x + CGFloat(cos(angle)) * radius
                    let y = center.y + CGFloat(sin(angle)) * radius
                    let label = labelProvider(peripheral.fingerprintID) ?? peripheral.name ?? "Unknown"
                    let bucket = distanceBucketLabel(for: peripheral.smoothedRSSI)
                    let lastSeen = lastSeenSeconds(peripheral.lastSeen)
                    let trend = trendSymbol(for: peripheral)
                    let isTarget = peripheral.fingerprintID == findFingerprintID
                    let dimOthers = !findFingerprintID.isEmpty && !isTarget
                    VStack(spacing: 2) {
                        Circle()
                            .fill(isTarget ? Theme.accent : Theme.muted)
                            .frame(width: isTarget ? 12 : 8, height: isTarget ? 12 : 8)
                            .overlay(
                                Circle()
                                    .stroke(Color.orange.opacity(isTarget ? 0.9 : 0), lineWidth: 2)
                                    .frame(width: isTarget ? 16 : 0, height: isTarget ? 16 : 0)
                            )
                        Text("\(label) • \(bucket) • \(trend) • \(lastSeen)s")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .opacity(dimOthers ? 0.3 : 1.0)
                    .position(x: x, y: y)
        }
    }

}
        .padding(12)
    }

    private func distanceFactor(for rssi: Double) -> CGFloat {
        if rssi > -45 {
            return 0.2
        } else if rssi > -60 {
            return 0.4
        } else if rssi > -75 {
            return 0.65
        } else {
            return 0.85
        }
    }

    private func angleFor(_ fingerprintID: String) -> Double {
        var hash = 0
        for scalar in fingerprintID.unicodeScalars {
            hash = (hash * 31 + Int(scalar.value)) & 0x7fffffff
        }
        let degrees = Double(hash % 360)
        return degrees * Double.pi / 180
    }

    private func distanceBucketLabel(for rssi: Double) -> String {
        if rssi > -45 { return "Near" }
        if rssi > -60 { return "Medium" }
        if rssi > -75 { return "Far" }
        return "Weak"
    }

    private func lastSeenSeconds(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date)))
    }

    private func trendSymbol(for peripheral: BLEPeripheral) -> String {
        let now = Date()
        let target = now.addingTimeInterval(-2)
        guard let current = peripheral.rssiHistory.last else { return "•" }
        let past = peripheral.rssiHistory.last(where: { $0.timestamp <= target }) ?? peripheral.rssiHistory.first
        guard let past else { return "•" }
        let delta = current.smoothedRSSI - past.smoothedRSSI
        if delta > 3 { return "↑" }
        if delta < -3 { return "↓" }
        return "→"
    }
}
