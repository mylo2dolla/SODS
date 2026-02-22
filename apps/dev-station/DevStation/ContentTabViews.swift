import SwiftUI
import UniformTypeIdentifiers
import Foundation
import CoreBluetooth
import Network
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
    @Binding var bleDiscoveryEnabled: Bool
    @Binding var networkScanMode: ScanMode
    @Binding var connectNodeID: String
    @Binding var showFlashConfirm: Bool
    let onStartScan: () -> Void
    let onStopScan: () -> Void
    let onGenerateScanReport: () -> Void
    let onFindDevice: () -> Void
    let onFlashStarted: (FlashTarget) -> Void
    let onFlashAwaitingHello: () -> Void
    let onFlashClaimed: (String) -> Void
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

    private var flashControlSection: some View {
        GroupBox("Node Actions") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
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
                    VStack(alignment: .leading, spacing: 8) {
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
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
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
                        Text("Host/IP")
                            .font(.system(size: 11))
                        HStack(spacing: 8) {
                            TextField("192.168.1.22", text: $manualConnectHost)
                                .textFieldStyle(.roundedBorder)
                            TextField("Label (optional)", text: $manualConnectLabel)
                                .textFieldStyle(.roundedBorder)
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
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Persist Node (Manual)")
                        .font(.system(size: 11, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Node ID", text: $addNodeID)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Label", text: $addNodeLabel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack(spacing: 8) {
                                TextField("IP", text: $addNodeIP)
                                    .textFieldStyle(.roundedBorder)
                                TextField("MAC", text: $addNodeMAC)
                                    .textFieldStyle(.roundedBorder)
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
                        }
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

                ViewThatFits(in: .horizontal) {
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
                    VStack(alignment: .leading, spacing: 8) {
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
                    }
                }

                ScrollView(.horizontal, showsIndicators: true) {
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
                        Spacer(minLength: 0)
                    }
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
                ScrollView(.vertical, showsIndicators: true) {
                    caseDetail
                }
                    .frame(minWidth: 320)
            }
            VStack(spacing: 12) {
                caseList
                ScrollView(.vertical, showsIndicators: true) {
                    caseDetail
                }
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

            ViewThatFits(in: .horizontal) {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Host")
                        .font(.system(size: 11))
                    TextField("", text: $shipper.host)
                        .textFieldStyle(.roundedBorder)
                    Text("User")
                        .font(.system(size: 11))
                    TextField("pi", text: $shipper.user)
                        .textFieldStyle(.roundedBorder)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Destination")
                        .frame(width: 90, alignment: .leading)
                    TextField("/vault/sods/sods/", text: $shipper.destinationPath)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination")
                        .font(.system(size: 11))
                    TextField("/vault/sods/sods/", text: $shipper.destinationPath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            ViewThatFits(in: .horizontal) {
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Method")
                            .font(.system(size: 11))
                        Picker("Method", selection: $shipper.method) {
                            ForEach(VaultMethod.allCases) { method in
                                Text(method.rawValue).tag(method)
                            }
                        }
                    }
                    Toggle("Auto-ship after export/report", isOn: $shipper.autoShipAfterExport)
                        .toggleStyle(.switch)
                    HStack(spacing: 8) {
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
                        Spacer(minLength: 0)
                    }
                }
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

struct ConsentView: View {
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Authorized Use Only")
                .font(.system(size: 18, weight: .semibold))
            Text("Use only on networks you own or are authorized to assess. This tool performs network scanning and service discovery for inventory and validation purposes.")
                .font(.system(size: 13))
            Button { onAcknowledge() } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .semibold))
            }
            .help("I Understand")
            .accessibilityLabel(Text("I Understand"))
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct HostTable: View {
    let hosts: [HostEntry]
    @Binding var selectedIP: String?
    let aliasForHost: (HostEntry) -> String?
    private let tableMinWidth: CGFloat = 1780

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                HStack {
                    Text("IP")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 160, alignment: .leading)
                    Text("Alias")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 180, alignment: .leading)
                    Text("Status")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 120, alignment: .leading)
                    Text("Provenance")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 200, alignment: .leading)
                    Text("Evidence")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 100, alignment: .leading)
                    Text("Ports")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 200, alignment: .leading)
                    Text("Conf")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    Text("Hostname")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 220, alignment: .leading)
                    Text("MAC")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 150, alignment: .leading)
                    Text("Vendor")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 220, alignment: .leading)
                    Text("Confidence")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.04))

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(hosts) { host in
                            HStack {
                                Text(host.ip)
                                    .frame(width: 160, alignment: .leading)
                                Text(aliasForHost(host) ?? "")
                                    .frame(width: 180, alignment: .leading)
                                Text(host.isAlive ? "Alive" : "No Response")
                                    .foregroundColor(host.isAlive ? .green : .secondary)
                                    .frame(width: 120, alignment: .leading)
                                Text(host.provenance?.label ?? "")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .frame(width: 200, alignment: .leading)
                                Text(host.evidence)
                                    .frame(width: 100, alignment: .leading)
                                Text(host.openPorts.sorted().map(String.init).joined(separator: ", "))
                                    .frame(width: 200, alignment: .leading)
                                Text("\(host.hostConfidence.level.rawValue) (\(host.hostConfidence.score))")
                                    .frame(width: 110, alignment: .leading)
                                Text(host.hostname ?? "")
                                    .frame(width: 220, alignment: .leading)
                                Text(host.macAddress ?? "")
                                    .frame(width: 150, alignment: .leading)
                                Text(host.vendor ?? "")
                                    .frame(width: 220, alignment: .leading)
                                Text("\(host.vendorConfidenceScore)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(selectedIP == host.ip ? Theme.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                            .onTapGesture {
                                selectedIP = host.ip
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(minWidth: tableMinWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

struct DeviceRow: View {
    let device: Device
    let status: String?
    let alias: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(device.ip)
                    .font(.system(size: 14, weight: .semibold))
                if let alias, !alias.isEmpty {
                    Text(alias)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.panelAlt)
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
                if device.isCameraLikely {
                    Text("camera-likely")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(4)
                }
                if device.discoveredViaOnvif {
                    Text("ONVIF")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15))
                        .foregroundColor(Theme.accent)
                        .cornerRadius(4)
                }
                if let status = status {
                    Text(status)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.12))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
                Text("\(device.hostConfidence.level.rawValue) (\(device.hostConfidence.score))")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .foregroundColor(.secondary)
                    .cornerRadius(4)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.ip, forType: .string)
                }
                label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Copy IP")
                .accessibilityLabel(Text("Copy IP"))

                Button {
                    NSPasteboard.general.clearContents()
                    let value = device.bestRtspURI ?? device.suggestedRTSPURL
                    NSPasteboard.general.setString(value, forType: .string)
                }
                label: {
                    Image(systemName: "video")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Copy RTSP URL")
                .accessibilityLabel(Text("Copy RTSP URL"))
            }

            if let title = device.httpTitle {
                Text("Title: \(title)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Open ports: \(device.openPorts.sorted().map(String.init).joined(separator: ", "))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            let portLabels = portLabelsString(device.openPorts)
            if !portLabels.isEmpty {
                Text("Port labels: \(portLabels)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct UnifiedDetailView: View {
    let host: HostEntry?
    let device: Device?
    let selectedIP: String?
    let bestHTTPURL: URL?
    let bestRTSPURI: String?
    let bestONVIFXAddr: String?
    let bestSSDPURL: String?
    let bestPorts: [Int]
    let rtspOverrideEnabled: Binding<Bool>?
    let rtspOverrideValue: Binding<String>?
    let statusText: String?
    let username: Binding<String>?
    let password: Binding<String>?
    let credentialsAutofilled: Bool
    let isFetching: Bool
    let safeMode: Bool
    let showHardProbe: Bool
    let onFetch: (Device) -> Void
    let onProbeRtsp: (Device) -> Void
    let onHardProbe: (Device) -> Void
    let onOpenWeb: (String) -> Void
    let onOpenSSDP: (String) -> Void
    let onExportEvidence: (String) -> Void
    let onCopyIP: (String) -> Void
    let onCopyRTSP: (String) -> Void
    let onOpenVLC: (String, String) -> Void
    let onGenerateDeviceReport: (String) -> Void
    let onTryRtspPaths: (String) -> Void
    let onPinCase: (String) -> Void
    let onRevealEvidence: (String) -> Void
    let onRevealProbeReport: (String) -> Void
    let onRevealArtifacts: (String) -> Void
    let onGenerateScanReport: () -> Void
    let onRevealLatestReport: () -> Void
    let onExportAudit: () -> Void
    let onExportRuntimeLog: () -> Void
    let onRevealExports: () -> Void
    let onShipNow: () -> Void
    let onBack: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if host == nil && device == nil {
                        Text("Select a host to see details.")
                            .foregroundColor(.secondary)
                    } else {
                    if let host {
                        HostDetailView(host: host)
                    }

                        if let device, let username, let password {
                        DeviceDetailView(
                            device: device,
                            hostEvidence: host,
                            statusText: statusText,
                            username: username,
                            password: password,
                            credentialsAutofilled: credentialsAutofilled
                        )
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var headerView: some View {
        let sections = actionSections()
        return VStack(alignment: .leading, spacing: 8) {
            ModalHeaderView(title: "Details", onBack: onBack, onClose: onClose)
            if let alias = resolvedAlias(), !alias.isEmpty {
                Text("Alias: \(alias)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
            ActionMenuView(sections: sections)
            quickActionsBar
            VStack(alignment: .leading, spacing: 4) {
                Text("HTTP URL: \(bestHTTPURL?.absoluteString ?? "Unknown")")
                Text("RTSP URI: \(bestRTSPURI ?? "Unknown")")
                Text("ONVIF XAddr: \(bestONVIFXAddr ?? "Unknown")")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            if credentialsAutofilled || bestRTSPURI != nil || bestHTTPURL != nil || bestONVIFXAddr != nil {
                Text("Autofilled from known data")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let rtspOverrideEnabled, let rtspOverrideValue {
                HStack {
                    Toggle("Override RTSP", isOn: rtspOverrideEnabled)
                        .toggleStyle(.switch)
                    if rtspOverrideEnabled.wrappedValue {
                        TextField("rtsp://...", text: rtspOverrideValue)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func resolvedAlias() -> String? {
        let keys = [
            selectedIP ?? host?.ip ?? device?.ip ?? "",
            host?.macAddress ?? device?.macAddress ?? "",
            host?.hostname ?? ""
        ]
        return IdentityResolver.shared.resolveLabel(keys: keys)
    }

    @ViewBuilder
    private var quickActionsBar: some View {
        let ip = selectedIP ?? host?.ip ?? device?.ip
        let rtsp = bestRTSPURI
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                if let ip, bestHTTPURL != nil {
                    Button { onOpenWeb(ip) } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Open Web UI")
                    .accessibilityLabel(Text("Open Web UI"))
                }
                if let ip, let rtsp {
                    Button { onOpenVLC(rtsp, ip) } label: {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Open in VLC")
                    .accessibilityLabel(Text("Open in VLC"))
                }
                if let device, !safeMode && !device.rtspProbeInProgress {
                    Button { onProbeRtsp(device) } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help("Probe RTSP")
                    .accessibilityLabel(Text("Probe RTSP"))
                }
                if let device, !safeMode && !isFetching {
                    Button { onFetch(device) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Retry RTSP Fetch")
                    .accessibilityLabel(Text("Retry RTSP Fetch"))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func actionSections() -> [ActionMenuSection] {
        let ip = selectedIP ?? host?.ip ?? device?.ip
        let rtsp = bestRTSPURI
        let canTryRtsp = (rtsp == nil) && (bestPorts.contains(554))
        let hostActions = ActionMenuSection(
            title: "Host Actions",
            items: [
                ActionMenuItem(
                    title: "Copy IP",
                    systemImage: "doc.on.doc",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onCopyIP(ip) } }
                ),
                ActionMenuItem(
                    title: "Copy RTSP URL",
                    systemImage: "doc.on.doc",
                    enabled: rtsp != nil,
                    reason: rtsp == nil ? "No RTSP URI known" : nil,
                    action: { if let rtsp { onCopyRTSP(rtsp) } }
                ),
                ActionMenuItem(
                    title: "Open Web UI",
                    systemImage: "globe",
                    enabled: bestHTTPURL != nil,
                    reason: bestHTTPURL == nil ? "No HTTP URL known" : nil,
                    action: { if let ip { onOpenWeb(ip) } }
                ),
                ActionMenuItem(
                    title: "Open SSDP Location",
                    systemImage: "link",
                    enabled: bestSSDPURL != nil,
                    reason: bestSSDPURL == nil ? "No SSDP location known" : nil,
                    action: { if let ip { onOpenSSDP(ip) } }
                ),
                ActionMenuItem(
                    title: "Open in VLC",
                    systemImage: "play.rectangle",
                    enabled: rtsp != nil,
                    reason: rtsp == nil ? "No RTSP URI known" : nil,
                    action: { if let rtsp, let ip { onOpenVLC(rtsp, ip) } }
                ),
                ActionMenuItem(
                    title: "Probe RTSP",
                    systemImage: "dot.radiowaves.left.and.right",
                    enabled: device != nil && !safeMode && !(device?.rtspProbeInProgress ?? false),
                    reason: safeMode ? "Safe Mode blocks active probes" : (device == nil ? "No device selected" : (device?.rtspProbeInProgress == true ? "RTSP probe already running" : nil)),
                    action: { if let device { onProbeRtsp(device) } }
                ),
                ActionMenuItem(
                    title: "Hard Probe (VLC + Diagnostics)",
                    systemImage: "hammer",
                    enabled: showHardProbe && !safeMode && (device?.onvifRtspURI != nil),
                    reason: showHardProbe ? (safeMode ? "Safe Mode blocks active probes" : (device?.onvifRtspURI == nil ? "No ONVIF RTSP URI" : nil)) : "Only available in Cameras/Interesting",
                    action: { if let device { onHardProbe(device) } }
                ),
                ActionMenuItem(
                    title: "Reveal Probe Folder",
                    systemImage: "folder",
                    enabled: device != nil,
                    reason: device == nil ? "No device selected" : nil,
                    action: { if let device { RTSPHardProbe.revealFolder(for: device, log: LogStore.shared) } }
                ),
                ActionMenuItem(
                    title: "View Latest Probe Report",
                    systemImage: "doc.text.magnifyingglass",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onRevealProbeReport(ip) } }
                ),
                ActionMenuItem(
                    title: "Retry RTSP Fetch",
                    systemImage: "arrow.clockwise",
                    enabled: device != nil && !safeMode && !isFetching,
                    reason: safeMode ? "Safe Mode blocks active probes" : (device == nil ? "No device selected" : (isFetching ? "RTSP fetch already running" : nil)),
                    action: { if let device { onFetch(device) } }
                ),
                ActionMenuItem(
                    title: "Export Evidence (Raw + Readable)",
                    systemImage: "tray.and.arrow.down",
                    enabled: host != nil,
                    reason: host == nil ? "No host evidence available" : nil,
                    action: { if let ip { onExportEvidence(ip) } }
                ),
                ActionMenuItem(
                    title: "Export Device Report",
                    systemImage: "doc.text",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onGenerateDeviceReport(ip) } }
                ),
                ActionMenuItem(
                    title: "Pin to Case",
                    systemImage: "pin",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onPinCase(ip) } }
                ),
                ActionMenuItem(
                    title: "View Latest Evidence",
                    systemImage: "doc.text.magnifyingglass",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onRevealEvidence(ip) } }
                ),
                ActionMenuItem(
                    title: "Reveal Device Artifacts",
                    systemImage: "folder",
                    enabled: ip != nil,
                    reason: ip == nil ? "No host selected" : nil,
                    action: { if let ip { onRevealArtifacts(ip) } }
                ),
                ActionMenuItem(
                    title: "Try RTSP Paths",
                    systemImage: "wand.and.rays",
                    enabled: canTryRtsp && !safeMode,
                    reason: safeMode ? "Safe Mode blocks active probes" : (canTryRtsp ? nil : "RTSP port not observed"),
                    action: { if let ip { onTryRtspPaths(ip) } }
                )
            ]
        )
        let appActions = ActionMenuSection(
            title: "App/Global Actions",
            items: [
                ActionMenuItem(title: "Generate Scan Report", systemImage: "doc.badge.plus", enabled: true, reason: nil, action: onGenerateScanReport),
                ActionMenuItem(title: "Reveal Latest Report", systemImage: "folder", enabled: true, reason: nil, action: onRevealLatestReport),
                ActionMenuItem(title: "Export Audit", systemImage: "tray.and.arrow.down", enabled: true, reason: nil, action: onExportAudit),
                ActionMenuItem(title: "Export Runtime Log", systemImage: "doc.plaintext", enabled: true, reason: nil, action: onExportRuntimeLog),
                ActionMenuItem(title: "Reveal Exports", systemImage: "folder.fill", enabled: true, reason: nil, action: onRevealExports),
                ActionMenuItem(title: "Ship Now", systemImage: "paperplane", enabled: true, reason: nil, action: onShipNow)
            ]
        )
        let bleActions = ActionMenuSection(
            title: "BLE Actions",
            items: [
                ActionMenuItem(title: "Start/Stop Find", systemImage: "scope", enabled: false, reason: "No BLE device selected", action: {}),
                ActionMenuItem(title: "Export BLE Fingerprint (Raw + Readable)", systemImage: "tray.and.arrow.down", enabled: false, reason: "No BLE device selected", action: {}),
                ActionMenuItem(title: "Export BLE Device Report", systemImage: "doc.text", enabled: false, reason: "No BLE device selected", action: {})
            ]
        )
        return [hostActions, appActions, bleActions]
    }

}

struct DeviceDetailView: View {
    let device: Device
    let hostEvidence: HostEntry?
    let statusText: String?
    @Binding var username: String
    @Binding var password: String
    let credentialsAutofilled: Bool
    @State private var showCredentials = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Details")
                .font(.system(size: 16, weight: .semibold))

            Text("IP: \(device.ip)")
                .font(.system(size: 13))
            if let alias = resolvedAlias(), !alias.isEmpty {
                Text("Alias: \(alias)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }

            if let title = device.httpTitle {
                Text("HTTP Title: \(title)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Open ports: \(device.openPorts.sorted().map(String.init).joined(separator: ", "))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if device.discoveredViaOnvif {
                Text("Discovered via ONVIF WS-Discovery")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if !device.onvifXAddrs.isEmpty {
                Text("XAddrs: \(device.onvifXAddrs.joined(separator: " "))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let types = device.onvifTypes {
                Text("Types: \(types)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let scopes = device.onvifScopes {
                Text("Scopes: \(scopes)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let statusText = statusText {
                Text("Status: \(statusText)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if let mac = device.macAddress {
                Text("MAC: \(mac)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            if let vendor = device.vendor {
                Text("Vendor: \(vendor)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Text("Vendor Confidence: \(device.vendorConfidenceScore)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !device.vendorConfidenceReasons.isEmpty {
                ForEach(device.vendorConfidenceReasons, id: \.self) { reason in
                    Text("- \(reason)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Text("Confidence: \(device.hostConfidence.level.rawValue) (\(device.hostConfidence.score))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !device.hostConfidence.reasons.isEmpty {
                ForEach(device.hostConfidence.reasons, id: \.self) { reason in
                    Text("- \(reason)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if let error = device.onvifLastError {
                Text("ONVIF error: \(error)")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            Divider()

            Text("Discovery Evidence")
                .font(.system(size: 12, weight: .semibold))

            if let host = hostEvidence {
                if let server = host.ssdpServer {
                    Text("SSDP Server: \(server)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let location = host.ssdpLocation {
                    Text("SSDP Location: \(location)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let st = host.ssdpST {
                    Text("SSDP ST: \(st)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let usn = host.ssdpUSN {
                    Text("SSDP USN: \(usn)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if !host.bonjourServices.isEmpty {
                    Text("Bonjour Services:")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(host.bonjourServices, id: \.self) { service in
                        let txt = service.txt.joined(separator: " ")
                        Text("\(service.name) \(service.type) :\(service.port) \(txt)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if host.httpStatus != nil || host.httpServer != nil || host.httpAuth != nil || host.httpTitle != nil {
                    Text("HTTP Fingerprint:")
                        .font(.system(size: 11, weight: .semibold))
                    if let status = host.httpStatus {
                        Text("Status: \(status)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let server = host.httpServer {
                        Text("Server: \(server)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let auth = host.httpAuth {
                        Text("Auth: \(auth)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let title = host.httpTitle {
                        Text("Title: \(title)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

            } else {
                Text("No discovery evidence available for this host.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            DisclosureGroup("ONVIF Credentials", isExpanded: $showCredentials) {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                if credentialsAutofilled {
                    Text("Autofilled from saved credentials")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12, weight: .semibold))

            Divider()

            Text("RTSP Probe")
                .font(.system(size: 12, weight: .semibold))

            if let summary = device.lastRtspProbeSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            let working = device.rtspProbeResults.filter { $0.success }
            if !working.isEmpty {
                ForEach(working) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.uri)
                            .font(.system(size: 11))
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result.uri, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .help("Copy RTSP URL")
                                .accessibilityLabel(Text("Copy RTSP URL"))
                            }
                        if let server = result.server, !server.isEmpty {
                            Text("Server: \(server)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        if !result.codecHints.isEmpty {
                            Text("Codecs: \(result.codecHints.joined(separator: ", "))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let rtsp = device.onvifRtspURI {
                Text("RTSP URI: \(rtsp)")
                    .font(.system(size: 12))
            }
        }
    }

    private func resolvedAlias() -> String? {
        let keys = [device.ip, device.macAddress ?? ""]
        return IdentityResolver.shared.resolveLabel(keys: keys)
    }
}

struct HostDetailView: View {
    let host: HostEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Host Details")
                .font(.system(size: 16, weight: .semibold))

            if let host = host {
                Text("IP: \(host.ip)")
                    .font(.system(size: 13))
                if let alias = resolvedAlias(for: host), !alias.isEmpty {
                    Text("Alias: \(alias)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                Text("Status: \(host.isAlive ? "Alive" : "No Response")")
                    .font(.system(size: 12))
                    .foregroundColor(host.isAlive ? .green : .secondary)
                Text("Open ports: \(host.openPorts.sorted().map(String.init).joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                let portLabels = portLabelsString(host.openPorts)
                if !portLabels.isEmpty {
                    Text("Port labels: \(portLabels)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if let hostname = host.hostname {
                    Text("Hostname: \(hostname)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                if let mac = host.macAddress {
                    Text("MAC: \(mac)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                if let vendor = host.vendor {
                    Text("Vendor: \(vendor)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("Confidence: \(host.hostConfidence.level.rawValue) (\(host.hostConfidence.score))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !host.hostConfidence.reasons.isEmpty {
                    ForEach(host.hostConfidence.reasons, id: \.self) { reason in
                        Text("- \(reason)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Text("Vendor Confidence: \(host.vendorConfidenceScore)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !host.vendorConfidenceReasons.isEmpty {
                    ForEach(host.vendorConfidenceReasons, id: \.self) { reason in
                        Text("- \(reason)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                Text("Discovery Evidence")
                    .font(.system(size: 12, weight: .semibold))

                if let server = host.ssdpServer {
                    Text("SSDP Server: \(server)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let location = host.ssdpLocation {
                    Text("SSDP Location: \(location)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let st = host.ssdpST {
                    Text("SSDP ST: \(st)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let usn = host.ssdpUSN {
                    Text("SSDP USN: \(usn)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if !host.bonjourServices.isEmpty {
                    Text("Bonjour Services:")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(host.bonjourServices, id: \.self) { service in
                        let txt = service.txt.joined(separator: " ")
                        Text("\(service.name) \(service.type) :\(service.port) \(txt)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if host.httpStatus != nil || host.httpServer != nil || host.httpAuth != nil || host.httpTitle != nil {
                    Text("HTTP Fingerprint:")
                        .font(.system(size: 11, weight: .semibold))
                    if let status = host.httpStatus {
                        Text("Status: \(status)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let server = host.httpServer {
                        Text("Server: \(server)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let auth = host.httpAuth {
                        Text("Auth: \(auth)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let title = host.httpTitle {
                        Text("Title: \(title)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

            } else {
                Text("Select a host to see details.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private func resolvedAlias(for host: HostEntry) -> String? {
        let keys = [host.ip, host.macAddress ?? "", host.hostname ?? ""]
        return IdentityResolver.shared.resolveLabel(keys: keys)
    }

}

struct BLEListView: View {
    let scanner: BLEScanner
    let peripherals: [BLEPeripheral]
    let aliasForPeripheral: (BLEPeripheral) -> String?
    @Binding var selectedID: UUID?
    @Binding var findFingerprintID: String
    let warningText: String?
    let onSelectRow: () -> Void
    @AppStorage("SODSBLERecentWindowSeconds") private var recentWindowSeconds = 30
    @State private var lockFindTarget = true

    var body: some View {
        let rows = buildRows(from: peripherals)
        let diagnostics = diagnostics(for: rows)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Authorization: \(scanner.authorizationDescription)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("State: \(scanner.stateDescription)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Scanning: \(scanner.isScanning ? "true" : "false")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Discovered: \(scanner.peripherals.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Entity rows: \(peripherals.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Rendered: \(rows.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("UUIDs: \(diagnostics.distinctUUIDCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Fingerprints: \(diagnostics.distinctFingerprintCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Last: \(scanner.lastPermissionMessage)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button {
                    Task { @MainActor in
                        await BLEScanner.shared.touchForPermissionIfNeeded()
                    }
                }
                label: {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Touch Permission")
                .accessibilityLabel(Text("Touch Permission"))

                Button {
                    BLEMetadataStore.shared.importCompanyMap(log: LogStore.shared)
                }
                label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Import BLE Company IDs")
                .accessibilityLabel(Text("Import BLE Company IDs"))

                Button {
                    BLEMetadataStore.shared.importAssignedNumbersMap(log: LogStore.shared)
                }
                label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Import BLE Assigned Numbers")
                .accessibilityLabel(Text("Import BLE Assigned Numbers"))

                Button {
                    StoragePaths.revealResourcesFolder()
                }
                label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Reveal Resources Folder")
                .accessibilityLabel(Text("Reveal Resources Folder"))

                Button {
                    scanner.clearDiscovered()
                    selectedID = nil
                    if lockFindTarget {
                        findFingerprintID = ""
                    }
                }
                label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Clear BLE List")
                .accessibilityLabel(Text("Clear BLE List"))

                Spacer()
                if !findFingerprintID.isEmpty {
                    Text("Find: \(findFingerprintID)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if diagnostics.hasCollisions {
                HStack {
                    Text("BLE row diagnostic: duplicate identifiers detected (uuid dups: \(diagnostics.uuidCollisionCount), fingerprint dups: \(diagnostics.fingerprintCollisionCount)). Showing all UUID rows.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            if scanner.authorizationStatus == .denied || scanner.authorizationStatus == .restricted {
                HStack {
                    Text("Bluetooth permission is blocked. Enable it in System Settings to scan.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                    Button {
                        openBluetoothPrivacySettings()
                    }
                    label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .help("Open Bluetooth Privacy Settings")
                    .accessibilityLabel(Text("Open Bluetooth Privacy Settings"))
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            if let warningText {
                HStack {
                    Text(warningText)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Picker("Recent Metric", selection: $recentWindowSeconds) {
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                        Text("5m").tag(300)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Toggle("Lock Find Target", isOn: $lockFindTarget)
                        .toggleStyle(.switch)
                    Text("Seen in \(recentWindowLabel()): \(recentCount(in: rows))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Recent Metric", selection: $recentWindowSeconds) {
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                        Text("5m").tag(300)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    Toggle("Lock Find Target", isOn: $lockFindTarget)
                        .toggleStyle(.switch)
                    Text("Seen in \(recentWindowLabel()): \(recentCount(in: rows))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Label/Name")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 200, alignment: .leading)
                        Text("UUID")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 130, alignment: .leading)
                        Text("Fingerprint")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 130, alignment: .leading)
                        Text("RSSI")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 70, alignment: .leading)
                        Text("Conf")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 105, alignment: .leading)
                        Text("Last Seen")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 85, alignment: .leading)
                        Text("Company")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 220, alignment: .leading)
                        Text("Connectable")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 100, alignment: .leading)
                        Text("Provenance")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 220, alignment: .leading)
                        Text("Flags")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.04))

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(rows, id: \.rowID) { row in
                                HStack {
                                    Text(row.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: 200, alignment: .leading)
                                    Text(row.uuidShort)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: 130, alignment: .leading)
                                    Text(row.fingerprintShort)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: 130, alignment: .leading)
                                    Text("\(row.rssi)")
                                        .frame(width: 70, alignment: .leading)
                                        .foregroundColor(row.rssi > -60 ? .green : .secondary)
                                    Text(row.confidenceLabel)
                                        .frame(width: 105, alignment: .leading)
                                    Text(row.lastSeenAge)
                                        .frame(width: 85, alignment: .leading)
                                        .foregroundColor(.secondary)
                                    Text(row.companyLabel)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: 220, alignment: .leading)
                                    Text(row.connectableLabel)
                                        .frame(width: 100, alignment: .leading)
                                    Text(row.provenanceLabel)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: 220, alignment: .leading)
                                    HStack(spacing: 8) {
                                        if row.duplicateFingerprintCount > 1 {
                                            Text("dup x\(row.duplicateFingerprintCount)")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.orange)
                                        }
                                        if findFingerprintID == row.fingerprintID {
                                            Text("Find")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.green)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12))
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                                .background(selectedID == row.peripheral.id ? Theme.accent.opacity(0.12) : Color.clear)
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedID = row.peripheral.id
                                    if lockFindTarget {
                                        findFingerprintID = row.fingerprintID
                                    }
                                    onSelectRow()
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .frame(minWidth: 1460, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func recentCutoffSeconds() -> Int {
        switch recentWindowSeconds {
        case 10, 30, 60, 300:
            return recentWindowSeconds
        default:
            return 30
        }
    }

    private func recentWindowLabel() -> String {
        switch recentCutoffSeconds() {
        case 10:
            return "10 seconds"
        case 30:
            return "30 seconds"
        case 60:
            return "60 seconds"
        case 300:
            return "5 minutes"
        default:
            return "\(recentCutoffSeconds()) seconds"
        }
    }

    private func lastSeenAgeLabel(_ lastSeen: Date) -> String {
        let age = max(0, Int(Date().timeIntervalSince(lastSeen)))
        if age < 60 {
            return "\(age)s"
        }
        let minutes = age / 60
        let seconds = age % 60
        return "\(minutes)m \(seconds)s"
    }

    private func buildRows(from peripherals: [BLEPeripheral]) -> [BLETableRow] {
        let sorted = peripherals.sorted {
            if $0.lastSeen != $1.lastSeen {
                return $0.lastSeen > $1.lastSeen
            }
            if $0.rssi != $1.rssi {
                return $0.rssi > $1.rssi
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let fingerprintCounts = Dictionary(grouping: sorted, by: { normalizedFingerprint($0.fingerprintID) }).mapValues(\.count)
        return sorted.map { peripheral in
            let fingerprintID = normalizedFingerprint(peripheral.fingerprintID)
            let uuid = peripheral.id.uuidString
            let rowID = "\(uuid)|\(fingerprintID)"
            return BLETableRow(
                rowID: rowID,
                peripheral: peripheral,
                uuid: uuid,
                fingerprintID: fingerprintID,
                displayName: displayName(for: peripheral),
                companyLabel: normalizedCompany(companyLabel(peripheral.fingerprint)),
                rssi: peripheral.rssi,
                confidenceLabel: "\(peripheral.bleConfidence.level.rawValue) (\(peripheral.bleConfidence.score))",
                lastSeenAge: lastSeenAgeLabel(peripheral.lastSeen),
                provenanceLabel: normalizedProvenance(peripheral.provenance?.label),
                connectableLabel: normalizedConnectable(peripheral.fingerprint.isConnectable),
                uuidShort: shortToken(uuid),
                fingerprintShort: shortToken(fingerprintID),
                duplicateFingerprintCount: fingerprintCounts[fingerprintID] ?? 1
            )
        }
    }

    private func recentCount(in rows: [BLETableRow]) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(recentCutoffSeconds()))
        return rows.filter { $0.peripheral.lastSeen >= cutoff }.count
    }

    private func diagnostics(for rows: [BLETableRow]) -> BLEListDiagnostics {
        let uuidCounts = Dictionary(grouping: rows, by: \.uuid).mapValues(\.count)
        let fingerprintCounts = Dictionary(grouping: rows, by: \.fingerprintID).mapValues(\.count)
        let uuidCollisionCount = uuidCounts.values.filter { $0 > 1 }.count
        let fingerprintCollisionCount = fingerprintCounts.values.filter { $0 > 1 }.count
        return BLEListDiagnostics(
            distinctUUIDCount: uuidCounts.count,
            distinctFingerprintCount: fingerprintCounts.count,
            uuidCollisionCount: uuidCollisionCount,
            fingerprintCollisionCount: fingerprintCollisionCount
        )
    }

    private func displayName(for peripheral: BLEPeripheral) -> String {
        let alias = normalizedAlias(aliasForPeripheral(peripheral))
        let base = normalizedName(scanner.label(for: peripheral.fingerprintID) ?? peripheral.name)
        if alias == "—" {
            return base
        }
        return "\(base) [\(alias)]"
    }

    private func normalizedName(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unknown"
        }
        return trimmed
    }

    private func normalizedAlias(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func normalizedCompany(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func normalizedProvenance(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ble.scan" : trimmed
    }

    private func normalizedConnectable(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Yes" : "No"
    }

    private func normalizedFingerprint(_ fingerprintID: String) -> String {
        let trimmed = fingerprintID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown-fingerprint" : trimmed
    }

    private func shortToken(_ value: String, leading: Int = 8, trailing: Int = 6) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > leading + trailing + 1 else { return trimmed }
        let prefix = trimmed.prefix(leading)
        let suffix = trimmed.suffix(trailing)
        return "\(prefix)…\(suffix)"
    }

    private func companyLabel(_ fingerprint: BLEAdFingerprint) -> String {
        guard let id = fingerprint.manufacturerCompanyID else { return "" }
        let name = fingerprint.manufacturerCompanyName ?? "Unknown"
        return "\(name) (0x\(String(format: "%04X", id)))"
    }

}

private struct BLETableRow: Hashable {
    let rowID: String
    let peripheral: BLEPeripheral
    let uuid: String
    let fingerprintID: String
    let displayName: String
    let companyLabel: String
    let rssi: Int
    let confidenceLabel: String
    let lastSeenAge: String
    let provenanceLabel: String
    let connectableLabel: String
    let uuidShort: String
    let fingerprintShort: String
    let duplicateFingerprintCount: Int
}

private struct BLEListDiagnostics: Hashable {
    let distinctUUIDCount: Int
    let distinctFingerprintCount: Int
    let uuidCollisionCount: Int
    let fingerprintCollisionCount: Int

    var hasCollisions: Bool {
        uuidCollisionCount > 0 || fingerprintCollisionCount > 0
    }
}

struct BLEDetailView: View {
    let peripheral: BLEPeripheral?
    let prober: BLEProber
    @Binding var findFingerprintID: String
    let aliasForPeripheral: (BLEPeripheral) -> String?
    let onGenerateScanReport: () -> Void
    let onRevealLatestReport: () -> Void
    let onExportAudit: () -> Void
    let onExportRuntimeLog: () -> Void
    let onRevealExports: () -> Void
    let onShipNow: () -> Void
    let onBack: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var flashedNoteStore = FlashedNoteStore.shared
    @State private var labelText: String = ""
    @State private var flashedNoteKey: String = ""
    @State private var flashedNoteText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let peripheral = peripheral {
                        let isFinding = findFingerprintID == peripheral.fingerprintID
                        let status = prober.statuses[peripheral.fingerprintID]
                        let result = prober.results[peripheral.fingerprintID]
                        HStack {
                            Text("Label:")
                                .font(.system(size: 12))
                            TextField("Label", text: $labelText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                        }
                        .onAppear {
                            labelText = BLEScanner.shared.label(for: peripheral.fingerprintID) ?? ""
                            loadFlashedNoteForCurrentSelection()
                        }
                        .onChange(of: peripheral.fingerprintID) { _ in
                            labelText = BLEScanner.shared.label(for: peripheral.fingerprintID) ?? ""
                            loadFlashedNoteForCurrentSelection()
                        }
                        .onChange(of: prober.results[peripheral.fingerprintID]?.serialNumber ?? "") { _ in
                            loadFlashedNoteForCurrentSelection()
                        }
                        .onChange(of: labelText) { value in
                            BLEScanner.shared.setLabel(value, for: peripheral.fingerprintID)
                            SODSStore.shared.setAlias(id: peripheral.fingerprintID, alias: value)
                        }

                        if let alias = aliasForPeripheral(peripheral), !alias.isEmpty {
                            Text("Alias: \(alias)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        Text("Name: \(peripheral.name ?? "Unknown")")
                            .font(.system(size: 12))
                        Text("Identifier: \(peripheral.id.uuidString)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Fingerprint ID: \(peripheral.fingerprintID)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Last seen: \(Int(Date().timeIntervalSince(peripheral.lastSeen)))s ago")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("RSSI: \(peripheral.rssi)")
                            .font(.system(size: 12))
                            .foregroundColor(peripheral.rssi > -60 ? .green : .secondary)

                        if isFinding {
                            Text("Find active")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            BLEFindPanel(peripheral: peripheral)
                        }

                        Divider()

                        Text("Probe (Connect + Read Basics)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Connect only to devices you own or are authorized to assess.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        if let status {
                            Text("Probe Status: \(status.status)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if let error = status.lastError, !error.isEmpty {
                                Text("Probe Error: \(error)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let result {
                            Text("Services: \(result.discoveredServices.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            if let manufacturer = result.manufacturerName {
                                Text("Manufacturer: \(manufacturer)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let model = result.modelNumber {
                                Text("Model: \(model)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let serial = result.serialNumber {
                                Text("Serial: \(serial)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let firmware = result.firmwareRevision {
                                Text("Firmware: \(firmware)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let hardware = result.hardwareRevision {
                                Text("Hardware: \(hardware)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let systemID = result.systemID {
                                Text("System ID: \(systemID)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let battery = result.batteryLevel {
                                Text("Battery: \(battery)%")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let deviceName = result.deviceName {
                                Text("Device Name: \(deviceName)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()
                        Text("Flashed Notes (Persistent)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Use serial from probe/serial monitor, then save notes for this device.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Text("Key")
                                .font(.system(size: 11))
                                .frame(width: 42, alignment: .leading)
                            TextField("serial or device id", text: $flashedNoteKey)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                loadFlashedNoteForCurrentSelection()
                            }
                            label: {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Load")
                            .accessibilityLabel(Text("Load"))
                        }
                        TextEditor(text: $flashedNoteText)
                            .font(.system(size: 11))
                            .frame(minHeight: 72)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                        HStack(spacing: 8) {
                            Button {
                                flashedNoteStore.setNote(flashedNoteText, for: flashedNoteKey)
                                loadFlashedNoteForCurrentSelection()
                            }
                            label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .help("Save Note")
                            .accessibilityLabel(Text("Save Note"))

                            Button {
                                flashedNoteStore.setNote("", for: flashedNoteKey)
                                loadFlashedNoteForCurrentSelection()
                            }
                            label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Clear Note")
                            .accessibilityLabel(Text("Clear Note"))
                            Spacer()
                        }

                        Text("Confidence: \(peripheral.bleConfidence.level.rawValue) (\(peripheral.bleConfidence.score))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if !peripheral.bleConfidence.reasons.isEmpty {
                            ForEach(peripheral.bleConfidence.reasons, id: \.self) { reason in
                                Text("- \(reason)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        let fingerprint = peripheral.fingerprint
                        if let companyID = fingerprint.manufacturerCompanyID {
                            let name = fingerprint.manufacturerCompanyName ?? "Unknown"
                            let assignment = fingerprint.manufacturerAssignmentDate ?? "Unknown"
                            Text("Company: \(name) (0x\(String(format: "%04X", companyID)))")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("Company Assignment: \(assignment)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        if let beacon = fingerprint.beaconHint {
                            Text("Beacon Hint: \(beacon)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        if let connectable = fingerprint.isConnectable {
                            Text("Connectable: \(connectable ? "Yes" : "No")")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        if let txPower = fingerprint.txPower {
                            Text("TX Power: \(txPower)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        if let prefix = fingerprint.manufacturerDataPrefixHex {
                            Text("Manufacturer Prefix: \(prefix)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        if !peripheral.serviceUUIDs.isEmpty {
                            Text("Service UUIDs:")
                                .font(.system(size: 11, weight: .semibold))
                            ForEach(peripheral.serviceUUIDs, id: \.self) { uuid in
                                let info = BLEMetadataStore.shared.assignedUUIDInfo(for: CBUUID(string: uuid))
                                let decodedName = info?.name ?? "Unknown"
                                let decodedType = info?.type ?? "unknown"
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Raw: \(uuid)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("Normalized: \(BLEUUIDDisplay.normalized(uuid))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("Decoded: \(decodedName) (\(decodedType))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.bottom, 4)
                            }
                        }

                        if let mfg = peripheral.manufacturerDataHex, !mfg.isEmpty {
                            Text("Manufacturer Data:")
                                .font(.system(size: 11, weight: .semibold))
                            Text(mfg)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Select a BLE device to see details.")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var headerView: some View {
        let sections = actionSections()
        return VStack(alignment: .leading, spacing: 8) {
            ModalHeaderView(title: "BLE Details", onBack: onBack, onClose: onClose)
            ActionMenuView(sections: sections)
            bleQuickActions
            Text("Authorization: \(BLEScanner.shared.authorizationDescription) • State: \(BLEScanner.shared.stateDescription) • Scanning: \(BLEScanner.shared.isScanning ? "true" : "false")")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var bleQuickActions: some View {
        if let peripheral {
            let canProbe = (peripheral.fingerprint.isConnectable == true) && prober.canProbe(fingerprintID: peripheral.fingerprintID)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button {
                        prober.startProbe(peripheralInfo: peripheral)
                    }
                    label: {
                        Image(systemName: "link.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(!canProbe)
                    .help("Probe / Connect")
                    .accessibilityLabel(Text("Probe / Connect"))

                    Button {
                        CaseManager.shared.pinBLE(fingerprintID: peripheral.fingerprintID, bleScanner: BLEScanner.shared, log: LogStore.shared)
                    }
                    label: {
                        Image(systemName: "pin")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Pin to Case")
                    .accessibilityLabel(Text("Pin to Case"))
                    Spacer(minLength: 0)
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        Button {
                            prober.startProbe(peripheralInfo: peripheral)
                        }
                        label: {
                            Image(systemName: "link.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!canProbe)
                        .help("Probe / Connect")
                        .accessibilityLabel(Text("Probe / Connect"))

                        Button {
                            CaseManager.shared.pinBLE(fingerprintID: peripheral.fingerprintID, bleScanner: BLEScanner.shared, log: LogStore.shared)
                        }
                        label: {
                            Image(systemName: "pin")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Pin to Case")
                        .accessibilityLabel(Text("Pin to Case"))
                    }
                }
            }
        }
    }

    private func actionSections() -> [ActionMenuSection] {
        let appActions = ActionMenuSection(
            title: "App/Global Actions",
            items: [
                ActionMenuItem(title: "Generate Scan Report", systemImage: "doc.badge.plus", enabled: true, reason: nil, action: onGenerateScanReport),
                ActionMenuItem(title: "Reveal Latest Report", systemImage: "folder", enabled: true, reason: nil, action: onRevealLatestReport),
                ActionMenuItem(title: "Export Audit", systemImage: "tray.and.arrow.down", enabled: true, reason: nil, action: onExportAudit),
                ActionMenuItem(title: "Export Runtime Log", systemImage: "doc.plaintext", enabled: true, reason: nil, action: onExportRuntimeLog),
                ActionMenuItem(title: "Reveal Exports", systemImage: "folder.fill", enabled: true, reason: nil, action: onRevealExports),
                ActionMenuItem(title: "Ship Now", systemImage: "paperplane", enabled: true, reason: nil, action: onShipNow)
            ]
        )

        let isFinding = peripheral.map { findFingerprintID == $0.fingerprintID } ?? false
        let probeResult = peripheral.flatMap { prober.results[$0.fingerprintID] }
        let canProbe = peripheral.map { ($0.fingerprint.isConnectable == true) && prober.canProbe(fingerprintID: $0.fingerprintID) } ?? false
        let bleActions = ActionMenuSection(
            title: "BLE Actions",
            items: [
                ActionMenuItem(
                    title: isFinding ? "Stop Find" : "Start Find",
                    systemImage: "scope",
                    enabled: peripheral != nil,
                    reason: peripheral == nil ? "No BLE device selected" : nil,
                    action: {
                        guard let peripheral = peripheral else { return }
                        if isFinding {
                            findFingerprintID = ""
                            LogStore.shared.log(.info, "BLE Find stopped id=\(peripheral.fingerprintID)")
                        } else {
                            findFingerprintID = peripheral.fingerprintID
                            LogStore.shared.log(.info, "BLE Find started id=\(peripheral.fingerprintID)")
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Pin to Case",
                    systemImage: "pin",
                    enabled: peripheral != nil,
                    reason: peripheral == nil ? "No BLE device selected" : nil,
                    action: {
                        if let peripheral {
                            CaseManager.shared.pinBLE(fingerprintID: peripheral.fingerprintID, bleScanner: BLEScanner.shared, log: LogStore.shared)
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Reveal BLE Artifacts",
                    systemImage: "folder",
                    enabled: peripheral != nil,
                    reason: peripheral == nil ? "No BLE device selected" : nil,
                    action: {
                        if let peripheral {
                            let caseDir = StoragePaths.workspaceSubdir("cases").appendingPathComponent(LogStore.sanitizeFilename(peripheral.fingerprintID))
                            if FileManager.default.fileExists(atPath: caseDir.path) {
                                NSWorkspace.shared.open(caseDir)
                            } else {
                                let dir = StoragePaths.inboxSubdir("ble-raw")
                                NSWorkspace.shared.open(dir)
                            }
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Probe (Connect + Read Basics)",
                    systemImage: "antenna.radiowaves.left.and.right",
                    enabled: canProbe,
                    reason: peripheral == nil ? "No BLE device selected" : (canProbe ? nil : "Device not connectable"),
                    action: {
                        if let peripheral {
                            prober.startProbe(peripheralInfo: peripheral)
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Export BLE Fingerprint (Raw + Readable)",
                    systemImage: "tray.and.arrow.down",
                    enabled: peripheral != nil,
                    reason: peripheral == nil ? "No BLE device selected" : nil,
                    action: {
                        if let peripheral {
                            exportFingerprintJSON(peripheral, label: labelText)
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Export BLE Device Report",
                    systemImage: "doc.text",
                    enabled: probeResult != nil,
                    reason: probeResult == nil ? "No BLE probe report available" : nil,
                    action: {
                        if let probeResult {
                            exportProbeReport(probeResult)
                        }
                    }
                ),
                ActionMenuItem(
                    title: "Export Probe Report",
                    systemImage: "tray.and.arrow.down",
                    enabled: probeResult != nil,
                    reason: probeResult == nil ? "No BLE probe report available" : nil,
                    action: {
                        if let probeResult {
                            exportProbeReport(probeResult)
                        }
                    }
                )
            ]
        )
        return [appActions, bleActions]
    }

    private func currentFlashedNoteLookupKeys() -> (preferred: String?, fallbacks: [String]) {
        guard let peripheral else { return (nil, []) }
        let serial = prober.results[peripheral.fingerprintID]?.serialNumber
        let sanitizedSerial = serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = (sanitizedSerial?.isEmpty == false) ? sanitizedSerial : nil
        let fallbacks = [
            peripheral.fingerprintID,
            peripheral.id.uuidString,
            peripheral.name ?? ""
        ]
        return (preferred, fallbacks)
    }

    private func loadFlashedNoteForCurrentSelection() {
        let keys = currentFlashedNoteLookupKeys()
        let resolved = flashedNoteStore.resolveKey(preferred: keys.preferred, fallbacks: keys.fallbacks)
        flashedNoteKey = resolved
        flashedNoteText = flashedNoteStore.note(for: resolved)
    }
}


struct BLEFindPanel: View {
    let peripheral: BLEPeripheral

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find")
                .font(.system(size: 13, weight: .semibold))
            Text("Current RSSI: \(peripheral.rssi)")
                .font(.system(size: 12))
            Text("Smoothed RSSI: \(String(format: "%.1f", peripheral.smoothedRSSI))")
                .font(.system(size: 12))
            Text("Trend: \(trendLabel())")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Proximity: \(hotColdLabel())")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.black.opacity(0.04))
        .cornerRadius(6)
    }

    private func trendLabel() -> String {
        let now = Date()
        let target = now.addingTimeInterval(-2)
        guard let current = peripheral.rssiHistory.last else { return "Unknown" }
        let past = peripheral.rssiHistory.last(where: { $0.timestamp <= target }) ?? peripheral.rssiHistory.first
        guard let past else { return "Unknown" }
        let delta = current.smoothedRSSI - past.smoothedRSSI
        if delta > 3 {
            return "Up"
        } else if delta < -3 {
            return "Down"
        } else {
            return "Stable"
        }
    }

    private func hotColdLabel() -> String {
        let rssi = peripheral.smoothedRSSI
        if rssi > -45 {
            return "Very Close"
        } else if rssi > -60 {
            return "Close"
        } else if rssi > -75 {
            return "Medium"
        } else {
            return "Far"
        }
    }
}


struct LogScanToggles: Hashable {
    let onvifDiscovery: Bool
    let serviceDiscovery: Bool
    let arpWarmup: Bool
    let safeMode: Bool
    let bleDiscovery: Bool
}

struct LogPanel: View {
    @ObservedObject var logStore: LogStore
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var bleScanner: BLEScanner
    let scanToggles: LogScanToggles
    let onExportAudit: () -> Void
    let onSelectIP: (String) -> Void
    let onSelectBLEFingerprint: (String) -> Void
    @State private var autoScroll = true
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var contentOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    onExportAudit()
                }
                label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Export Audit Log")
                .accessibilityLabel(Text("Export Audit Log"))

                Button {
                    if let url = LogStore.latestAuditURL(log: logStore) {
                        NSWorkspace.shared.open(url)
                    } else {
                        logStore.log(.warn, "No audit file exists yet in ~/SODS/reports/audit-raw/")
                    }
                }
                label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("View Latest Audit")
                .accessibilityLabel(Text("View Latest Audit"))

                Button {
                    if let url = LogStore.latestReadableAuditURL(log: logStore) {
                        NSWorkspace.shared.open(url)
                    } else {
                        logStore.log(.warn, "No readable audit file exists yet in ~/SODS/reports/audit-readable/")
                    }
                }
                label: {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("View Latest Readable")
                .accessibilityLabel(Text("View Latest Readable"))

                Button {
                    let iso = LogStore.isoTimestamp()
                    let rawFilename = "SODS-LogsRaw-\(iso).txt"
                    let rawURL = LogStore.exportURL(subdir: "logs-raw", filename: rawFilename, log: logStore)
                    _ = LogStore.writeStringReturning(logStore.copyAllText(), to: rawURL, log: logStore)

                    let readableFilename = "SODS-LogsReadable-\(iso).txt"
                    let readableURL = LogStore.exportURL(subdir: "logs-readable", filename: readableFilename, log: logStore)
                    let readableText = buildReadableLog(rawFilename: rawFilename, scanner: scanner, bleScanner: bleScanner, scanToggles: scanToggles)
                    if let url = LogStore.writeStringReturning(readableText, to: readableURL, log: logStore) {
                        LogStore.copyExportSummaryToClipboard(path: url.path, summary: readableText)
                        logStore.log(.info, "Runtime log export copied to clipboard")
                    }
                }
                label: {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Export Runtime Log (TXT)")
                .accessibilityLabel(Text("Export Runtime Log (TXT)"))

                Button {
                    logStore.clear()
                }
                label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Clear")
                .accessibilityLabel(Text("Clear"))
            }

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(logStore.lines) { line in
                                Text(line.formatted)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(color(for: line.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                                    .onTapGesture {
                                        if let ip = extractIPv4(from: line.formatted) {
                                            onSelectIP(ip)
                                        } else if let fingerprint = extractFingerprintID(from: line.formatted) {
                                            onSelectBLEFingerprint(fingerprint)
        }
    }

}
                        }
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .preference(key: ContentHeightKey.self, value: contentGeo.size.height)
                                    .preference(key: ContentOffsetKey.self, value: contentGeo.frame(in: .named("logScroll")).minY)
                            }
                        )
                    }
                    .coordinateSpace(name: "logScroll")
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        contentHeight = height
                        viewportHeight = geo.size.height
                        updateAutoScroll()
                    }
                    .onPreferenceChange(ContentOffsetKey.self) { offset in
                        contentOffset = offset
                        updateAutoScroll()
                    }
                    .onChange(of: logStore.lines.count) { _ in
                        if autoScroll, let last = logStore.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.04))
        .cornerRadius(8)
    }

    private func updateAutoScroll() {
        let maxOffset = max(0, contentHeight - viewportHeight)
        let distanceFromBottom = abs((-contentOffset) - maxOffset)
        autoScroll = distanceFromBottom < 8
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func extractIPv4(from text: String) -> String? {
        let pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        if let matchRange = Range(match.range, in: text) {
            return String(text[matchRange])
        }
        return nil
    }

    private func extractFingerprintID(from text: String) -> String? {
        let patterns = [
            #"fingerprintID=([0-9a-fA-F]{10})"#,
            #"id=([0-9a-fA-F]{10})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               match.numberOfRanges >= 2,
               let idRange = Range(match.range(at: 1), in: text) {
                return String(text[idRange])
            }
        }
        return nil
    }
}

@MainActor
func buildReadableLog(rawFilename: String, scanner: NetworkScanner, bleScanner: BLEScanner, scanToggles: LogScanToggles) -> String {
    let logStore = LogStore.shared
    var lines: [String] = []
    let summary = scanner.scanSummary()
    let formatter = ISO8601DateFormatter()
    let start = summary.start.map { formatter.string(from: $0) } ?? "unknown"
    let end = summary.end.map { formatter.string(from: $0) } ?? "unknown"
    let duration: String = {
        guard let s = summary.start, let e = summary.end else { return "unknown" }
        let seconds = Int(e.timeIntervalSince(s))
        return "\(seconds)s"
    }()

    lines.append("SODS READABLE LOG")
    lines.append("Generated: \(formatter.string(from: Date()))")
    lines.append("")
    lines.append("SCAN SUMMARY")
    lines.append("Scope: \(summary.scope)")
    lines.append("Start: \(start)")
    lines.append("End: \(end)")
    lines.append("Duration: \(duration)")
    lines.append("Total IPs: \(summary.totalIPs)")
    lines.append("Alive: \(summary.aliveCount)")
    lines.append("Interesting: \(summary.interestingCount)")
    lines.append("Safe Mode: \(summary.safeMode ? "ON" : "OFF")")
    lines.append("Toggles: ONVIF=\(scanToggles.onvifDiscovery), ServiceDiscovery=\(scanToggles.serviceDiscovery), ARPWarmup=\(scanToggles.arpWarmup), BLE=\(scanToggles.bleDiscovery)")
    lines.append("")

    let aliasOverrides = IdentityResolver.shared.aliasMap()
    let highConfidence = EntityStore.shared.hosts
        .filter { $0.hostConfidence.level == .high }
        .sorted { $0.hostConfidence.score > $1.hostConfidence.score }
        .prefix(10)
    lines.append("FINDINGS (HIGH CONFIDENCE)")
    if highConfidence.isEmpty {
        lines.append("None.")
    } else {
        for host in highConfidence {
            let alias = aliasOverrides[host.ip]
                ?? host.macAddress.flatMap { aliasOverrides[$0] }
                ?? host.hostname.flatMap { aliasOverrides[$0] }
            let aliasTag = alias.map { " alias=\($0)" } ?? ""
            lines.append("- \(host.ip)\(aliasTag) \(host.vendor ?? "") conf=\(host.hostConfidence.score) ports=\(host.openPorts.sorted().map(String.init).joined(separator: ","))")
        }
    }
    lines.append("")

    lines.append("BLE SUMMARY")
    let bleDevices = EntityStore.shared.blePeripherals
    lines.append("Devices: \(bleDevices.count)")
    let beacons = bleDevices.filter { $0.fingerprint.beaconHint != nil }
    if !beacons.isEmpty {
        lines.append("Beacons: \(beacons.count)")
    }
    let topBle = bleDevices.sorted { $0.rssi > $1.rssi }.prefix(5)
    if !topBle.isEmpty {
        lines.append("Strongest RSSI:")
        for item in topBle {
            let label = IdentityResolver.shared.resolveLabel(keys: [item.fingerprintID, item.id.uuidString]) ?? bleScanner.label(for: item.fingerprintID) ?? item.name ?? "Unknown"
            lines.append("- \(label) rssi=\(item.rssi) dBm")
        }
    }
    lines.append("")

    lines.append("KEY EVENTS")
    let warnings = logStore.lines.filter { $0.level == .warn }
    let errors = logStore.lines.filter { $0.level == .error }
    if warnings.isEmpty && errors.isEmpty {
        lines.append("No warnings or errors.")
    } else {
        if !errors.isEmpty {
            lines.append("Errors:")
            for line in errors.prefix(10) {
                lines.append("- \(line.formatted)")
            }
        }
        if !warnings.isEmpty {
            lines.append("Warnings:")
            for line in warnings.prefix(10) {
                lines.append("- \(line.formatted)")
            }
        }
    }
    lines.append("")
    lines.append("RAW LOG REF: \(rawFilename)")
    lines.append("RAW LOG (last 200 lines)")
    let tail = logStore.lines.suffix(200).map { $0.formatted }
    lines.append(contentsOf: tail)

    return lines.joined(separator: "\n")
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContentOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FingerprintReadablePayload: Codable {
    struct Meta: Codable {
        let isoTimestamp: String
        let fingerprintID: String
        let label: String
    }
    struct RawRef: Codable {
        let filename: String
    }
    struct RawValues: Codable {
        let manufacturerData: String
        let serviceUUIDs: [String]
        let rssi: Int
        let advertisementBytes: String
        let fingerprintID: String
    }
    struct CompanyDecoded: Codable {
        let id: String?
        let name: String
        let assignmentDate: String?
    }
    struct ServiceDecoded: Codable {
        let uuid: String
        let uuidDisplay: String
        let name: String
        let type: String
        let source: String
    }
    struct Decoded: Codable {
        let company: CompanyDecoded
        let services: [ServiceDecoded]
        let unknownServices: [String]
        let unknownServicesNormalized: [String]
    }
    struct Proximity: Codable {
        let rssiRaw: Int
        let rssiSmoothed: Double
        let bucket: String
        let note: String
    }
    struct Confidence: Codable {
        let level: String
        let score: Int
        let reasons: [String]
    }
    struct GlossaryItem: Codable {
        let term: String
        let meaning: String
    }
    let meta: Meta
    let rawRef: RawRef
    let summary: String
    let decoded: Decoded
    let raw: RawValues
    let proximity: Proximity
    let confidence: Confidence
    let recommendations: [String]
    let glossary: [GlossaryItem]
}

private struct BLEFingerprintRaw: Codable {
    let fingerprintID: String
    let label: String
    let name: String?
    let rssi: Int
    let smoothedRSSI: Double
    let serviceUUIDs: [String]
    let manufacturerDataHex: String?
    let advertisementBytes: String?
    let fingerprint: BLEAdFingerprint
    let bleConfidence: BLEConfidence
    let lastSeen: Date
}

private func rssiBucket(_ rssi: Double) -> String {
    if rssi > -45 { return "Very Close (> -45 dBm)" }
    if rssi > -60 { return "Close (-45 to -60 dBm)" }
    if rssi > -75 { return "Same Room (-60 to -75 dBm)" }
    return "Far (< -75 dBm)"
}

private func bleServiceLabel(_ uuid: String) -> String {
    if let info = BLEMetadataStore.shared.assignedUUIDInfo(for: CBUUID(string: uuid)) {
        return "\(uuid) (\(info.name))"
    }
    return uuid
}

@MainActor
private func exportFingerprintJSON(_ peripheral: BLEPeripheral, label: String) {
    let log = LogStore.shared
    let iso = LogStore.isoTimestamp()
    let safeID = LogStore.sanitizeFilename(peripheral.fingerprintID)
    let rawFilename = "SODS-BLERaw-\(safeID)-\(iso).json"
    let rawURL = LogStore.exportURL(subdir: "ble-raw", filename: rawFilename, log: log)
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rawPayload = BLEFingerprintRaw(
            fingerprintID: peripheral.fingerprintID,
            label: label.isEmpty ? "Unlabeled" : label,
            name: peripheral.name,
            rssi: peripheral.rssi,
            smoothedRSSI: peripheral.smoothedRSSI,
            serviceUUIDs: peripheral.serviceUUIDs,
            manufacturerDataHex: peripheral.manufacturerDataHex,
            advertisementBytes: peripheral.manufacturerDataHex,
            fingerprint: peripheral.fingerprint,
            bleConfidence: peripheral.bleConfidence,
            lastSeen: peripheral.lastSeen
        )
        let rawData = try encoder.encode(rawPayload)
        _ = LogStore.writeDataReturning(rawData, to: rawURL, log: log)

        let readablePayload = buildReadableFingerprintPayload(peripheral: peripheral, label: label, rawFilename: rawFilename)
        let readableFilename = "SODS-BLEReadable-\(safeID)-\(iso).json"
        let readableURL = LogStore.exportURL(subdir: "ble-readable", filename: readableFilename, log: log)
        let readableData = try encoder.encode(readablePayload)
        if let url = LogStore.writeDataReturning(readableData, to: readableURL, log: log) {
            let summary = [
                "BLE fingerprint readable export",
                "Fingerprint: \(peripheral.fingerprintID)",
                "Label: \(label.isEmpty ? "Unlabeled" : label)",
                "Confidence: \(peripheral.bleConfidence.level.rawValue) (\(peripheral.bleConfidence.score))"
            ].joined(separator: "\n")
            LogStore.copyExportSummaryToClipboard(path: url.path, summary: summary)
            log.log(.info, "BLE fingerprint export copied to clipboard")
        }
    } catch {
        log.log(.error, "Failed to export BLE fingerprint: \(error.localizedDescription)")
    }
}

@MainActor
private func buildReadableFingerprintPayload(peripheral: BLEPeripheral, label: String, rawFilename: String) -> FingerprintReadablePayload {
    let fingerprint = peripheral.fingerprint
    let companyName = fingerprint.manufacturerCompanyName ?? "Unknown"
    let companyID = fingerprint.manufacturerCompanyID.map { String(format: "0x%04X", $0) }
    let assignmentDate = fingerprint.manufacturerAssignmentDate
    let decodedServices = fingerprint.servicesDecoded.map {
        FingerprintReadablePayload.ServiceDecoded(
            uuid: $0.uuid,
            uuidDisplay: BLEUUIDDisplay.shortAndNormalized($0.uuid),
            name: $0.name,
            type: $0.type,
            source: $0.source
        )
    }
    let unknownNormalized = fingerprint.unknownServices.map { BLEUUIDDisplay.shortAndNormalized($0) }
    let proximity = rssiBucket(peripheral.smoothedRSSI)
    let confidence = peripheral.bleConfidence
    let summaryParts: [String] = [
        companyID != nil ? "Likely \(companyName) device based on Company ID \(companyID!)." : "Company ID not available.",
        fingerprint.beaconHint != nil ? "Advertises \(fingerprint.beaconHint!) beacon pattern." : "No standard beacon hint detected.",
        decodedServices.isEmpty ? "No standard services decoded." : "Advertises standard services: \(decodedServices.map { $0.name }.joined(separator: ", "))."
    ]
    let summary = summaryParts.joined(separator: " ")
    let recs = [
        "Label the device for local tracking.",
        "Observe RSSI changes to understand proximity.",
        "If authorized, identify the device owner in your environment."
    ]
    let glossary = [
        FingerprintReadablePayload.GlossaryItem(term: "RSSI", meaning: "Received Signal Strength Indicator; higher (less negative) means closer."),
        FingerprintReadablePayload.GlossaryItem(term: "Beacon", meaning: "A BLE advertising pattern such as iBeacon or Eddystone."),
        FingerprintReadablePayload.GlossaryItem(term: "Assigned Numbers", meaning: "Bluetooth SIG registered UUIDs and company identifiers used to decode common services.")
    ]
    return FingerprintReadablePayload(
        meta: .init(
            isoTimestamp: LogStore.isoTimestamp(),
            fingerprintID: peripheral.fingerprintID,
            label: label.isEmpty ? "Unlabeled" : label
        ),
        rawRef: .init(filename: rawFilename),
        summary: summary,
        decoded: .init(
            company: .init(
                id: companyID,
                name: companyName,
                assignmentDate: assignmentDate
            ),
            services: decodedServices,
            unknownServices: fingerprint.unknownServices,
            unknownServicesNormalized: unknownNormalized
        ),
        raw: .init(
            manufacturerData: peripheral.manufacturerDataHex ?? "",
            serviceUUIDs: peripheral.serviceUUIDs,
            rssi: peripheral.rssi,
            advertisementBytes: peripheral.manufacturerDataHex ?? "",
            fingerprintID: peripheral.fingerprintID
        ),
        proximity: .init(
            rssiRaw: peripheral.rssi,
            rssiSmoothed: peripheral.smoothedRSSI,
            bucket: proximity,
            note: "RSSI is noisy; bucket is an approximate proximity hint."
        ),
        confidence: .init(
            level: confidence.level.rawValue,
            score: confidence.score,
            reasons: confidence.reasons
        ),
        recommendations: recs,
        glossary: glossary
    )
}

@MainActor
private func exportProbeReport(_ result: BLEProbeResult) {
    let log = LogStore.shared
    let iso = LogStore.isoTimestamp()
    let safeID = LogStore.sanitizeFilename(result.fingerprintID)
    let filename = "SODS-BLEProbe-\(safeID)-\(iso).json"
    let url = LogStore.exportURL(subdir: "ble-probes", filename: filename, log: log)
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        if let written = LogStore.writeDataReturning(data, to: url, log: log) {
            let summary = [
                "BLE probe report",
                "Fingerprint: \(result.fingerprintID)",
                result.alias == nil ? nil : "Alias: \(result.alias!)",
                "Status: \(result.status)"
            ].compactMap { $0 }.joined(separator: "\n")
            LogStore.copyExportSummaryToClipboard(path: written.path, summary: summary)
            log.log(.info, "BLE probe report copied to clipboard")
        }
    } catch {
        log.log(.error, "Failed to export BLE probe report: \(error.localizedDescription)")
    }
}

func portLabelsString(_ ports: [Int]) -> String {
    let labels = ports.sorted().compactMap { portLabel(for: $0) }
    return labels.joined(separator: ", ")
}

private func portLabel(for port: Int) -> String? {
    switch port {
    case 80: return "HTTP"
    case 443: return "HTTPS"
    case 554: return "RTSP"
    case 8554: return "RTSP (alt)"
    case 3702: return "ONVIF"
    case 8000: return "HTTP (alt)"
    case 8080: return "HTTP (alt)"
    case 8443: return "HTTPS (alt)"
    case 22: return "SSH"
    case 445: return "SMB"
    case 5353: return "mDNS"
    case 1900: return "SSDP"
    default: return nil
    }
}

func exportCSV(_ snapshot: ExportSnapshot) -> String {
    var lines: [String] = []
    lines.append("timestamp,ip,status,ports,hostname,mac,vendor,vendor_confidence,vendor_confidence_reasons,host_conf_level,host_conf_score,host_conf_reasons,ssdp_server,ssdp_location,ssdp_st,ssdp_usn,bonjour_services,http_status,http_server,http_auth,http_title,onvif,rtsp_uri")
    for record in snapshot.records {
        let ports = record.ports.map(String.init).joined(separator: "|")
        let bonjour = record.bonjourServices.map { service in
            let txt = service.txt.joined(separator: " ")
            return "\(service.name)|\(service.type)|\(service.port)|\(txt)"
        }.joined(separator: ";")
        let httpStatus = record.httpStatus.map(String.init) ?? ""
        let confidenceReasons = record.vendorConfidenceReasons.joined(separator: " | ")
        let hostConfidenceReasons = record.hostConfidence.reasons.joined(separator: " | ")
        let fields = [
            snapshot.timestamp,
            record.ip,
            record.status,
            ports,
            record.hostname,
            record.mac,
            record.vendor,
            String(record.vendorConfidenceScore),
            confidenceReasons,
            record.hostConfidence.level.rawValue,
            String(record.hostConfidence.score),
            hostConfidenceReasons,
            record.ssdpServer,
            record.ssdpLocation,
            record.ssdpST,
            record.ssdpUSN,
            bonjour,
            httpStatus,
            record.httpServer,
            record.httpAuth,
            record.httpTitle,
            record.onvif ? "true" : "false",
            record.rtspURI
        ].map { csvEscape($0) }
        lines.append(fields.joined(separator: ","))
    }
    return lines.joined(separator: "\n")
}

private func csvEscape(_ value: String) -> String {
    let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n")
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    return needsQuotes ? "\"\(escaped)\"" : escaped
}

private func openBluetoothPrivacySettings() {
    let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    let rootURL = URL(string: "x-apple.systempreferences:")
    if let privacyURL, NSWorkspace.shared.open(privacyURL) {
        return
    }
    if let rootURL {
        NSWorkspace.shared.open(rootURL)
    }
}

extension Notification.Name {
    static let flashNodeCommand = Notification.Name("sods.flashNodeCommand")
    static let connectNodeCommand = Notification.Name("sods.connectNodeCommand")
    static let sodsOpenURLInApp = Notification.Name("sods.openUrlInApp")
    static let sodsDeepLinkCommand = Notification.Name("sods.deepLinkCommand")
    static let openGodMenuCommand = Notification.Name("sods.openGodMenuCommand")
    static let targetLockNodeCommand = Notification.Name("sods.targetLockNodeCommand")
    static let navigatePreviousViewCommand = Notification.Name("sods.navigatePreviousViewCommand")
    static let navigateNextViewCommand = Notification.Name("sods.navigateNextViewCommand")
    static let openScanningViewCommand = Notification.Name("sods.openScanningViewCommand")
}

struct RemoveNodeSheet: View {
    let node: NodeRecord
    let stationBaseURL: String
    let hostHint: String?
    let onForgetLocal: () -> Void
    let onClose: () -> Void

    @State private var busy = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Remove Node", onBack: nil, onClose: onClose)
            Text(node.label)
                .font(.system(size: 14, weight: .semibold))
            Text("Node ID: \(node.id)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            let profile = NodeFirmwareProfile.infer(nodeID: node.id, hostname: node.hostname, capabilities: node.capabilities)
            Text("Firmware: \(profile.rawValue)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            if let hostHint, !hostHint.isEmpty {
                Text("Host: \(hostHint)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            if let err = lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }

            Divider()

            HStack(spacing: 10) {
                Text("Forget locally")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    lastError = nil
                    onForgetLocal()
                    onClose()
                } label: {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(busy)
                .help("Forget locally")
                .accessibilityLabel(Text("Forget locally"))
            }

            HStack(spacing: 10) {
                Text("Forget via Station")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await forgetViaStation() }
                } label: {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(busy || stationBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Forget via Station")
                .accessibilityLabel(Text("Forget via Station"))
            }

            let canFactoryReset = profile == .opsPortalCYD && (hostHint?.isEmpty == false)
            HStack(spacing: 10) {
                Text("Factory reset networking (CYD)")
                    .font(.system(size: 11))
                    .foregroundColor(canFactoryReset ? .secondary : Theme.muted)
                Spacer()
                Button {
                    Task { await factoryResetNetworking() }
                } label: {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(busy || !canFactoryReset)
                .help("Factory reset networking (CYD)")
                .accessibilityLabel(Text("Factory reset networking (CYD)"))
            }

            Spacer()
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 220)
        .background(Theme.panel)
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> (Int, String) {
        let base = stationBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: base + path) else { throw NSError(domain: "remove.node", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad station url"]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(data: data, encoding: .utf8) ?? "")
    }

    private func forgetViaStation() async {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            let (status, text) = try await postJSON(path: "/api/registry/nodes/forget", body: ["node_id": node.id])
            guard (200...299).contains(status) else {
                lastError = "Station refused: HTTP \(status) \(text)"
                return
            }
            await MainActor.run {
                NodeRegistry.shared.load()
            }
            onClose()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func factoryResetNetworking() async {
        busy = true
        defer { busy = false }
        lastError = nil
        guard let hostHint, !hostHint.isEmpty else {
            lastError = "Missing device host/IP."
            return
        }
        do {
            let (status, text) = try await postJSON(path: "/api/registry/nodes/factory-reset", body: ["node_id": node.id, "host": hostHint])
            guard (200...299).contains(status) else {
                lastError = "Factory reset failed: HTTP \(status) \(text)"
                return
            }
            onClose()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private func sodsRootPath() -> String {
    StoragePaths.sodsRootPath()
}

private func nodeAgentRootPath() -> String {
    "\(sodsRootPath())/firmware/node-agent"
}

private func p4RootPath() -> String {
    "\(sodsRootPath())/firmware/sods-p4-godbutton"
}

private func portalRootPath() -> String {
    "\(sodsRootPath())/firmware/ops-portal"
}

func nodeActionSystemImage(_ title: String) -> String {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.contains("connect") { return "link.circle" }
    if t.contains("identify") || t.contains("whoami") { return "person.crop.circle" }
    if t.contains("scan") && t.contains("stop") { return "stop.circle" }
    if t.contains("scan") { return "dot.radiowaves.left.and.right" }
    if t.contains("probe") { return "waveform.path.ecg" }
    if t.contains("ping") { return "antenna.radiowaves.left.and.right" }
    if t.contains("report") { return "doc.badge.plus" }
    if t.contains("ship") { return "paperplane" }
    if t.contains("refresh") { return "arrow.clockwise" }
    return "circle"
}

struct FlashPopoverView: View {
    let status: APIHealth
    let onFlashEsp32: () -> Void
    let onFlashEsp32c3: () -> Void
    let onFlashPortalCyd: () -> Void
    let onFlashP4: () -> Void
    let onOpenWebTools: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Flash Device")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(status.color))
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.panelAlt)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Theme.border, lineWidth: 1)
                )
            }

            Text("Pick a target to open the station-hosted web flasher.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 10) {
                Button { onFlashEsp32() } label: {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help("ESP32 DevKit")
                .accessibilityLabel(Text("ESP32 DevKit"))

                Button { onFlashEsp32c3() } label: {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help("XIAO ESP32-C3")
                .accessibilityLabel(Text("XIAO ESP32-C3"))
            }
            HStack(spacing: 10) {
                Button { onFlashPortalCyd() } label: {
                    Image(systemName: "display")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help("Ops Portal CYD")
                .accessibilityLabel(Text("Ops Portal CYD"))

                Button { onFlashP4() } label: {
                    Image(systemName: "radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help("ESP32-P4 God Button")
                .accessibilityLabel(Text("ESP32-P4 God Button"))
            }

            Button { onOpenWebTools() } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Open Web Tools Folder")
            .accessibilityLabel(Text("Open Web Tools Folder"))
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }
}

enum FlashTarget: String, CaseIterable, Identifiable {
    case esp32dev
    case esp32c3
    case portalCyd = "portal-cyd"
    case esp32p4

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .esp32dev:
            return "cpu"
        case .esp32c3:
            return "cpu.fill"
        case .portalCyd:
            return "display"
        case .esp32p4:
            return "radiowaves.left.and.right"
        }
    }

    var label: String {
        switch self {
        case .esp32dev:
            return "ESP32 DevKit v1"
        case .esp32c3:
            return "XIAO ESP32-C3"
        case .portalCyd:
            return "Ops Portal (CYD)"
        case .esp32p4:
            return "ESP32-P4 God Button"
        }
    }

    var defaultPort: Int {
        switch self {
        case .esp32dev:
            return 8000
        case .esp32c3:
            return 8001
        case .portalCyd:
            return 8003
        case .esp32p4:
            return 8002
        }
    }

    var chipQuery: String? {
        switch self {
        case .esp32dev:
            return nil
        case .esp32c3:
            return "chip=esp32c3"
        case .portalCyd:
            return nil
        case .esp32p4:
            return "chip=esp32p4"
        }
    }

    var buildCommand: String {
        switch self {
        case .esp32dev:
            return "cd \(nodeAgentRootPath()) && node ./tools/stage.mjs --board esp32-devkitv1 --version devstation"
        case .esp32c3:
            return "cd \(nodeAgentRootPath()) && node ./tools/stage.mjs --board esp32-c3 --version devstation"
        case .portalCyd:
            return "cd \(sodsRootPath())/firmware/ops-portal && node ./tools/stage.mjs --board cyd-2432s028 --version devstation"
        case .esp32p4:
            return "cd \(sodsRootPath())/firmware/sods-p4-godbutton && node ./tools/stage.mjs --board waveshare-esp32p4 --version devstation"
        }
    }

    var stageCommand: String {
        switch self {
        case .esp32dev:
            return "cd \(nodeAgentRootPath()) && node ./tools/stage.mjs --board esp32-devkitv1 --version devstation --skip-build"
        case .esp32c3:
            return "cd \(nodeAgentRootPath()) && node ./tools/stage.mjs --board esp32-c3 --version devstation --skip-build"
        case .portalCyd:
            return "cd \(sodsRootPath())/firmware/ops-portal && node ./tools/stage.mjs --board cyd-2432s028 --version devstation --skip-build"
        case .esp32p4:
            return "cd \(sodsRootPath())/firmware/sods-p4-godbutton && node ./tools/stage.mjs --board waveshare-esp32p4 --version devstation --skip-build"
        }
    }
}

struct FlashPrepStatus: Equatable {
    let isReady: Bool
    let missingItems: [String]
    let buildCommand: String
}

@MainActor
final class FlashServerManager: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case requiresTerminal
        case error
    }

    @Published var selectedTarget: FlashTarget = .esp32dev
    @Published private(set) var state: State = .idle
    @Published private(set) var prepStatus = FlashPrepStatus(isReady: true, missingItems: [], buildCommand: "")
    @Published private(set) var terminalCommand: String?
    @Published private(set) var port: Int?
    @Published private(set) var url: URL?
    @Published private(set) var lastError: String?

    private var process: Process?
    private var outputBuffer = ""
    private var didLogTargets = false

    var isRunning: Bool { state == .running }
    var isStarting: Bool { state == .starting }
    var canOpenFlasher: Bool { url != nil }

    var statusLine: String? {
        switch state {
        case .idle:
            return "Server idle."
        case .starting:
            return "Preparing station flasher..."
        case .running:
            if let url {
                return "Station flasher at \(url.absoluteString)"
            }
            return "Station flasher ready."
        case .requiresTerminal:
            if let url {
                return "Run in Terminal, then open \(url.absoluteString)"
            }
            return "Run in Terminal to launch the flash server."
        case .error:
            return "Flash server error."
        }
    }

    var detailLine: String? {
        var parts: [String] = []
        if let port {
            parts.append("Port: \(port)")
        }
        if let lastError, !lastError.isEmpty {
            parts.append("Error: \(lastError)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    func refreshPrepStatus() {
        prepStatus = buildPrepStatus(for: selectedTarget)
        if !didLogTargets {
            let labels = FlashTarget.allCases.map { $0.label }.joined(separator: ", ")
            LogStore.logAsync(.info, "Flasher targets: \(labels)")
            didLogTargets = true
        }
        if !prepStatus.missingItems.isEmpty {
            LogStore.logAsync(.warn, "Flasher missing artifacts for \(selectedTarget.label): \(prepStatus.missingItems.joined(separator: ", "))")
        }
    }

    func startSelectedTarget() {
        let status = buildPrepStatus(for: selectedTarget)
        prepStatus = status
        guard status.isReady else {
            state = .idle
            return
        }
        openStationFlasher(target: selectedTarget, autoOpen: true)
    }

    func stop() {
        state = .idle
        lastError = nil
        terminalCommand = nil
        port = nil
        url = nil
    }

    func openFlasher() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func openLocalFlasher() {
        openStationFlasher(target: selectedTarget, autoOpen: true)
    }

    private func openStationFlasher(target: FlashTarget, autoOpen: Bool) {
        stop()
        state = .starting
        terminalCommand = nil
        lastError = nil
        outputBuffer = ""
        port = nil

        let baseURL = SODSStore.shared.baseURL
        guard let url = stationFlashURL(baseURL: baseURL, target: target) else {
            state = .error
            lastError = "Invalid station URL."
            return
        }
        self.url = url
        state = .running
        if autoOpen {
            NSWorkspace.shared.open(url)
        }
    }

    private func stationFlashURL(baseURL: String, target: FlashTarget) -> URL? {
        let path: String
        switch target {
        case .esp32dev:
            path = "/flash/esp32"
        case .esp32c3:
            path = "/flash/esp32c3"
        case .portalCyd:
            path = "/flash/portal-cyd"
        case .esp32p4:
            path = "/flash/p4"
        }
        return URL(string: "\(baseURL)\(path)")
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.outputBuffer.append(chunk)
            if let url = self.extractURL(from: self.outputBuffer) {
                self.url = url
            }
        }
    }

    private func extractURL(from text: String) -> URL? {
        let pattern = #"http://localhost:\d+/[^\s]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    private func pickPort(startingAt base: Int) -> Int? {
        for offset in 0...20 {
            let candidate = base + offset
            if isPortAvailable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.cancel()
            return true
        } catch {
            return false
        }
    }

    private func buildProcess(for target: FlashTarget, port: Int) -> (commandLine: String?, config: ProcessConfig?) {
        let root: String
        let toolsDir: String
        let scriptPath: String
        switch target {
        case .esp32dev:
            root = nodeAgentRoot()
            toolsDir = "\(root)/tools"
            scriptPath = "\(toolsDir)/flash-esp32dev.sh"
        case .esp32c3:
            root = nodeAgentRoot()
            toolsDir = "\(root)/tools"
            scriptPath = "\(toolsDir)/flash-esp32c3.sh"
        case .portalCyd:
            root = sodsRootPath()
            toolsDir = "\(root)/tools"
            scriptPath = "\(toolsDir)/portal-cyd-stage.sh"
        case .esp32p4:
            root = p4RootPath()
            toolsDir = "\(root)/tools"
            scriptPath = ""
        }

        if !scriptPath.isEmpty && FileManager.default.fileExists(atPath: scriptPath) {
            let needsPort = target != .portalCyd
            let suffix = needsPort ? " --port \(port)" : ""
            let commandLine = "cd \(root) && \(scriptPath)\(suffix)"
            let config = ProcessConfig(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", "\(scriptPath)\(suffix)"],
                currentDirectoryURL: URL(fileURLWithPath: root)
            )
            return (commandLine, config)
        }

        let httpCommand = "cd \(root) && python3 -m http.server \(port)"
        let config = ProcessConfig(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "python3 -m http.server \(port)"],
            currentDirectoryURL: URL(fileURLWithPath: root)
        )
        return (httpCommand, config)
    }

    private func defaultURL(target: FlashTarget, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = port
        components.path = "/esp-web-tools/"
        components.query = target.chipQuery
        return components.url
    }

    private func buildPrepStatus(for target: FlashTarget) -> FlashPrepStatus {
        let root: String
        switch target {
        case .esp32dev, .esp32c3:
            root = nodeAgentRoot()
        case .portalCyd:
            root = portalRootPath()
        case .esp32p4:
            root = p4RootPath()
        }
        let webTools = "\(root)/esp-web-tools"

        var missing: [String] = []

        let manifestPath: String
        switch target {
        case .esp32dev:
            manifestPath = "\(webTools)/manifest.json"
        case .esp32c3:
            manifestPath = "\(webTools)/manifest-esp32c3.json"
        case .portalCyd:
            manifestPath = "\(webTools)/manifest-portal-cyd.json"
        case .esp32p4:
            manifestPath = "\(webTools)/manifest-p4.json"
        }

        if !FileManager.default.fileExists(atPath: manifestPath) {
            missing.append(displayPath(manifestPath))
            return FlashPrepStatus(
                isReady: false,
                missingItems: missing,
                buildCommand: target.buildCommand
            )
        }

        guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let manifestJSON = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            missing.append("invalid manifest json: \(displayPath(manifestPath))")
            return FlashPrepStatus(
                isReady: false,
                missingItems: missing,
                buildCommand: target.buildCommand
            )
        }

        if let metadata = manifestJSON["metadata"] as? [String: Any] {
            if let buildInfoRel = metadata["buildinfo_path"] as? String, !buildInfoRel.isEmpty {
                let buildInfoAbs = "\(webTools)/\(buildInfoRel)"
                if !FileManager.default.fileExists(atPath: buildInfoAbs) {
                    missing.append(displayPath(buildInfoAbs))
                }
            }
            if let shaRel = metadata["sha256sums_path"] as? String, !shaRel.isEmpty {
                let shaAbs = "\(webTools)/\(shaRel)"
                if !FileManager.default.fileExists(atPath: shaAbs) {
                    missing.append(displayPath(shaAbs))
                }
            }
        }

        if let builds = manifestJSON["builds"] as? [[String: Any]], let firstBuild = builds.first {
            if let parts = firstBuild["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let rel = part["path"] as? String, !rel.isEmpty else { continue }
                    let absPath = "\(webTools)/\(rel)"
                    if !FileManager.default.fileExists(atPath: absPath) {
                        missing.append(displayPath(absPath))
                    }
                }
            } else {
                missing.append("manifest parts missing in \(displayPath(manifestPath))")
            }
        } else {
            missing.append("manifest builds missing in \(displayPath(manifestPath))")
        }

        return FlashPrepStatus(
            isReady: missing.isEmpty,
            missingItems: missing,
            buildCommand: target.buildCommand
        )
    }

    private func nodeAgentRoot() -> String {
        nodeAgentRootPath()
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return path.replacingOccurrences(of: home, with: "~")
        }
        return path
    }

    private struct ProcessConfig {
        let executableURL: URL
        let arguments: [String]
        let currentDirectoryURL: URL
    }
}
