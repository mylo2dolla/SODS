import SwiftUI
import UniformTypeIdentifiers
import Foundation
import CoreBluetooth
import Network
import AppKit

struct ContentView: View {
    enum ViewMode: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case interesting = "Cameras/Interesting"
        case allHosts = "All Hosts"
        case ble = "BLE Discovery"
        case spectral = "Spectrum"
        case nodes = "Nodes"
        case buttons = "Buttons"
        case runbooks = "Runbooks"
        case cases = "Cases"
        case vault = "Vault"

        var id: String { rawValue }
    }

    enum HostSortField: String, CaseIterable, Identifiable {
        case ip = "IP"
        case alive = "Alive"
        case hostname = "Hostname"

        var id: String { rawValue }
    }

    enum APIEndpoint: String, CaseIterable, Identifiable {
        case tools = "/api/tools"
        case status = "/api/status"
        case presets = "/api/presets"
        case runbooks = "/api/runbooks"
        case health = "/health"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .tools: return "/api/tools"
            case .status: return "/api/status"
            case .presets: return "/api/presets"
            case .runbooks: return "/api/runbooks"
            case .health: return "/health"
            }
        }
    }


    @StateObject private var scanner = NetworkScanner()
    @StateObject private var logStore = LogStore.shared
    @StateObject private var modalCoordinator = ModalCoordinator()
    @StateObject private var bleScanner = BLEScanner.shared
    @StateObject private var bleProber = BLEProber.shared
    @StateObject private var piAuxStore = PiAuxStore.shared
    @StateObject private var entityStore = EntityStore.shared
    @StateObject private var caseManager = CaseManager.shared
    @StateObject private var sodsStore = SODSStore.shared
    @StateObject private var sessionManager = CaseSessionManager.shared
    @StateObject private var vaultTransport = VaultTransport.shared
    @StateObject private var flashManager = FlashServerManager()
    @StateObject private var toolRegistry = ToolRegistry.shared
    @StateObject private var presetRegistry = PresetRegistry.shared
    @StateObject private var runbookRegistry = RunbookRegistry.shared
    @StateObject private var aliasStore = SODSStore.shared
    @AppStorage("consentAcknowledged") private var consentAcknowledged = false
    @AppStorage("bleFindFingerprintID") private var bleFindFingerprintID = ""

    @State private var onvifDiscoveryEnabled = true
    @State private var serviceDiscoveryEnabled = true
    @State private var selectedIP: String?
    @State private var showLogs = false
    @State private var viewMode: ViewMode = .dashboard
    @State private var searchText = ""
    @State private var hostSortField: HostSortField = .ip
    @State private var hostSortAscending = true
    @State private var showAliveOnly = false
    @State private var showArpOnly = true
    @State private var showHighConfidenceOnly = false
    @State private var arpWarmupEnabled = true
    @State private var bleDiscoveryEnabled = false
    @State private var networkScanMode: ScanMode = .oneShot
    @State private var bleScanMode: ScanMode = .oneShot
    @State private var selectedBleID: UUID?
    @State private var connectNodeID: String = ""
    @State private var showFlashConfirm: Bool = false
    @State private var credentialIP: String?
    @State private var credentialUsername = ""
    @State private var credentialPassword = ""
    @State private var didLogCredentialStorage = false
    @State private var credentialsAutofilled = false
    @State private var rtspOverrideEnabledByIP: [String: Bool] = [:]
    @State private var rtspOverrideValueByIP: [String: String] = [:]
    @State private var showRtspCredentialsPrompt = false
    @State private var rtspPromptIP: String?
    @State private var rtspPromptUsername = ""
    @State private var rtspPromptPassword = ""
    @State private var rtspSessionCreds: [String: (String, String)] = [:]
    private let rtspTrySemaphore = AsyncSemaphore(value: 4)

    @State private var scopeCIDR = ""
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    @State private var onlyLocalSubnet = true
    @AppStorage("inboxRetentionDays") private var inboxRetentionDays = 14
    @AppStorage("inboxMaxGB") private var inboxMaxGB = 10
    @State private var inboxStatus = InboxRetention.shared.currentStatus()
    @State private var bleTableWarning: String?
    @State private var sodsURLText = ""
    @State private var showFlashPopover = false
    @State private var showGodMenu = false

    var body: some View {
        mainContent
            .toolbar { toolbarContent }
            .sheet(item: $modalCoordinator.activeSheet) { sheet in
                switch sheet {
                case .toolRegistry:
                    ToolRegistryView(
                        registry: toolRegistry,
                        baseURL: sodsStore.baseURL,
                        onFlash: { showFlashPopover = true },
                        onInspect: { endpoint in modalCoordinator.present(.apiInspector(endpoint: endpoint)) },
                        onRunTool: { tool in modalCoordinator.present(.toolRunner(tool: tool)) },
                        onRunRunbook: { name in
                            let id = name.replacingOccurrences(of: "runbook.", with: "")
                            if let runbook = runbookRegistry.runbooks.first(where: { $0.id == id }) {
                                modalCoordinator.present(.runbookRunner(runbook: runbook))
                            } else {
                                modalCoordinator.present(.apiInspector(endpoint: .runbooks))
                            }
                        },
                        onBuildTool: { modalCoordinator.present(.toolBuilder) },
                        onBuildPreset: { modalCoordinator.present(.presetBuilder) },
                        onScratchpad: { modalCoordinator.present(.scratchpad) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .apiInspector(let endpoint):
                    APIInspectorView(
                        baseURL: sodsStore.baseURL,
                        endpoint: endpoint,
                        onClose: { modalCoordinator.dismiss() },
                        onBack: { modalCoordinator.present(.toolRegistry) }
                    )
                case .toolRunner(let tool):
                    ToolRunnerView(
                        baseURL: sodsStore.baseURL,
                        tool: tool,
                        onOpenViewer: { url in modalCoordinator.present(.viewer(url: url)) },
                        onClose: { modalCoordinator.dismiss() },
                        onBack: { modalCoordinator.present(.toolRegistry) }
                    )
                case .presetRunner(let preset):
                    PresetRunnerView(
                        preset: preset,
                        baseURL: sodsStore.baseURL,
                        onOpenViewer: { url in modalCoordinator.present(.viewer(url: url)) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .runbookRunner(let runbook):
                    RunbookRunnerView(
                        runbook: runbook,
                        baseURL: sodsStore.baseURL,
                        onOpenViewer: { url in modalCoordinator.present(.viewer(url: url)) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .toolBuilder:
                    ToolBuilderView(
                        baseURL: sodsStore.baseURL,
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .presetBuilder:
                    PresetBuilderView(
                        baseURL: sodsStore.baseURL,
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .scratchpad:
                    ScratchpadView(
                        baseURL: sodsStore.baseURL,
                        onSaveAsTool: { _, _ in modalCoordinator.present(.toolBuilder) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .aliasManager:
                    AliasManagerView(
                        aliases: aliasStore.aliasOverrides,
                        onSave: { id, alias in aliasStore.setAlias(id: id, alias: alias) },
                        onDelete: { id in aliasStore.deleteAlias(id: id) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .findDevice:
                    FindDeviceView(
                        baseURL: sodsStore.baseURL,
                        onBindAlias: { id, alias in aliasStore.setAlias(id: id, alias: alias) },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .consent:
                    ConsentView {
                        consentAcknowledged = true
                        modalCoordinator.dismiss()
                    }
                case .rtspCredentials:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RTSP Credentials (optional)")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Provide credentials to include in RTSP path probes for this session only.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("Username", text: $rtspPromptUsername)
                        SecureField("Password", text: $rtspPromptPassword)
                        HStack {
                            Button("Try Without Credentials") {
                                runRtspTry(with: nil)
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            }
                            Button("Use Credentials") {
                                runRtspTry(with: (rtspPromptUsername, rtspPromptPassword))
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            }
                            Button("Cancel") {
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            }
                        }
                    }
                    .padding(20)
                case .viewer(let url):
                    ViewerSheet(url: url, onClose: { modalCoordinator.dismiss() })
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sodsOpenURLInApp)) { note in
                if let url = note.object as? URL {
                    modalCoordinator.present(.viewer(url: url))
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    statusSection
                    contentSection
                    logSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            if !consentAcknowledged { modalCoordinator.present(.consent) }
            if scopeCIDR.isEmpty, let subnet = IPv4Subnet.active() {
                scopeCIDR = "\(subnet.addressString)/\(subnet.prefixLength)"
            }
            sodsURLText = sodsStore.baseURL
            BLEMetadataStore.shared.reload(log: logStore)
            bleTableWarning = BLEMetadataStore.shared.tableWarning()
            if let warning = bleTableWarning {
                logStore.log(.warn, warning)
            }
            inboxStatus = InboxRetention.shared.currentStatus()
            piAuxStore.refreshLocalNodeHeartbeat()
            IdentityResolver.shared.updateOverrides(sodsStore.aliasOverrides)
            entityStore.ingestHosts(scanner.allHosts)
            entityStore.ingestDevices(scanner.devices)
            entityStore.ingestBLE(bleScanner.peripherals)
            entityStore.ingestNodes(piAuxStore.activeNodes)
            IdentityResolver.shared.updateFromSignals(sodsStore.nodes)
            Task.detached {
                await ArtifactStore.shared.runCleanup(log: logStore)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bleMetadataUpdated)) { _ in
            bleTableWarning = BLEMetadataStore.shared.tableWarning()
        }
        .onChange(of: bleDiscoveryEnabled) { enabled in
            if enabled {
                bleScanner.startScan(mode: bleScanMode)
                updateLocalScanningState()
                if bleScanMode == .oneShot {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        if bleScanMode == .oneShot {
                            bleDiscoveryEnabled = false
                            updateLocalScanningState()
                        }
                    }
                }
            } else {
                bleScanner.stopScan()
                updateLocalScanningState()
            }
        }
        .onChange(of: viewMode) { mode in
            if (mode == .ble || mode == .spectral) && bleDiscoveryEnabled && !bleScanner.isScanning {
                bleScanner.startScan(mode: bleScanMode)
            }
            if mode == .vault {
                inboxStatus = InboxRetention.shared.currentStatus()
            }
            if mode == .cases {
                caseManager.refreshCases()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flashNodeCommand)) { _ in
            viewMode = .nodes
            showFlashConfirm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectNodeCommand)) { _ in
            viewMode = .nodes
            guard !connectNodeID.isEmpty else { return }
            sodsStore.connectNode(connectNodeID)
            piAuxStore.connectNode(connectNodeID)
        }
        .onChange(of: selectedIP) { newValue in
            if let ip = newValue {
                entityStore.select(id: ip, kind: .host)
                loadCredentials(for: ip)
                applyCredentialsToDevice(ip: ip)
                if rtspOverrideValueByIP[ip] == nil {
                    rtspOverrideValueByIP[ip] = AppTruth.shared.bestRTSPURI(ip: ip, scanner: scanner) ?? ""
                }
            } else {
                entityStore.select(id: nil, kind: nil)
            }
        }
        .onChange(of: scanner.devices) { _ in
            entityStore.ingestDevices(scanner.devices)
            refreshAutofillForSelectedIP()
        }
        .onChange(of: scanner.allHosts) { _ in
            entityStore.ingestHosts(scanner.allHosts)
            refreshAutofillForSelectedIP()
        }
        .onChange(of: bleScanner.peripherals) { _ in
            entityStore.ingestBLE(bleScanner.peripherals)
        }
        .onChange(of: piAuxStore.activeNodes) { _ in
            entityStore.ingestNodes(piAuxStore.activeNodes)
        }
        .onChange(of: sodsStore.nodes) { _ in
            IdentityResolver.shared.updateFromSignals(sodsStore.nodes)
        }
        .onChange(of: scanner.isScanning) { _ in
            updateLocalScanningState()
        }
        .onChange(of: bleScanner.isScanning) { _ in
            updateLocalScanningState()
        }
        .onChange(of: selectedBleID) { newValue in
            guard let id = newValue else { return }
            if let peripheral = entityStore.blePeripherals.first(where: { $0.id == id }) {
                entityStore.select(id: peripheral.fingerprintID, kind: .ble)
            }
        }
        
        .onChange(of: showRtspCredentialsPrompt) { show in
            if show { modalCoordinator.present(.rtspCredentials) }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let subnet = scanner.subnetDescription {
            Text("Subnet: \(subnet)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }

        GroupBox("Strange Ops Dev Station") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Base URL")
                        .font(.system(size: 11))
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $sodsURLText)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        sodsStore.updateBaseURL(sodsURLText)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    Button("Inspect API") {
                        modalCoordinator.present(.apiInspector(endpoint: .status))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
                HStack(spacing: 10) {
                    Button("Open Spectrum") { viewMode = .spectral }
                        .buttonStyle(PrimaryActionButtonStyle())
                    Button("God Button") {
                        toolRegistry.reload()
                        runbookRegistry.reload()
                        showGodMenu = true
                    }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .popover(isPresented: $showGodMenu, arrowEdge: .bottom) {
                            ActionMenuView(sections: godButtonSections())
                                .frame(minWidth: 320)
                                .padding(10)
                                .background(Theme.background)
                        }
                    Button("Flash") { showFlashPopover = true }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .popover(isPresented: $showFlashPopover, arrowEdge: .bottom) {
                            FlashPopoverView(
                                status: sodsStore.health,
                                onFlashEsp32: { openFlashPath("/flash/esp32") },
                                onFlashEsp32c3: { openFlashPath("/flash/esp32c3") },
                                onFlashPortalCyd: { openFlashPath("/flash/portal-cyd") },
                                onFlashP4: { openFlashPath("/flash/p4") },
                                onOpenWebTools: { openFlashPath("/flash/") }
                            )
                        }
                    Text(sodsStore.health.label)
                        .font(.system(size: 11))
                        .foregroundColor(Color(sodsStore.health.color))
                    Text("Nodes: \(sodsStore.nodes.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let last = sodsStore.lastPoll {
                        Text("Last ingest: \(last.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(6)
        }

        if let progress = scanner.progress {
            ProgressView(value: Double(progress.scannedHosts), total: Double(progress.totalHosts))
            Text("Scanned \(progress.scannedHosts) of \(progress.totalHosts) hosts")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }

        if let status = scanner.statusMessage {
            Text(status)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }

        if !bleScanner.isAvailableForScan {
            Text(bleAvailabilityMessage())
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if viewMode == .dashboard {
            DashboardView(
                scanner: scanner,
                bleScanner: bleScanner,
                piAuxStore: piAuxStore,
                entityStore: entityStore,
                sodsStore: sodsStore,
                vaultTransport: vaultTransport,
                inboxStatus: inboxStatus,
                retentionDays: inboxRetentionDays,
                retentionMaxGB: inboxMaxGB,
                onvifDiscoveryEnabled: onvifDiscoveryEnabled,
                serviceDiscoveryEnabled: serviceDiscoveryEnabled,
                arpWarmupEnabled: arpWarmupEnabled,
                bleDiscoveryEnabled: bleScanner.isScanning,
                safeModeEnabled: scanner.safeModeEnabled,
                onlyLocalSubnet: onlyLocalSubnet,
                onOpenNodes: {
                    viewMode = .nodes
                },
                onStartScan: {
                    let scope = makeScope()
                    scanner.startScan(enableOnvifDiscovery: onvifDiscoveryEnabled, enableServiceDiscovery: serviceDiscoveryEnabled, enableArpWarmup: arpWarmupEnabled, scope: scope, mode: networkScanMode)
                    piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: true)
                    piAuxStore.refreshLocalNodeHeartbeat()
                },
                onStopScan: {
                    stopAllScanning()
                },
                onGenerateScanReport: {
                    generateScanReport()
                },
                stationActionSections: { dashboardStationSections() },
                scanActionSections: { dashboardScanSections() },
                eventsActionSections: { dashboardEventsSections() },
                vaultActionSections: { dashboardVaultSections() },
                inboxActionSections: { dashboardInboxSections() }
            )
        } else if viewMode == .interesting {
            interestingSection
        } else if viewMode == .allHosts {
            allHostsSection
        } else if viewMode == .ble {
            bleSection
        } else if viewMode == .spectral {
            VisualizerView(store: sodsStore, entityStore: entityStore, onOpenTools: { openSODSTools() })
        } else if viewMode == .nodes {
            NodesView(
                store: piAuxStore,
                sodsStore: sodsStore,
                nodes: entityStore.nodes,
                nodePresence: sodsStore.nodePresence,
                scanner: scanner,
                flashManager: flashManager,
                connectableNodeIDs: connectableNodeIDs(),
                bleIsScanning: bleScanner.isScanning,
                onvifDiscoveryEnabled: $onvifDiscoveryEnabled,
                serviceDiscoveryEnabled: $serviceDiscoveryEnabled,
                arpWarmupEnabled: $arpWarmupEnabled,
                bleDiscoveryEnabled: $bleDiscoveryEnabled,
                safeModeEnabled: $scanner.safeModeEnabled,
                onlyLocalSubnet: $onlyLocalSubnet,
                scopeCIDR: $scopeCIDR,
                rangeStart: $rangeStart,
                rangeEnd: $rangeEnd,
                showLogs: $showLogs,
                networkScanMode: $networkScanMode,
                bleScanMode: $bleScanMode,
                connectNodeID: $connectNodeID,
                showFlashConfirm: $showFlashConfirm,
                onStartScan: {
                    let scope = makeScope()
                    scanner.startScan(enableOnvifDiscovery: onvifDiscoveryEnabled, enableServiceDiscovery: serviceDiscoveryEnabled, enableArpWarmup: arpWarmupEnabled, scope: scope, mode: networkScanMode)
                    piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: true)
                    piAuxStore.refreshLocalNodeHeartbeat()
                },
                onStopScan: {
                    stopAllScanning()
                },
                onGenerateScanReport: {
                    generateScanReport()
                },
                onRevealLatestReport: {
                    if let url = LogStore.latestReadableScanReportURL(log: logStore) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        logStore.log(.warn, "No readable scan report found in ~/SODS/reports/scan-readable/")
                    }
                },
                onFindDevice: { modalCoordinator.present(.findDevice) }
            )
        } else if viewMode == .buttons {
            PresetButtonsView(
                registry: presetRegistry,
                onRunPreset: { preset in modalCoordinator.present(.presetRunner(preset: preset)) },
                onOpenBuilder: { modalCoordinator.present(.presetBuilder) }
            )
        } else if viewMode == .runbooks {
            RunbookListView(
                registry: runbookRegistry,
                onRunbook: { runbook in modalCoordinator.present(.runbookRunner(runbook: runbook)) },
                onInspect: { modalCoordinator.present(.apiInspector(endpoint: .runbooks)) }
            )
        } else if viewMode == .cases {
            CasesView(
                caseManager: caseManager,
                sessionManager: sessionManager,
                piAuxStore: piAuxStore,
                vaultTransport: vaultTransport,
                entityStore: entityStore,
                onRefresh: { caseManager.refreshCases() }
            )
        } else if viewMode == .vault {
            VaultView(
                shipper: vaultTransport,
                inboxStatus: $inboxStatus,
                retentionDays: $inboxRetentionDays,
                retentionMaxGB: $inboxMaxGB,
                onPrune: {
                    pruneInbox()
                },
                onRevealShipper: { NSWorkspace.shared.open(ArtifactStore.stateURL()) },
                onRevealResources: { StoragePaths.revealResourcesFolder() }
            )
        }
    }

    private var interestingSection: some View {
        HStack(spacing: 0) {
            List(selection: $selectedIP) {
                ForEach(sortedDevices) { device in
                    DeviceRow(
                        device: device,
                        status: onvifStatus(for: device),
                        alias: aliasForDevice(ip: device.ip, host: hostForDevice(device), device: device)
                    )
                    .tag(device.ip)
                }
            }
            .frame(minWidth: 360)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                UnifiedDetailView(
                    host: selectedHost,
                    device: selectedDevice,
                    selectedIP: selectedIP,
                    bestHTTPURL: selectedIP.flatMap { bestHTTPURL(for: $0) },
                    bestRTSPURI: selectedIP.flatMap { bestRTSPURI(for: $0) },
                    bestONVIFXAddr: selectedIP.flatMap { bestONVIFXAddr(for: $0) },
                    bestSSDPURL: selectedIP.flatMap { bestSSDPURL(for: $0) },
                    bestPorts: selectedIP.map { AppTruth.shared.bestPorts(ip: $0, scanner: scanner) } ?? [],
                    rtspOverrideEnabled: selectedIP.map { rtspOverrideEnabledBinding(for: $0) },
                    rtspOverrideValue: selectedIP.map { rtspOverrideValueBinding(for: $0) },
                    statusText: selectedDevice.flatMap { onvifStatus(for: $0) },
                    username: selectedDevice.map { _ in credentialBinding("username") },
                    password: selectedDevice.map { _ in credentialBinding("password") },
                    credentialsAutofilled: credentialsAutofilled,
                    isFetching: selectedDevice.map { scanner.onvifFetchInProgress.contains($0.id) } ?? false,
                    safeMode: scanner.safeModeEnabled,
                    showHardProbe: true,
                    onFetch: { device in
                        let safeMode = scanner.safeModeEnabled
                        logStore.log(.info, "Retry RTSP Fetch clicked ip=\(device.ip) safeMode=\(safeMode)")
                        guard !safeMode else {
                            logStore.log(.warn, "Retry RTSP Fetch blocked ip=\(device.ip)")
                            return
                        }
                        scanner.fetchOnvifRtsp(for: device.id, reason: .manual)
                    },
                    onProbeRtsp: { device in
                        let safeMode = scanner.safeModeEnabled
                        logStore.log(.info, "Probe RTSP clicked ip=\(device.ip) safeMode=\(safeMode)")
                        guard !safeMode else {
                            logStore.log(.warn, "Probe RTSP blocked ip=\(device.ip)")
                            return
                        }
                        scanner.probeRtsp(for: device.id)
                    },
                    onHardProbe: { device in
                        let safeMode = scanner.safeModeEnabled
                        let selected = selectedIP ?? device.ip
                        RTSPHardProbe.run(device: device, log: logStore, safeMode: safeMode, selectedIP: selected)
                    },
                    onOpenWeb: { ip in
                        openWebUI(for: ip)
                    },
                    onOpenSSDP: { ip in
                        openSSDP(for: ip)
                    },
                    onExportEvidence: { ip in
                        exportEvidenceJSON(for: ip)
                    },
                    onCopyIP: { ip in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                        logStore.log(.info, "Copied IP \(ip) to clipboard")
                    },
                    onCopyRTSP: { url in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        logStore.log(.info, "Copied RTSP URL for \(url)")
                    },
                    onOpenVLC: { url, ip in
                        openRTSPInVLC(url: url, ip: ip)
                    },
                    onGenerateDeviceReport: { ip in
                        generateDeviceReport(for: ip)
                    },
                    onTryRtspPaths: { ip in
                        if let creds = rtspSessionCreds[ip] {
                            tryRtspPaths(for: ip, credentials: creds)
                        } else {
                            let cached = cachedCredentials(for: ip)
                            rtspPromptIP = ip
                            rtspPromptUsername = cached.0
                            rtspPromptPassword = cached.1
                            showRtspCredentialsPrompt = true
                        }
                    },
                    onPinCase: { ip in
                        caseManager.pinHost(ip: ip, scanner: scanner, log: logStore)
                    },
                    onRevealEvidence: { ip in
                        revealLatestEvidence(for: ip)
                    },
                    onRevealProbeReport: { ip in
                        revealLatestProbeReport(for: ip)
                    },
                    onRevealArtifacts: { ip in
                        revealDeviceArtifacts(for: ip)
                    },
                    onGenerateScanReport: {
                        generateScanReport()
                    },
                    onRevealLatestReport: {
                        revealLatestReport()
                    },
                    onExportAudit: {
                        exportAudit()
                    },
                    onExportRuntimeLog: {
                        exportRuntimeLog()
                    },
                    onRevealExports: {
                        revealExports()
                    },
                    onShipNow: {
                        vaultTransport.shipNow(log: logStore)
                    }
                )
                Spacer()
            }
            .padding(16)
            .frame(minWidth: 420)
        }
        .frame(maxHeight: .infinity)
    }

    private var allHostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search IP or hostname", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Toggle("Show ARP-only", isOn: $showArpOnly)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                Toggle("Show Alive Only", isOn: $showAliveOnly)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                Toggle("Show High Confidence Only", isOn: $showHighConfidenceOnly)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                Spacer()
                Button("Refresh ARP") {
                    scanner.refreshARP()
                }
                Button("Import OUI File...") {
                    OUIStore.shared.importFromOpenPanel(log: logStore)
                }
                Button("Export...") {
                    exportHosts()
                }
                Button("Reveal Exports") {
                    revealExports()
                }
                Picker("Sort", selection: $hostSortField) {
                    ForEach(HostSortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Ascending", isOn: $hostSortAscending)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                Text("Hosts: \(filteredHosts.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 0) {
                HostTable(
                    hosts: filteredHosts,
                    selectedIP: $selectedIP,
                    aliasForHost: { host in aliasForDevice(ip: host.ip, host: host, device: nil) }
                )
                .frame(minWidth: 700)
                Divider()
                UnifiedDetailView(
                    host: selectedHost,
                    device: selectedDevice,
                    selectedIP: selectedIP,
                    bestHTTPURL: selectedIP.flatMap { bestHTTPURL(for: $0) },
                    bestRTSPURI: selectedIP.flatMap { bestRTSPURI(for: $0) },
                    bestONVIFXAddr: selectedIP.flatMap { bestONVIFXAddr(for: $0) },
                    bestSSDPURL: selectedIP.flatMap { bestSSDPURL(for: $0) },
                    bestPorts: selectedIP.map { AppTruth.shared.bestPorts(ip: $0, scanner: scanner) } ?? [],
                    rtspOverrideEnabled: selectedIP.map { rtspOverrideEnabledBinding(for: $0) },
                    rtspOverrideValue: selectedIP.map { rtspOverrideValueBinding(for: $0) },
                    statusText: selectedDevice.flatMap { onvifStatus(for: $0) },
                    username: selectedDevice.map { _ in credentialBinding("username") },
                    password: selectedDevice.map { _ in credentialBinding("password") },
                    credentialsAutofilled: credentialsAutofilled,
                    isFetching: selectedDevice.map { scanner.onvifFetchInProgress.contains($0.id) } ?? false,
                    safeMode: scanner.safeModeEnabled,
                    showHardProbe: false,
                    onFetch: { device in
                        let safeMode = scanner.safeModeEnabled
                        logStore.log(.info, "Retry RTSP Fetch clicked ip=\(device.ip) safeMode=\(safeMode)")
                        guard !safeMode else {
                            logStore.log(.warn, "Retry RTSP Fetch blocked ip=\(device.ip)")
                            return
                        }
                        scanner.fetchOnvifRtsp(for: device.id, reason: .manual)
                    },
                    onProbeRtsp: { device in
                        let safeMode = scanner.safeModeEnabled
                        logStore.log(.info, "Probe RTSP clicked ip=\(device.ip) safeMode=\(safeMode)")
                        guard !safeMode else {
                            logStore.log(.warn, "Probe RTSP blocked ip=\(device.ip)")
                            return
                        }
                        scanner.probeRtsp(for: device.id)
                    },
                    onHardProbe: { device in
                        let safeMode = scanner.safeModeEnabled
                        let selected = selectedIP ?? device.ip
                        RTSPHardProbe.run(device: device, log: logStore, safeMode: safeMode, selectedIP: selected)
                    },
                    onOpenWeb: { ip in
                        openWebUI(for: ip)
                    },
                    onOpenSSDP: { ip in
                        openSSDP(for: ip)
                    },
                    onExportEvidence: { ip in
                        exportEvidenceJSON(for: ip)
                    },
                    onCopyIP: { ip in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                        logStore.log(.info, "Copied IP \(ip) to clipboard")
                    },
                    onCopyRTSP: { url in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        logStore.log(.info, "Copied RTSP URL for \(url)")
                    },
                    onOpenVLC: { url, ip in
                        openRTSPInVLC(url: url, ip: ip)
                    },
                    onGenerateDeviceReport: { ip in
                        generateDeviceReport(for: ip)
                    },
                    onTryRtspPaths: { ip in
                        if let creds = rtspSessionCreds[ip] {
                            tryRtspPaths(for: ip, credentials: creds)
                        } else {
                            let cached = cachedCredentials(for: ip)
                            rtspPromptIP = ip
                            rtspPromptUsername = cached.0
                            rtspPromptPassword = cached.1
                            showRtspCredentialsPrompt = true
                        }
                    },
                    onPinCase: { ip in
                        caseManager.pinHost(ip: ip, scanner: scanner, log: logStore)
                    },
                    onRevealEvidence: { ip in
                        revealLatestEvidence(for: ip)
                    },
                    onRevealProbeReport: { ip in
                        revealLatestProbeReport(for: ip)
                    },
                    onRevealArtifacts: { ip in
                        revealDeviceArtifacts(for: ip)
                    },
                    onGenerateScanReport: {
                        generateScanReport()
                    },
                    onRevealLatestReport: {
                        revealLatestReport()
                    },
                    onExportAudit: {
                        exportAudit()
                    },
                    onExportRuntimeLog: {
                        exportRuntimeLog()
                    },
                    onRevealExports: {
                        revealExports()
                    },
                    onShipNow: {
                        vaultTransport.shipNow(log: logStore)
                    }
                )
                .frame(minWidth: 420)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var bleSection: some View {
        BLEListView(
            scanner: bleScanner,
            prober: bleProber,
            peripherals: entityStore.blePeripherals,
            aliasForPeripheral: { peripheral in
                IdentityResolver.shared.resolveLabel(keys: [peripheral.fingerprintID, peripheral.id.uuidString])
            },
            selectedID: $selectedBleID,
            findFingerprintID: $bleFindFingerprintID,
            warningText: bleTableWarning,
            onGenerateScanReport: { generateScanReport() },
            onRevealLatestReport: { revealLatestReport() },
            onExportAudit: { exportAudit() },
            onExportRuntimeLog: { exportRuntimeLog() },
            onRevealExports: { revealExports() },
            onShipNow: { vaultTransport.shipNow(log: logStore) }
        )
    }

    @ViewBuilder
    private var logSection: some View {
        if showLogs {
            LogPanel(
                logStore: logStore,
                scanner: scanner,
                bleScanner: bleScanner,
                scanToggles: LogScanToggles(
                    onvifDiscovery: onvifDiscoveryEnabled,
                    serviceDiscovery: serviceDiscoveryEnabled,
                    arpWarmup: arpWarmupEnabled,
                    safeMode: scanner.safeModeEnabled,
                    bleDiscovery: bleDiscoveryEnabled
                ),
                onExportAudit: {
                    exportAudit()
                },
                onSelectIP: { ip in
                    selectedIP = ip
                    viewMode = .allHosts
                },
                onSelectBLEFingerprint: { fingerprintID in
                    if let peripheral = entityStore.blePeripherals.first(where: { $0.fingerprintID == fingerprintID }) {
                        selectedBleID = peripheral.id
                        viewMode = .ble
                    } else {
                        logStore.log(.warn, "No BLE device found for fingerprintID=\(fingerprintID)")
                    }
                }
            )
            .frame(minHeight: 160, maxHeight: 220)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("SODS Dev Station")
                .font(.system(size: 16, weight: .semibold))
        }
        ToolbarItemGroup(placement: .automatic) {
            Button("Tools") { openSODSTools() }
                .buttonStyle(SecondaryActionButtonStyle())
            Button("Guide") { modalCoordinator.present(.consent) }
                .buttonStyle(SecondaryActionButtonStyle())
            Button("Aliases") { modalCoordinator.present(.aliasManager) }
                .buttonStyle(SecondaryActionButtonStyle())
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 260, idealWidth: 420, maxWidth: 520)
            .layoutPriority(1)
            Button("Flash") { showFlashPopover = true }
                .buttonStyle(SecondaryActionButtonStyle())
                .popover(isPresented: $showFlashPopover, arrowEdge: .bottom) {
                    FlashPopoverView(
                        status: sodsStore.health,
                        onFlashEsp32: { openFlashPath("/flash/esp32") },
                        onFlashEsp32c3: { openFlashPath("/flash/esp32c3") },
                        onFlashPortalCyd: { openFlashPath("/flash/portal-cyd") },
                        onFlashP4: { openFlashPath("/flash/p4") },
                        onOpenWebTools: { openFlashPath("/flash/") }
                    )
                }
            Text("Scanning: \(scanner.isScanning ? "Yes" : "No")")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Hosts: \(entityStore.hosts.count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("BLE: \(bleScanner.stateDescription)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var selectedDevice: Device? {
        guard let selectedIP = selectedIP else { return nil }
        return AppTruth.shared.resolveDevice(ip: selectedIP, scanner: scanner)
    }

    private var selectedHost: HostEntry? {
        guard let selectedIP = selectedIP else { return nil }
        return AppTruth.shared.resolveHost(ip: selectedIP, scanner: scanner)
    }

    private func hostForDevice(_ device: Device) -> HostEntry? {
        entityStore.hosts.first(where: { $0.ip == device.ip })
    }

    private func credentialsKey(_ ip: String, field: String) -> String {
        "credentials.\(ip).\(field)"
    }

    private func loadCredentials(for ip: String) {
        credentialIP = ip
        credentialUsername = UserDefaults.standard.string(forKey: credentialsKey(ip, field: "username")) ?? ""
        credentialPassword = UserDefaults.standard.string(forKey: credentialsKey(ip, field: "password")) ?? ""
        credentialsAutofilled = !credentialUsername.isEmpty || !credentialPassword.isEmpty
    }

    private func cachedCredentials(for ip: String) -> (String, String) {
        let username = UserDefaults.standard.string(forKey: credentialsKey(ip, field: "username")) ?? ""
        let password = UserDefaults.standard.string(forKey: credentialsKey(ip, field: "password")) ?? ""
        return (username, password)
    }

    private func saveCredentials(for ip: String, username: String, password: String) {
        UserDefaults.standard.set(username, forKey: credentialsKey(ip, field: "username"))
        UserDefaults.standard.set(password, forKey: credentialsKey(ip, field: "password"))
        if !didLogCredentialStorage {
            didLogCredentialStorage = true
            logStore.log(.info, "Credentials stored in UserDefaults (local dev only)")
        }
    }

    private func applyCredentialsToDevice(ip: String) {
        guard let device = scanner.devices.first(where: { $0.ip == ip }) else { return }
        scanner.updateCredentials(for: device.id, username: credentialUsername, password: credentialPassword)
    }

    private func aliasForDevice(ip: String, host: HostEntry?, device: Device?) -> String? {
        let keys = [
            ip,
            host?.macAddress ?? "",
            device?.macAddress ?? "",
            host?.hostname ?? "",
            device?.httpTitle ?? ""
        ]
        if let resolved = IdentityResolver.shared.resolveLabel(keys: keys) {
            return resolved
        }
        if let hostname = host?.hostname, !hostname.isEmpty { return hostname }
        return nil
    }

    private func buildAliasMap(for snapshot: ExportSnapshot) -> [String: String] {
        var out: [String: String] = IdentityResolver.shared.aliasMap()
        for record in snapshot.records {
            if out[record.ip] == nil, !record.hostname.isEmpty {
                out[record.ip] = record.hostname
            }
        }
        return out
    }

    private func credentialBinding(_ field: String) -> Binding<String> {
        Binding(
            get: {
                field == "username" ? credentialUsername : credentialPassword
            },
            set: { newValue in
                if field == "username" {
                    credentialUsername = newValue
                } else {
                    credentialPassword = newValue
                }
                credentialsAutofilled = false
                guard let ip = credentialIP ?? selectedIP else { return }
                saveCredentials(for: ip, username: credentialUsername, password: credentialPassword)
                applyCredentialsToDevice(ip: ip)
            }
        )
    }

    private func bestRTSPURI(for ip: String) -> String? {
        if rtspOverrideEnabledByIP[ip] == true {
            let override = rtspOverrideValueByIP[ip] ?? ""
            return override.isEmpty ? nil : override
        }
        return AppTruth.shared.bestRTSPURI(ip: ip, scanner: scanner)
    }

    private func bestHTTPURL(for ip: String) -> URL? {
        AppTruth.shared.bestHTTPURL(ip: ip, scanner: scanner)
    }

    private func openSODSSpectrum() {
        viewMode = .spectral
    }

    private func openSODSTools() {
        toolRegistry.reload()
        modalCoordinator.present(.toolRegistry)
    }

    private func updateLocalScanningState() {
        let scanning = scanner.isScanning || bleScanner.isScanning
        piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: scanning)
    }

    private func stopAllScanning() {
        scanner.stopScan()
        if bleDiscoveryEnabled {
            bleDiscoveryEnabled = false
        }
        if bleScanner.isScanning {
            bleScanner.stopScan()
        }
        updateLocalScanningState()
        piAuxStore.refreshLocalNodeHeartbeat()
    }

    private func connectableNodeIDs() -> [String] {
        var ids: Set<String> = []
        for node in piAuxStore.activeNodes {
            ids.insert(node.id)
        }
        return ids.sorted()
    }

    private func godButtonSections() -> [ActionMenuSection] {
        let isBleTab = viewMode == .ble
        let isNodesTab = viewMode == .nodes
        let nowItems: [ActionMenuItem] = {
            var items: [ActionMenuItem] = []
            if isBleTab {
                items.append(ActionMenuItem(
                    title: bleDiscoveryEnabled ? "Stop BLE Scan" : "Start BLE Scan",
                    systemImage: "antenna.radiowaves.left.and.right",
                    enabled: true,
                    reason: nil,
                    action: { bleDiscoveryEnabled.toggle() }
                ))
                items.append(ActionMenuItem(
                    title: "One-shot BLE Scan",
                    systemImage: "scope",
                    enabled: true,
                    reason: nil,
                    action: {
                        bleScanMode = .oneShot
                        bleDiscoveryEnabled = true
                    }
                ))
            }
            if isNodesTab {
                items.append(ActionMenuItem(
                    title: "Connect Node",
                    systemImage: "link",
                    enabled: true,
                    reason: nil,
                    action: {
                        let target = !connectNodeID.isEmpty ? connectNodeID : (self.connectableNodeIDs().first ?? "")
                        guard !target.isEmpty else { return }
                        connectNodeID = target
                        sodsStore.connectNode(target)
                        piAuxStore.connectNode(target)
                        if !bleDiscoveryEnabled { bleDiscoveryEnabled = true }
                    }
                ))
                items.append(ActionMenuItem(
                    title: scanner.isScanning ? "Stop Network Scan" : "Start Network Scan",
                    systemImage: "dot.radiowaves.left.and.right",
                    enabled: true,
                    reason: nil,
                    action: {
                        if scanner.isScanning {
                            scanner.stopScan()
                        } else {
                            let scope = makeScope()
                            scanner.startScan(enableOnvifDiscovery: onvifDiscoveryEnabled, enableServiceDiscovery: serviceDiscoveryEnabled, enableArpWarmup: arpWarmupEnabled, scope: scope, mode: networkScanMode)
                            piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: true)
                        }
                    }
                ))
            }
            for runbook in runbookRegistry.runbooks where (runbook.ui?.capsule ?? false) {
                items.append(ActionMenuItem(
                    title: runbook.name,
                    systemImage: "bolt",
                    enabled: true,
                    reason: nil,
                    action: { modalCoordinator.present(.runbookRunner(runbook: runbook)) }
                ))
            }
            return items
        }()

        let inspectItems: [ActionMenuItem] = stationInspectItems()

        let connectItems: [ActionMenuItem] = [
            ActionMenuItem(title: "Connect Node", systemImage: "link", enabled: true, reason: nil, action: {
                let target = !connectNodeID.isEmpty ? connectNodeID : (self.connectableNodeIDs().first ?? "")
                guard !target.isEmpty else { return }
                connectNodeID = target
                sodsStore.connectNode(target)
                piAuxStore.connectNode(target)
            })
        ]

        let flashItems: [ActionMenuItem] = [
            ActionMenuItem(title: "Find Newly Flashed Device", systemImage: "magnifyingglass", enabled: true, reason: nil, action: {
                modalCoordinator.present(.findDevice)
            })
        ]

        let exportItems: [ActionMenuItem] = exportMenuItems()

        var sections: [ActionMenuSection] = []
        if !nowItems.isEmpty { sections.append(ActionMenuSection(title: "Now", items: nowItems)) }
        let toolItems = toolRegistry.tools.map { tool in
            ActionMenuItem(
                title: tool.name,
                systemImage: "wrench.and.screwdriver",
                enabled: true,
                reason: nil,
                action: { modalCoordinator.present(.toolRunner(tool: tool)) }
            )
        }
        if !toolItems.isEmpty {
            sections.append(ActionMenuSection(title: "Tools", items: toolItems))
        }
        let runbookItems = runbookRegistry.runbooks.map { runbook in
            ActionMenuItem(
                title: runbook.name,
                systemImage: "bolt",
                enabled: true,
                reason: nil,
                action: { modalCoordinator.present(.runbookRunner(runbook: runbook)) }
            )
        }
        if !runbookItems.isEmpty {
            sections.append(ActionMenuSection(title: "Runbooks", items: runbookItems))
        }
        sections.append(ActionMenuSection(title: "Inspect", items: inspectItems))
        sections.append(ActionMenuSection(title: "Connect / Control", items: connectItems))
        sections.append(ActionMenuSection(title: "Flash / Bind", items: flashItems))
        sections.append(ActionMenuSection(title: "Export / Ship", items: exportItems))
        if FeatureFlags.shared.showDevActions {
            let devItems: [ActionMenuItem] = [
                ActionMenuItem(title: "Tool Builder", systemImage: "hammer", enabled: true, reason: nil, action: { modalCoordinator.present(.toolBuilder) }),
                ActionMenuItem(title: "Preset Builder", systemImage: "slider.horizontal.3", enabled: true, reason: nil, action: { modalCoordinator.present(.presetBuilder) }),
                ActionMenuItem(title: "Scratchpad", systemImage: "terminal", enabled: true, reason: nil, action: { modalCoordinator.present(.scratchpad) })
            ]
            sections.append(ActionMenuSection(title: "Advanced", items: devItems))
        }
        return sections
    }

    private func stationInspectItems() -> [ActionMenuItem] {
        [
            ActionMenuItem(title: "Open Tools", systemImage: "wrench", enabled: true, reason: nil, action: { modalCoordinator.present(.toolRegistry) }),
            ActionMenuItem(title: "Inspect Station", systemImage: "info.circle", enabled: true, reason: nil, action: { modalCoordinator.present(.apiInspector(endpoint: .status)) }),
            ActionMenuItem(title: "Inspect Tools JSON", systemImage: "doc.text", enabled: true, reason: nil, action: { modalCoordinator.present(.apiInspector(endpoint: .tools)) }),
            ActionMenuItem(title: "Open Web UI", systemImage: "globe", enabled: true, reason: nil, action: { if let ip = selectedIP { openWebUI(for: ip) } })
        ]
    }

    private func exportMenuItems() -> [ActionMenuItem] {
        [
            ActionMenuItem(title: "Generate Scan Report", systemImage: "doc.badge.plus", enabled: true, reason: nil, action: { generateScanReport() }),
            ActionMenuItem(title: "Reveal Latest Report", systemImage: "folder", enabled: true, reason: nil, action: { revealLatestReport() }),
            ActionMenuItem(title: "Export Audit", systemImage: "tray.and.arrow.down", enabled: true, reason: nil, action: { exportAudit() }),
            ActionMenuItem(title: "Export Runtime Log", systemImage: "doc.plaintext", enabled: true, reason: nil, action: { exportRuntimeLog() }),
            ActionMenuItem(title: "Reveal Exports", systemImage: "folder.fill", enabled: true, reason: nil, action: { revealExports() }),
            ActionMenuItem(title: "Ship Now", systemImage: "paperplane", enabled: true, reason: nil, action: { vaultTransport.shipNow(log: logStore) })
        ]
    }

    private func scanControlItems() -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        items.append(ActionMenuItem(
            title: bleDiscoveryEnabled ? "Stop BLE Scan" : "Start BLE Scan",
            systemImage: "antenna.radiowaves.left.and.right",
            enabled: true,
            reason: nil,
            action: { bleDiscoveryEnabled.toggle() }
        ))
        items.append(ActionMenuItem(
            title: "One-shot BLE Scan",
            systemImage: "scope",
            enabled: true,
            reason: nil,
            action: {
                bleScanMode = .oneShot
                if !bleDiscoveryEnabled { bleDiscoveryEnabled = true }
            }
        ))
        items.append(ActionMenuItem(
            title: scanner.isScanning ? "Stop Network Scan" : "Start Network Scan",
            systemImage: "dot.radiowaves.left.and.right",
            enabled: true,
            reason: nil,
            action: {
                if scanner.isScanning {
                    scanner.stopScan()
                } else {
                    let scope = makeScope()
                    scanner.startScan(enableOnvifDiscovery: onvifDiscoveryEnabled, enableServiceDiscovery: serviceDiscoveryEnabled, enableArpWarmup: arpWarmupEnabled, scope: scope, mode: networkScanMode)
                    piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: true)
                }
            }
        ))
        return items
    }

    private func dashboardStationSections() -> [ActionMenuSection] {
        let items = stationInspectItems()
        return items.isEmpty ? [] : [ActionMenuSection(title: "Inspect", items: items)]
    }

    private func dashboardScanSections() -> [ActionMenuSection] {
        let items = scanControlItems()
        return items.isEmpty ? [] : [ActionMenuSection(title: "Scan", items: items)]
    }

    private func dashboardEventsSections() -> [ActionMenuSection] {
        let items = exportMenuItems()
        return items.isEmpty ? [] : [ActionMenuSection(title: "Reports", items: items)]
    }

    private func dashboardVaultSections() -> [ActionMenuSection] {
        let items: [ActionMenuItem] = [
            ActionMenuItem(title: "Ship Now", systemImage: "paperplane", enabled: true, reason: nil, action: { vaultTransport.shipNow(log: logStore) }),
            ActionMenuItem(title: "Reveal Exports", systemImage: "folder.fill", enabled: true, reason: nil, action: { revealExports() })
        ]
        return [ActionMenuSection(title: "Vault", items: items)]
    }

    private func dashboardInboxSections() -> [ActionMenuSection] {
        let items: [ActionMenuItem] = [
            ActionMenuItem(title: "Run Cleanup", systemImage: "trash", enabled: true, reason: nil, action: { pruneInbox() }),
            ActionMenuItem(title: "Reveal Resources", systemImage: "folder", enabled: true, reason: nil, action: { StoragePaths.revealResourcesFolder() })
        ]
        return [ActionMenuSection(title: "Inbox", items: items)]
    }

    private func pruneInbox() {
        Task.detached {
            await ArtifactStore.shared.runCleanup(log: logStore)
            await MainActor.run {
                inboxStatus = InboxRetention.shared.currentStatus()
            }
        }
    }

    private func openFlashPath(_ path: String) {
        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        StationProcessManager.shared.ensureRunning(baseURL: base)
        Task {
            if await waitForStation(baseURL: base, timeout: 6.0) {
                if let url = URL(string: base + path) {
                    NSWorkspace.shared.open(url)
                }
            } else if let url = URL(string: base + path) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func waitForStation(baseURL: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await pingStatus(baseURL: baseURL) { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    private func pingStatus(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/api/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
        } catch {
            return false
        }
        return false
    }

    private func bestONVIFXAddr(for ip: String) -> String? {
        AppTruth.shared.bestONVIFXAddr(ip: ip, scanner: scanner)
    }

    private func bestSSDPURL(for ip: String) -> String? {
        let bundle = AppTruth.shared.resolveEvidence(ip: ip, scanner: scanner)
        if let host = bundle.host, let location = host.ssdpLocation, !location.isEmpty {
            return location
        }
        if let record = bundle.exportRecord, !record.ssdpLocation.isEmpty {
            return record.ssdpLocation
        }
        if let audit = bundle.auditEvidence, !audit.ssdpLocation.isEmpty {
            return audit.ssdpLocation
        }
        return nil
    }

    private func bestVendor(for ip: String) -> String {
        AppTruth.shared.bestVendor(ip: ip, scanner: scanner) ?? "Unknown"
    }

    private func rtspOverrideEnabledBinding(for ip: String) -> Binding<Bool> {
        Binding(
            get: { rtspOverrideEnabledByIP[ip] ?? false },
            set: { newValue in
                rtspOverrideEnabledByIP[ip] = newValue
                if newValue, (rtspOverrideValueByIP[ip] ?? "").isEmpty {
                    rtspOverrideValueByIP[ip] = AppTruth.shared.bestRTSPURI(ip: ip, scanner: scanner) ?? ""
                }
            }
        )
    }

    private func rtspOverrideValueBinding(for ip: String) -> Binding<String> {
        Binding(
            get: { rtspOverrideValueByIP[ip] ?? "" },
            set: { newValue in
                rtspOverrideValueByIP[ip] = newValue
            }
        )
    }

    private func refreshAutofillForSelectedIP() {
        guard let ip = selectedIP else { return }
        if rtspOverrideEnabledByIP[ip] != true, (rtspOverrideValueByIP[ip] ?? "").isEmpty {
            if let best = AppTruth.shared.bestRTSPURI(ip: ip, scanner: scanner) {
                rtspOverrideValueByIP[ip] = best
            }
        }
    }

    private func makeScope() -> ScanScope {
        let cidr = scopeCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = rangeStart.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = rangeEnd.trimmingCharacters(in: .whitespacesAndNewlines)
        let range: ScanScope.Range?
        if !start.isEmpty && !end.isEmpty {
            range = ScanScope.Range(start: start, end: end)
        } else {
            range = nil
        }
        return ScanScope(cidr: cidr.isEmpty ? (IPv4Subnet.active().map { "\($0.addressString)/\($0.prefixLength)" } ?? "") : cidr, ipRange: range, onlyLocalSubnet: onlyLocalSubnet)
    }

    private var filteredHosts: [HostEntry] {
        var hosts = entityStore.hosts
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            hosts = hosts.filter { host in
                host.ip.lowercased().contains(query) || (host.hostname?.lowercased().contains(query) ?? false)
            }
        }
        if showAliveOnly {
            hosts = hosts.filter { $0.isAlive }
        }
        if showHighConfidenceOnly {
            hosts = hosts.filter { $0.hostConfidence.level == .high }
        }
        if !showArpOnly {
            hosts = hosts.filter { !($0.macAddress != nil && $0.openPorts.isEmpty) }
        }
        return sortHosts(hosts)
    }

    private var sortedDevices: [Device] {
        entityStore.devices.sorted {
            if $0.hostConfidence.score == $1.hostConfidence.score {
                return $0.ip < $1.ip
            }
            return $0.hostConfidence.score > $1.hostConfidence.score
        }
    }

    private func sortHosts(_ hosts: [HostEntry]) -> [HostEntry] {
        let sorted: [HostEntry]
        switch hostSortField {
        case .ip:
            sorted = hosts.sorted { $0.ipNumeric < $1.ipNumeric }
        case .alive:
            sorted = hosts.sorted { ($0.isAlive ? 1 : 0) < ($1.isAlive ? 1 : 0) }
        case .hostname:
            sorted = hosts.sorted { ($0.hostname ?? "") < ($1.hostname ?? "") }
        }
        return hostSortAscending ? sorted : Array(sorted.reversed())
    }

    private func openWebUI(for ip: String) {
        guard let url = bestHTTPURL(for: ip) else {
            logStore.log(.warn, "Open Web UI blocked: no HTTP URL for \(ip)")
            return
        }
        logStore.log(.info, "Open Web UI: ip=\(ip) url=\(url.absoluteString)")
        openInAppURL(url)
    }

    private func openSSDP(for ip: String) {
        guard let location = bestSSDPURL(for: ip), let url = URL(string: location) else {
            logStore.log(.warn, "Open SSDP blocked: no SSDP location for \(ip)")
            return
        }
        logStore.log(.info, "Open SSDP Location: ip=\(ip) url=\(url.absoluteString)")
        openInAppURL(url)
    }

    private func openInAppURL(_ url: URL) {
        modalCoordinator.present(.viewer(url: url))
    }

    private func generateDeviceReport(for ip: String) {
        let host = AppTruth.shared.resolveHost(ip: ip, scanner: scanner)
        let device = AppTruth.shared.resolveDevice(ip: ip, scanner: scanner)
        guard host != nil || device != nil else {
            logStore.log(.warn, "No host/device available for report \(ip)")
            return
        }
        logStore.log(.info, "Generate Device Report: ip=\(ip)")
        let alias = aliasForDevice(ip: ip, host: host, device: device)

        struct DeviceReportRaw: Codable {
            let generatedAt: String
            let hostEvidence: EvidencePayload?
            let device: DevicePayload?
            let alias: String?
        }
        struct DevicePayload: Codable {
            let ip: String
            let alias: String?
            let openPorts: [Int]
            let httpTitle: String?
            let macAddress: String?
            let vendor: String?
            let hostConfidence: HostConfidence
            let vendorConfidenceScore: Int
            let vendorConfidenceReasons: [String]
            let discoveredViaOnvif: Bool
            let onvifXAddrs: [String]
            let onvifTypes: String?
            let onvifScopes: String?
            let onvifRtspURI: String?
            let onvifRequiresAuth: Bool
            let onvifLastError: String?
            let bestRtspURI: String?
            let lastRtspProbeSummary: String?
        }
        struct DeviceReportReadable: Codable {
            struct Meta: Codable {
                let isoTimestamp: String
                let hostIP: String
                let rawRef: String
            }
            struct Confidence: Codable {
                let level: String
                let score: Int
                let reasons: [String]
            }
            struct EvidenceItem: Codable {
                let label: String
                let rawField: String
                let rawValue: String
                let meaning: String
            }
            struct IdentityMapping: Codable {
                let label: String
                let rawField: String
                let rawValue: String
                let friendly: String
            }
            let meta: Meta
            let summary: String
            let clientSummary: String
            let classification: String
            let confidence: Confidence
            let evidence: [EvidenceItem]
            let identityMapping: [IdentityMapping]
            let howToAccess: [String]
            let failures: [String]
            let technicalAppendix: [String]
        }

        let evidencePayload = host.map(buildEvidencePayload)
        let devicePayload = device.map {
            DevicePayload(
                ip: $0.ip,
                alias: alias,
                openPorts: $0.openPorts,
                httpTitle: $0.httpTitle,
                macAddress: $0.macAddress,
                vendor: $0.vendor,
                hostConfidence: $0.hostConfidence,
                vendorConfidenceScore: $0.vendorConfidenceScore,
                vendorConfidenceReasons: $0.vendorConfidenceReasons,
                discoveredViaOnvif: $0.discoveredViaOnvif,
                onvifXAddrs: $0.onvifXAddrs,
                onvifTypes: $0.onvifTypes,
                onvifScopes: $0.onvifScopes,
                onvifRtspURI: $0.onvifRtspURI,
                onvifRequiresAuth: $0.onvifRequiresAuth,
                onvifLastError: $0.onvifLastError,
                bestRtspURI: $0.bestRtspURI,
                lastRtspProbeSummary: $0.lastRtspProbeSummary
            )
        }

        let iso = LogStore.isoTimestamp()
        let safeIP = LogStore.sanitizeFilename(ip)
        let rawFilename = "SODS-DeviceReportRaw-\(safeIP)-\(iso).json"
        let rawURL = LogStore.exportURL(subdir: "device-report-raw", filename: rawFilename, log: logStore)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let raw = DeviceReportRaw(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                hostEvidence: evidencePayload,
                device: devicePayload,
                alias: alias
            )
            let rawData = try encoder.encode(raw)
            _ = LogStore.writeDataReturning(rawData, to: rawURL, log: logStore)

            let hostConfidence = host?.hostConfidence ?? device?.hostConfidence
            let confidence = DeviceReportReadable.Confidence(
                level: hostConfidence?.level.rawValue ?? "Unknown",
                score: hostConfidence?.score ?? 0,
                reasons: hostConfidence?.reasons ?? []
            )
            let classification = device?.isCameraLikely == true ? "Likely camera/streaming device" : "General network host"
            let summary = "Report for \(ip). \(classification)."
            let clientSummary = "Device \(ip) is assessed as \(classification.lowercased()) with confidence \(confidence.score)."

            var evidenceItems: [DeviceReportReadable.EvidenceItem] = []
            if let alias, !alias.isEmpty {
                evidenceItems.append(.init(label: "Alias", rawField: "alias", rawValue: alias, meaning: "User or inferred alias for this device."))
            }
            if let host {
                let ports = host.openPorts.sorted().map(String.init).joined(separator: ", ")
                let portHints = portHintsText(for: host.openPorts).joined(separator: "; ")
                evidenceItems.append(.init(label: "Open Ports", rawField: "hostEvidence.openPorts", rawValue: ports, meaning: portHints))
                evidenceItems.append(.init(label: "HTTP Status", rawField: "hostEvidence.httpStatus", rawValue: host.httpStatus.map(String.init) ?? "", meaning: httpStatusMeaning(host.httpStatus)))
                evidenceItems.append(.init(label: "HTTP Server", rawField: "hostEvidence.httpServer", rawValue: host.httpServer ?? "", meaning: host.httpServer == nil ? "No server header observed." : "Server header reported by device."))
                evidenceItems.append(.init(label: "HTTP Title", rawField: "hostEvidence.httpTitle", rawValue: host.httpTitle ?? "", meaning: host.httpTitle == nil ? "No title observed." : "Web UI title hint."))
                if let ssdp = host.ssdpServer ?? host.ssdpST ?? host.ssdpUSN {
                    evidenceItems.append(.init(label: "SSDP Summary", rawField: "hostEvidence.ssdp*", rawValue: ssdp, meaning: "UPnP/SSDP discovery response."))
                }
                if !host.bonjourServices.isEmpty {
                    let joined = host.bonjourServices.map { "\($0.name) \($0.type)" }.joined(separator: ", ")
                    evidenceItems.append(.init(label: "Bonjour Services", rawField: "hostEvidence.bonjourServices", rawValue: joined, meaning: "mDNS/Bonjour services announced by device."))
                }
            }
            if let device {
                if !device.onvifXAddrs.isEmpty {
                    evidenceItems.append(.init(label: "ONVIF XAddrs", rawField: "device.onvifXAddrs", rawValue: device.onvifXAddrs.joined(separator: " "), meaning: "ONVIF service endpoints."))
                } else if device.discoveredViaOnvif {
                    evidenceItems.append(.init(label: "ONVIF Discovery", rawField: "device.discoveredViaOnvif", rawValue: "true", meaning: "ONVIF discovery response observed."))
                }
                if let rtsp = bestRTSPURI(for: ip) {
                    evidenceItems.append(.init(label: "RTSP URI", rawField: "device.bestRtspURI", rawValue: rtsp, meaning: "Stream URI from probe/ONVIF."))
                }
            }

            var identityMappings: [DeviceReportReadable.IdentityMapping] = []
            if let alias, !alias.isEmpty {
                identityMappings.append(.init(label: "Alias", rawField: "alias", rawValue: alias, friendly: alias))
            }
            if let host {
                let hostnameRaw = host.hostname ?? "Unknown"
                let vendorRaw = bestVendor(for: host.ip)
                identityMappings.append(.init(label: "Hostname", rawField: "hostEvidence.hostname", rawValue: hostnameRaw, friendly: hostnameRaw))
                identityMappings.append(.init(label: "Vendor", rawField: "hostEvidence.vendor", rawValue: vendorRaw, friendly: vendorRaw))
                let portLabels = portLabelsString(host.openPorts)
                if !portLabels.isEmpty {
                    identityMappings.append(.init(label: "Port Labels", rawField: "hostEvidence.openPorts", rawValue: host.openPorts.map(String.init).joined(separator: ", "), friendly: portLabels))
                } else {
                    identityMappings.append(.init(label: "Port Labels", rawField: "hostEvidence.openPorts", rawValue: host.openPorts.map(String.init).joined(separator: ", "), friendly: "Unknown"))
                }
            }
            if host == nil {
                identityMappings.append(.init(label: "Hostname", rawField: "hostEvidence.hostname", rawValue: "Unknown", friendly: "Unknown"))
                identityMappings.append(.init(label: "Vendor", rawField: "hostEvidence.vendor", rawValue: "Unknown", friendly: "Unknown"))
                identityMappings.append(.init(label: "Port Labels", rawField: "hostEvidence.openPorts", rawValue: "", friendly: "Unknown"))
            }

            let appendix: [String] = [
                "Raw reference: \(rawFilename)",
                "Alias: \(alias ?? "Unknown")",
                "Open ports (raw): \(host?.openPorts.sorted().map(String.init).joined(separator: ", ") ?? "")",
                "Open ports (friendly): \(portLabelsString(host?.openPorts ?? []))",
                "SSDP Server (raw): \(host?.ssdpServer ?? "Unknown")",
                "SSDP Location (raw): \(host?.ssdpLocation ?? "Unknown")",
                "ONVIF XAddrs (raw): \(device?.onvifXAddrs.joined(separator: " ") ?? "Unknown")"
            ]
            let accessLines: [String] = [
                "HTTP: \(bestHTTPURL(for: ip)?.absoluteString ?? "Unknown")",
                "RTSP: \(bestRTSPURI(for: ip) ?? "Unknown")",
                "ONVIF XAddr: \(bestONVIFXAddr(for: ip) ?? "Unknown")",
                "SSDP Location: \(bestSSDPURL(for: ip) ?? "Unknown")"
            ]
            var failures: [String] = []
            if let error = device?.onvifLastError, !error.isEmpty {
                failures.append("ONVIF error: \(error)")
            }
            if (device?.onvifRequiresAuth ?? false) && device?.onvifRtspURI == nil {
                failures.append("RTSP fetch requires authentication.")
            }
            if failures.isEmpty {
                failures.append("No failures recorded.")
            }

            let readable = DeviceReportReadable(
                meta: .init(isoTimestamp: iso, hostIP: ip, rawRef: rawFilename),
                summary: summary,
                clientSummary: clientSummary,
                classification: classification,
                confidence: confidence,
                evidence: evidenceItems,
                identityMapping: identityMappings,
                howToAccess: accessLines,
                failures: failures,
                technicalAppendix: appendix
            )
            let readableData = try encoder.encode(readable)
            let readableFilename = "SODS-DeviceReportReadable-\(safeIP)-\(iso).json"
            let readableURL = LogStore.exportURL(subdir: "device-report-readable", filename: readableFilename, log: logStore)
            _ = LogStore.writeDataReturning(readableData, to: readableURL, log: logStore)
            logStore.log(.info, "Device report generated for \(ip) classification=\(classification) confidence=\(confidence.score)")
            BLEMetadataStore.shared.logStats(log: logStore)
        } catch {
            logStore.log(.error, "Failed to generate device report: \(error.localizedDescription)")
        }
    }

    private func generateScanReport() {
        guard let snapshot = scanner.buildExportSnapshot() else {
            logStore.log(.warn, "No scan snapshot available for scan report")
            return
        }
        AppTruth.shared.lastExportSnapshot = snapshot
        let bleEvidence = bleScanner.snapshotEvidence()
        let piAuxEvidence = PiAuxStore.shared.events
        let aliasMap = buildAliasMap(for: snapshot)
        struct ScanReportRaw: Codable {
            let generatedAt: String
            let snapshot: ExportSnapshot
            let bleEvidence: [BLEEvidence]
            let piAuxEvidence: [PiAuxEvent]
            let aliases: [String: String]
        }
        struct ScanReportReadable: Codable {
            struct Meta: Codable {
                let isoTimestamp: String
                let rawRef: String
            }
            struct Summary: Codable {
                let totalHosts: Int
                let highConfidence: Int
                let mediumConfidence: Int
                let lowConfidence: Int
                let topHosts: [String]
                let bleDevices: Int
            }
            struct EvidenceItem: Codable {
                let label: String
                let rawField: String
                let rawValue: String
                let meaning: String
            }
            struct ConfidenceItem: Codable {
                let ip: String
                let level: String
                let score: Int
                let reasons: [String]
            }
            struct IdentityMapping: Codable {
                let label: String
                let rawField: String
                let rawValue: String
                let friendly: String
            }
            let meta: Meta
            let summary: Summary
            let summaryText: String
            let clientSummary: String
            let classification: String
            let evidence: [EvidenceItem]
            let topConfidence: [ConfidenceItem]
            let identityMapping: [IdentityMapping]
            let technicalAppendix: [String]
            let aliases: [String: String]
        }

        let iso = LogStore.isoTimestamp()
        let rawFilename = "SODS-ScanReportRaw-\(iso).json"
        let rawURL = LogStore.exportURL(subdir: "scan-report-raw", filename: rawFilename, log: logStore)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let raw = ScanReportRaw(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                snapshot: snapshot,
                bleEvidence: bleEvidence,
                piAuxEvidence: piAuxEvidence,
                aliases: aliasMap
            )
            let rawData = try encoder.encode(raw)
            _ = LogStore.writeDataReturning(rawData, to: rawURL, log: logStore)

            let high = snapshot.records.filter { $0.hostConfidence.level == .high }.count
            let medium = snapshot.records.filter { $0.hostConfidence.level == .medium }.count
            let low = snapshot.records.filter { $0.hostConfidence.level == .low }.count
            let topHosts = snapshot.records
                .sorted { $0.hostConfidence.score > $1.hostConfidence.score }
                .prefix(5)
                .map { "\($0.ip) (\($0.hostConfidence.score))" }
            let summaryText = "Scan report for \(snapshot.records.count) hosts with \(high) high-confidence candidates and \(bleEvidence.count) BLE devices."
            let clientSummary = "Inventory summary: \(snapshot.records.count) hosts scanned, \(high) high-confidence items, \(bleEvidence.count) BLE devices. Pi-Aux evidence present: \(piAuxEvidence.count)."
            let evidenceItems: [ScanReportReadable.EvidenceItem] = [
                .init(label: "Open Ports", rawField: "records[].openPorts", rawValue: "see raw", meaning: "Open TCP ports observed per host."),
                .init(label: "HTTP Fingerprint", rawField: "records[].http*", rawValue: "see raw", meaning: "HTTP status, server, auth, and title hints."),
                .init(label: "SSDP Evidence", rawField: "records[].ssdp*", rawValue: "see raw", meaning: "UPnP/SSDP discovery responses."),
                .init(label: "Bonjour Services", rawField: "records[].bonjourServices", rawValue: "see raw", meaning: "mDNS/Bonjour services announced."),
                .init(label: "ONVIF Evidence", rawField: "records[].onvif*", rawValue: "see raw", meaning: "ONVIF discovery and RTSP details."),
                .init(label: "BLE Devices", rawField: "bleEvidence[]", rawValue: "see raw", meaning: "Nearby BLE inventory snapshot."),
                .init(label: "Pi-Aux Evidence", rawField: "piAuxEvidence[]", rawValue: "see raw", meaning: "Local Pi-Aux sensor evidence."),
                .init(label: "Aliases", rawField: "aliases", rawValue: "see raw", meaning: "User-friendly identity map for devices.")
            ]
            let topConfidence = snapshot.records
                .sorted { $0.hostConfidence.score > $1.hostConfidence.score }
                .prefix(5)
                .map { record in
                    ScanReportReadable.ConfidenceItem(
                        ip: record.ip,
                        level: record.hostConfidence.level.rawValue,
                        score: record.hostConfidence.score,
                        reasons: record.hostConfidence.reasons
                    )
                }
            let identityMappings: [ScanReportReadable.IdentityMapping] = [
                .init(label: "Port Labels", rawField: "records[].openPorts", rawValue: "ports", friendly: "80 HTTP, 443 HTTPS, 554 RTSP, 3702 ONVIF, 1900 SSDP, 5353 mDNS"),
                .init(label: "BLE Company IDs", rawField: "bleEvidence[].manufacturerDataHex", rawValue: "see raw", friendly: "Company names from local mapping tables."),
                .init(label: "BLE Service UUIDs", rawField: "bleEvidence[].serviceUUIDs", rawValue: "see raw", friendly: "Service names from local mapping tables.")
            ]
            let appendix: [String] = [
                "Raw reference: \(rawFilename)",
                "Host records (raw): records[]",
                "BLE evidence (raw): bleEvidence[]",
                "Pi-Aux evidence count: \(piAuxEvidence.count)"
            ]
            let readable = ScanReportReadable(
                meta: .init(isoTimestamp: iso, rawRef: rawFilename),
                summary: .init(
                    totalHosts: snapshot.records.count,
                    highConfidence: high,
                    mediumConfidence: medium,
                    lowConfidence: low,
                    topHosts: topHosts,
                    bleDevices: bleEvidence.count
                ),
                summaryText: summaryText,
                clientSummary: clientSummary,
                classification: "Network inventory snapshot",
                evidence: evidenceItems,
                topConfidence: topConfidence,
                identityMapping: identityMappings,
                technicalAppendix: appendix,
                aliases: aliasMap
            )
            let readableData = try encoder.encode(readable)
            let readableFilename = "SODS-ScanReportReadable-\(iso).json"
            let readableURL = LogStore.exportURL(subdir: "scan-report-readable", filename: readableFilename, log: logStore)
            _ = LogStore.writeDataReturning(readableData, to: readableURL, log: logStore)
            let bleCount = bleEvidence.count
            logStore.log(.info, "Scan report generated: hosts=\(snapshot.records.count) ble=\(bleCount) high=\(high) top=\(topHosts.joined(separator: ", "))")
            BLEMetadataStore.shared.logStats(log: logStore)
        } catch {
            logStore.log(.error, "Failed to generate scan report: \(error.localizedDescription)")
        }
    }

    private func exportAudit() {
        if let audit = scanner.buildAuditLog() {
            AppTruth.shared.lastAuditLog = audit
            logStore.exportAuditLog(audit)
        } else {
            logStore.log(.warn, "No completed scan available for audit export")
        }
    }

    private func exportRuntimeLog() {
        let iso = LogStore.isoTimestamp()
        let rawFilename = "SODS-LogsRaw-\(iso).txt"
        let rawURL = LogStore.exportURL(subdir: "logs-raw", filename: rawFilename, log: logStore)
        _ = LogStore.writeStringReturning(logStore.copyAllText(), to: rawURL, log: logStore)

        let readableFilename = "SODS-LogsReadable-\(iso).txt"
        let readableURL = LogStore.exportURL(subdir: "logs-readable", filename: readableFilename, log: logStore)
        let scanToggles = LogScanToggles(
            onvifDiscovery: onvifDiscoveryEnabled,
            serviceDiscovery: serviceDiscoveryEnabled,
            arpWarmup: arpWarmupEnabled,
            safeMode: scanner.safeModeEnabled,
            bleDiscovery: bleDiscoveryEnabled
        )
        let readableText = buildReadableLog(rawFilename: rawFilename, scanner: scanner, bleScanner: bleScanner, scanToggles: scanToggles)
        if let url = LogStore.writeStringReturning(readableText, to: readableURL, log: logStore) {
            LogStore.copyExportSummaryToClipboard(path: url.path, summary: readableText)
            logStore.log(.info, "Runtime log export copied to clipboard")
        }
    }

    private func revealLatestReport() {
        if let url = LogStore.latestReadableScanReportURL(log: logStore) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            logStore.log(.warn, "No readable scan report found in ~/SODS/reports/scan-readable/")
        }
    }

    private func runRtspTry(with credentials: (String, String)?) {
        guard let ip = rtspPromptIP else {
            showRtspCredentialsPrompt = false
            return
        }
        if let credentials {
            rtspSessionCreds[ip] = credentials
            saveCredentials(for: ip, username: credentials.0, password: credentials.1)
            if credentialIP == ip {
                credentialUsername = credentials.0
                credentialPassword = credentials.1
                applyCredentialsToDevice(ip: ip)
            }
        }
        let creds = rtspSessionCreds[ip]
        showRtspCredentialsPrompt = false
        tryRtspPaths(for: ip, credentials: creds)
    }

    private func tryRtspPaths(for ip: String, credentials: (String, String)?) {
        let safeMode = scanner.safeModeEnabled
        if safeMode {
            logStore.log(.warn, "Safe Mode on: blocked RTSP path try for \(ip)")
            return
        }
        let username = credentials?.0 ?? ""
        let password = credentials?.1 ?? ""
        let credState = (credentials == nil || username.isEmpty) ? "none" : "provided"
        logStore.log(.info, "RTSP path try started for \(ip) credentials=\(credState)")
        Task {
            let results = await RTSPProber.probe(
                ip: ip,
                username: username,
                password: password,
                semaphore: rtspTrySemaphore,
                log: { level, message in
                    LogStore.shared.log(level, message)
                }
            )
            let successes = results.filter { $0.success }
            let best = successes.first?.uri
            logStore.log(.info, "RTSP path try finished for \(ip): \(successes.count) ok")
            if let index = scanner.devices.firstIndex(where: { $0.ip == ip }) {
                scanner.devices[index].rtspProbeResults = results
                scanner.devices[index].bestRtspURI = best
                scanner.devices[index].lastRtspProbeSummary = successes.isEmpty ? "No working RTSP URLs found" : "Found \(successes.count) working RTSP URLs"
            }
        }
    }

    private func openRTSPInVLC(url: String, ip: String) {
        if VLCLauncher.shared.isAvailable(log: logStore) {
            VLCLauncher.shared.open(url: url, log: logStore, deviceIP: ip)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
            logStore.log(.info, "Opened RTSP URL for \(ip): \(url)")
        } catch {
            logStore.log(.error, "Failed to open RTSP URL for \(ip): \(error.localizedDescription)")
        }
    }

    private func exportEvidenceJSON(for ip: String) {
        guard let host = AppTruth.shared.resolveHost(ip: ip, scanner: scanner) else {
            logStore.log(.warn, "No host evidence available for \(ip)")
            return
        }
        logStore.log(.info, "Export Evidence JSON: ip=\(ip)")
        struct EvidenceReadable: Codable {
            struct Meta: Codable {
                let isoTimestamp: String
                let appVersion: String
                let buildNumber: String
                let hostIP: String
            }
            struct RawRef: Codable {
                let filename: String
            }
            struct Confidence: Codable {
                let level: String
                let score: Int
                let explanations: [String]
            }
            struct IntSignal: Codable {
                let raw: Int?
                let meaning: String
            }
            struct StringSignal: Codable {
                let raw: String?
                let meaning: String
            }
            struct BoolSignal: Codable {
                let raw: Bool
                let meaning: String
            }
            struct PortsSignal: Codable {
                let raw: [Int]
                let meaning: [String]
            }
            struct Signals: Codable {
                let openPorts: PortsSignal
                let httpStatus: IntSignal
                let httpServer: StringSignal
                let httpAuth: StringSignal
                let httpTitle: StringSignal
                let onvif: BoolSignal
                let rtsp: StringSignal
                let ssdp: StringSignal
                let bonjour: StringSignal
            }
            struct GlossaryItem: Codable {
                let term: String
                let meaning: String
            }
            let meta: Meta
            let rawRef: RawRef
            let summary: String
            let confidence: Confidence
            let signals: Signals
            let recommendations: [String]
            let glossary: [GlossaryItem]
        }

        let payload = buildEvidencePayload(host)
        AppTruth.shared.lastEvidenceByIP[ip] = payload

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let rawData = try encoder.encode(payload)
            let iso = LogStore.isoTimestamp()
            let safeIP = LogStore.sanitizeFilename(host.ip)
            let rawFilename = "SODS-EvidenceRaw-\(safeIP)-\(iso).json"
            let rawURL = LogStore.exportURL(subdir: "evidence-raw", filename: rawFilename, log: logStore)
            _ = LogStore.writeDataReturning(rawData, to: rawURL, log: logStore)

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let device = AppTruth.shared.resolveDevice(ip: host.ip, scanner: scanner)
            let portHints = portHintsText(for: host.openPorts)
            let rtspRaw = bestRTSPURI(for: host.ip) ?? (host.openPorts.contains(554) ? "rtsp://\(host.ip):554/" : nil)
            let rtspCount = device?.rtspProbeResults.filter { $0.success }.count ?? 0
            let onvifFound = (device?.discoveredViaOnvif ?? false) || host.openPorts.contains(3702) || (host.ssdpUSN?.lowercased().contains("onvif") ?? false)
            let ssdpSummary = host.ssdpServer ?? host.ssdpST ?? host.ssdpUSN ?? ""
            let bonjourSummary = host.bonjourServices.map { "\($0.name) \($0.type)" }.joined(separator: ", ")

            let readable = EvidenceReadable(
                meta: .init(isoTimestamp: iso, appVersion: version, buildNumber: build, hostIP: host.ip),
                rawRef: .init(filename: rawFilename),
                summary: evidenceSummary(host: host, rtspURL: rtspRaw),
                confidence: .init(
                    level: host.hostConfidence.level.rawValue,
                    score: host.hostConfidence.score,
                    explanations: host.hostConfidence.reasons
                ),
                signals: .init(
                    openPorts: .init(raw: host.openPorts, meaning: portHints),
                    httpStatus: .init(raw: host.httpStatus, meaning: httpStatusMeaning(host.httpStatus)),
                    httpServer: .init(raw: host.httpServer, meaning: host.httpServer == nil ? "No server header observed." : "Server header reported by device."),
                    httpAuth: .init(raw: host.httpAuth, meaning: host.httpAuth == nil ? "No WWW-Authenticate header observed." : "Auth header indicates login may be required."),
                    httpTitle: .init(raw: host.httpTitle, meaning: host.httpTitle == nil ? "No title observed." : "Page title can hint at device UI."),
                    onvif: .init(raw: onvifFound, meaning: onvifFound ? "ONVIF-related signal observed." : "No ONVIF evidence observed."),
                    rtsp: .init(raw: rtspRaw, meaning: rtspRaw == nil ? "No RTSP port detected." : "RTSP available; validated streams found: \(rtspCount)."),
                    ssdp: .init(raw: ssdpSummary.isEmpty ? nil : ssdpSummary, meaning: ssdpSummary.isEmpty ? "No SSDP response." : "SSDP indicates a UPnP-capable device."),
                    bonjour: .init(raw: bonjourSummary.isEmpty ? nil : bonjourSummary, meaning: bonjourSummary.isEmpty ? "No Bonjour services found." : "Bonjour services observed.")
                ),
                recommendations: [
                    "Open the web UI to confirm device identity.",
                    "If RTSP is available, open in VLC to validate streams.",
                    "Verify credentials locally; do not attempt unauthorized access.",
                    "Label the device and record its physical location.",
                    "Re-scan after changes to confirm inventory."
                ],
                glossary: [
                    .init(term: "ONVIF", meaning: "Open Network Video Interface Forum standard for IP cameras."),
                    .init(term: "RTSP", meaning: "Real Time Streaming Protocol for media streams."),
                    .init(term: "SSDP", meaning: "Simple Service Discovery Protocol for UPnP devices."),
                    .init(term: "Bonjour", meaning: "Apple's mDNS-based local service discovery.")
                ]
            )

            let readableData = try encoder.encode(readable)
            let readableFilename = "SODS-EvidenceReadable-\(safeIP)-\(iso).json"
            let readableURL = LogStore.exportURL(subdir: "evidence-readable", filename: readableFilename, log: logStore)
            if let url = LogStore.writeDataReturning(readableData, to: readableURL, log: logStore) {
                LogStore.copyExportSummaryToClipboard(path: url.path, summary: readable.summary)
                logStore.log(.info, "Evidence export copied to clipboard for \(host.ip)")
            }
        } catch {
            logStore.log(.error, "Failed to export evidence JSON: \(error.localizedDescription)")
        }
    }

    private func portHintsText(for ports: [Int]) -> [String] {
        var hints: [String] = []
        for port in ports.sorted() {
            switch port {
            case 80: hints.append("80: HTTP web UI")
            case 443: hints.append("443: HTTPS web UI")
            case 554: hints.append("554: RTSP media stream")
            case 8554: hints.append("8554: RTSP alternate")
            case 3702: hints.append("3702: ONVIF discovery")
            case 8000: hints.append("8000: Web UI / API")
            case 8080: hints.append("8080: Alternate web UI")
            case 8443: hints.append("8443: Alternate HTTPS")
            case 22: hints.append("22: SSH remote access")
            case 445: hints.append("445: SMB file sharing")
            case 5353: hints.append("5353: mDNS/Bonjour")
            case 1900: hints.append("1900: SSDP/UPnP")
            default: hints.append("\(port): Open TCP port")
            }
        }
        return hints
    }

    private func httpStatusMeaning(_ status: Int?) -> String {
        switch status {
        case 200: return "OK (web UI likely available)."
        case 401: return "Unauthorized (login required)."
        case 403: return "Forbidden (access blocked)."
        case 404: return "Not Found (common on embedded devices)."
        case .some: return "HTTP response received."
        case .none: return "No HTTP response observed."
        }
    }

    private func evidenceSummary(host: HostEntry, rtspURL: String?) -> String {
        var parts: [String] = []
        parts.append("Host \(host.ip) shows \(host.isAlive ? "signs of life" : "no port response").")
        if !host.openPorts.isEmpty {
            parts.append("Open ports: \(host.openPorts.sorted().map(String.init).joined(separator: ", ")).")
        }
        if let vendor = host.vendor, !vendor.isEmpty {
            parts.append("Vendor hint: \(vendor).")
        }
        if rtspURL != nil {
            parts.append("RTSP port detected; streaming may be available.")
        }
        return parts.joined(separator: " ")
    }

    private func onvifStatus(for device: Device) -> String? {
        guard device.discoveredViaOnvif else { return nil }
        if scanner.onvifFetchInProgress.contains(device.id) {
            return "Fetching..."
        }
        if device.onvifRtspURI != nil {
            return "RTSP OK"
        }
        if device.onvifRequiresAuth {
            return "Auth Required"
        }
        if device.onvifLastError != nil {
            return "Error"
        }
        return nil
    }

    private func bleAvailabilityMessage() -> String {
        switch bleScanner.stateDescription {
        case "unauthorized":
            return "Bluetooth permission required."
        case "poweredOff":
            return "Bluetooth is off."
        case "unsupported":
            return "Bluetooth capability not available on this Mac."
        case "resetting":
            return "Bluetooth is resetting."
        default:
            return "Bluetooth capability unavailable."
        }
    }

    private func exportHosts() {
        guard let snapshot = scanner.buildExportSnapshot() else {
            logStore.log(.warn, "No completed scan available for export")
            return
        }
        AppTruth.shared.lastExportSnapshot = snapshot
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json, UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.directoryURL = LogStore.exportBaseDirectory(log: logStore)
        panel.nameFieldStringValue = "SODS-Export-\(isoTimestampForFilename()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format = url.pathExtension.lowercased()
            let logger = LogStore.shared
            Task.detached {
                do {
                    if format == "csv" {
                        let csv = exportCSV(snapshot)
                        try csv.write(to: url, atomically: true, encoding: .utf8)
                    } else {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(snapshot)
                        try data.write(to: url, options: [.atomic])
                    }
                    logger.log(.info, "Exported \(snapshot.records.count) records to \(url.path)")
                    Task.detached {
                        _ = await ArtifactStore.shared.enqueueArtifact(url, log: logger)
                        await ArtifactStore.shared.runCleanup(log: logger)
                        await MainActor.run {
                            if VaultTransport.shared.autoShipAfterExport {
                                VaultTransport.shared.shipNow(log: logger)
                            }
                        }
                    }
                    Task { @MainActor in
                        let summary = [
                            "Host export",
                            "Records: \(snapshot.records.count)",
                            "Timestamp: \(snapshot.timestamp)"
                        ].joined(separator: "\n")
                        LogStore.copyExportSummaryToClipboard(path: url.path, summary: summary)
                        logStore.log(.info, "Export path copied to clipboard")
                        LogStore.revealAndOpen(url)
                    }
                } catch {
                    logger.log(.error, "Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func revealExports() {
        let dir = StoragePaths.reportsBase()
        NSWorkspace.shared.open(dir)
    }

    private func revealLatestEvidence(for ip: String) {
        let safeIP = LogStore.sanitizeFilename(ip)
        let readableDir = StoragePaths.reportsSubdir("device-readable")
        let readablePrefix = "SODS-EvidenceReadable-\(safeIP)-"
        if let url = latestFile(in: readableDir, prefix: readablePrefix) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let dir = StoragePaths.inboxSubdir("evidence-raw")
        let prefix = "SODS-EvidenceRaw-\(safeIP)-"
        if let url = latestFile(in: dir, prefix: prefix) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            logStore.log(.warn, "No evidence file found for \(ip)")
        }
    }

    private func revealLatestProbeReport(for ip: String) {
        if let url = RTSPHardProbe.latestReportURL(for: ip, log: logStore) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            logStore.log(.warn, "No hard probe report found for \(ip)")
        }
    }

    private func revealDeviceArtifacts(for ip: String) {
        let caseDir = StoragePaths.workspaceSubdir("cases").appendingPathComponent(LogStore.sanitizeFilename(ip))
        if FileManager.default.fileExists(atPath: caseDir.path) {
            NSWorkspace.shared.open(caseDir)
            return
        }
        revealLatestEvidence(for: ip)
    }

    private func latestFile(in dir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let matches = items.filter { $0.lastPathComponent.hasPrefix(prefix) }
        let sorted = matches.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        return sorted.first
    }

    private func isoTimestampForFilename() -> String {
        LogStore.isoTimestamp()
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
            Button("I Understand") {
                onAcknowledge()
            }
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

    var body: some View {
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

            ScrollView {
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
                Button("Copy IP") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.ip, forType: .string)
                }
                Button("Copy RTSP") {
                    NSPasteboard.general.clearContents()
                    let value = device.bestRtspURI ?? device.suggestedRTSPURL
                    NSPasteboard.general.setString(value, forType: .string)
                }
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
            Text("Details")
                .font(.system(size: 16, weight: .semibold))
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
        HStack(spacing: 8) {
            if let ip, bestHTTPURL != nil {
                Button("Open Web UI") { onOpenWeb(ip) }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            if let ip, let rtsp {
                Button("Open in VLC") { onOpenVLC(rtsp, ip) }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            if let device, !safeMode && !device.rtspProbeInProgress {
                Button("Probe RTSP") { onProbeRtsp(device) }
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            if let device, !safeMode && !isFetching {
                Button("Retry RTSP Fetch") { onFetch(device) }
                    .buttonStyle(SecondaryActionButtonStyle())
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
                                Button("Copy RTSP URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result.uri, forType: .string)
                                }
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
    let prober: BLEProber
    let peripherals: [BLEPeripheral]
    let aliasForPeripheral: (BLEPeripheral) -> String?
    @Binding var selectedID: UUID?
    @Binding var findFingerprintID: String
    let warningText: String?
    let onGenerateScanReport: () -> Void
    let onRevealLatestReport: () -> Void
    let onExportAudit: () -> Void
    let onExportRuntimeLog: () -> Void
    let onRevealExports: () -> Void
    let onShipNow: () -> Void
    @State private var showRecentOnly = true
    @State private var lockFindTarget = true

    var body: some View {
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
                Text("Devices discovered: \(peripherals.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Last: \(scanner.lastPermissionMessage)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("Touch Permission") {
                    Task { @MainActor in
                        await BLEScanner.shared.touchForPermissionIfNeeded()
                    }
                }
                Button("Import BLE Company IDs...") {
                    BLEMetadataStore.shared.importCompanyMap(log: LogStore.shared)
                }
                Button("Import BLE Assigned Numbers...") {
                    BLEMetadataStore.shared.importAssignedNumbersMap(log: LogStore.shared)
                }
                Button("Reveal Resources Folder") {
                    StoragePaths.revealResourcesFolder()
                }
                Spacer()
                if !findFingerprintID.isEmpty {
                    Text("Find: \(findFingerprintID)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if scanner.authorizationStatus == .denied || scanner.authorizationStatus == .restricted {
                HStack {
                    Text("Bluetooth permission is blocked. Enable it in System Settings to scan.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Open Bluetooth Privacy Settings") {
                        openBluetoothPrivacySettings()
                    }
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

            HStack(spacing: 12) {
                Toggle("Show only devices seen in last 10s", isOn: $showRecentOnly)
                    .toggleStyle(.switch)
                Toggle("Lock Find Target", isOn: $lockFindTarget)
                    .toggleStyle(.switch)
                Spacer()
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Find")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 50, alignment: .leading)
                        Text("Label")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 200, alignment: .leading)
                        Text("Alias")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 200, alignment: .leading)
                        Text("Company")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 180, alignment: .leading)
                        Text("Services")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 260, alignment: .leading)
                        Text("Provenance")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 200, alignment: .leading)
                        Text("Beacon")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        Text("Connectable")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        Text("Conf")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        Text("RSSI")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 80, alignment: .leading)
                        Text("Identifier")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.04))

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredRecent(peripherals: peripherals)) { peripheral in
                                HStack {
                                    Text(findFingerprintID == peripheral.fingerprintID ? "Find" : "")
                                        .frame(width: 50, alignment: .leading)
                                    Text(labelForPeripheral(peripheral))
                                        .frame(width: 200, alignment: .leading)
                                    Text(aliasForPeripheral(peripheral) ?? "")
                                        .frame(width: 200, alignment: .leading)
                                    Text(companyLabel(peripheral.fingerprint))
                                        .frame(width: 180, alignment: .leading)
                                    Text(serviceNamesLabel(peripheral.fingerprint))
                                        .frame(width: 260, alignment: .leading)
                                    Text(peripheral.provenance?.label ?? "")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(width: 200, alignment: .leading)
                                    Text(peripheral.fingerprint.beaconHint ?? "")
                                        .frame(width: 110, alignment: .leading)
                                    Text(connectableLabel(peripheral.fingerprint.isConnectable))
                                        .frame(width: 110, alignment: .leading)
                                    Text("\(peripheral.bleConfidence.level.rawValue) (\(peripheral.bleConfidence.score))")
                                        .frame(width: 110, alignment: .leading)
                                    Text("\(peripheral.rssi)")
                                        .frame(width: 80, alignment: .leading)
                                        .foregroundColor(peripheral.rssi > -60 ? .green : .secondary)
                                    Text(peripheral.id.uuidString)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12))
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                                .background(selectedID == peripheral.id ? Theme.accent.opacity(0.2) : Color.clear)
                                .cornerRadius(4)
                                .onTapGesture {
                                    selectedID = peripheral.id
                                    if lockFindTarget {
                                        findFingerprintID = peripheral.fingerprintID
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .frame(minWidth: 520)

                Divider()

                BLEDetailView(
                    peripheral: selectedPeripheral,
                    prober: prober,
                    findFingerprintID: $findFingerprintID,
                    aliasForPeripheral: { peripheral in
                        IdentityResolver.shared.resolveLabel(keys: [peripheral.fingerprintID, peripheral.id.uuidString])
                    },
                    onGenerateScanReport: onGenerateScanReport,
                    onRevealLatestReport: onRevealLatestReport,
                    onExportAudit: onExportAudit,
                    onExportRuntimeLog: onExportRuntimeLog,
                    onRevealExports: onRevealExports,
                    onShipNow: onShipNow
                )
                .frame(minWidth: 320, maxWidth: 380)
            }
        }
    }

    private var selectedPeripheral: BLEPeripheral? {
        guard let selectedID = selectedID else { return nil }
        return peripherals.first(where: { $0.id == selectedID })
    }

    private func filteredRecent(peripherals: [BLEPeripheral]) -> [BLEPeripheral] {
        guard showRecentOnly else { return peripherals }
        let cutoff = Date().addingTimeInterval(-10)
        return peripherals.filter { $0.lastSeen >= cutoff }
    }

    private func labelForPeripheral(_ peripheral: BLEPeripheral) -> String {
        if let alias = aliasForPeripheral(peripheral), !alias.isEmpty {
            return alias
        }
        if let label = scanner.label(for: peripheral.fingerprintID), !label.isEmpty {
            return label
        }
        return peripheral.name ?? "Unknown"
    }

    private func companyLabel(_ fingerprint: BLEAdFingerprint) -> String {
        guard let id = fingerprint.manufacturerCompanyID else { return "" }
        let name = fingerprint.manufacturerCompanyName ?? "Unknown"
        return "\(name) (0x\(String(format: "%04X", id)))"
    }

    private func serviceNamesLabel(_ fingerprint: BLEAdFingerprint) -> String {
        let decoded = fingerprint.servicesDecoded.map { "\($0.name) (\(BLEUUIDDisplay.shortAndNormalized($0.uuid)))" }
        if decoded.isEmpty {
            let raw = fingerprint.serviceUUIDs.map { BLEUUIDDisplay.shortAndNormalized($0) }
            if raw.isEmpty { return "" }
            let prefix = raw.prefix(2)
            let remainder = raw.count - prefix.count
            if remainder > 0 {
                return "\(prefix.joined(separator: ", ")) +\(remainder) more"
            }
            return prefix.joined(separator: ", ")
        }
        let prefix = decoded.prefix(2)
        let remainder = decoded.count - prefix.count
        if remainder > 0 {
            return "\(prefix.joined(separator: ", ")) +\(remainder) more"
        }
        return prefix.joined(separator: ", ")
    }

    private func connectableLabel(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "Yes" : "No"
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
    @State private var labelText: String = ""

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
                        }
                        .onChange(of: peripheral.fingerprintID) { _ in
                            labelText = BLEScanner.shared.label(for: peripheral.fingerprintID) ?? ""
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
            Text("BLE Details")
                .font(.system(size: 16, weight: .semibold))
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
            HStack(spacing: 8) {
                Button("Probe / Connect") {
                    prober.startProbe(peripheralInfo: peripheral)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!canProbe)

                Button("Pin to Case") {
                    CaseManager.shared.pinBLE(fingerprintID: peripheral.fingerprintID, bleScanner: BLEScanner.shared, log: LogStore.shared)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
        }
    }

    private func actionSections() -> [ActionMenuSection] {
        let hostActions = ActionMenuSection(
            title: "Host Actions",
            items: [
                ActionMenuItem(title: "Open Web UI", systemImage: "globe", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Open SSDP Location", systemImage: "link", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Open in VLC", systemImage: "play.rectangle", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Probe RTSP", systemImage: "dot.radiowaves.left.and.right", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Hard Probe (VLC + Diagnostics)", systemImage: "hammer", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Retry RTSP Fetch", systemImage: "arrow.clockwise", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Export Evidence (Raw + Readable)", systemImage: "tray.and.arrow.down", enabled: false, reason: "No host selected", action: {}),
                ActionMenuItem(title: "Export Device Report", systemImage: "doc.text", enabled: false, reason: "No host selected", action: {})
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
        return [hostActions, appActions, bleActions]
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

struct NodesView: View {
    @ObservedObject var store: PiAuxStore
    @ObservedObject var sodsStore: SODSStore
    let nodes: [NodeRecord]
    let nodePresence: [String: NodePresence]
    @ObservedObject var scanner: NetworkScanner
    @ObservedObject var flashManager: FlashServerManager
    let connectableNodeIDs: [String]
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
    @State private var portText: String = ""

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
                    ForEach(nodes) { node in
                        NodeCardView(
                            node: node,
                            presence: nodePresence[node.id],
                            eventCount: store.recentEventCount(nodeID: node.id, window: 600),
                            actions: actions(for: node),
                            onRefresh: {
                                sodsStore.connectNode(node.id)
                                sodsStore.identifyNode(node.id)
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
                        TextField("8787", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onAppear {
                                portText = String(store.port)
                            }
                        Button("Apply") {
                            if let value = Int(portText) {
                                store.updatePort(value)
                            }
                        }
                        Button("Test Ping") {
                            store.testPing()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
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
                        Button("Stop Scan") { onStopScan() }
                            .buttonStyle(PrimaryActionButtonStyle())
                    } else {
                        Button("Start \(networkScanMode.label) Scan") { onStartScan() }
                            .buttonStyle(PrimaryActionButtonStyle())
                    }
                    Button("Generate Scan Report") { onGenerateScanReport() }
                        .buttonStyle(SecondaryActionButtonStyle())
                    Button("Reveal Latest Report") { onRevealLatestReport() }
                        .buttonStyle(SecondaryActionButtonStyle())
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
                    if !connectableNodeIDs.isEmpty {
                        Picker("Node", selection: $connectNodeID) {
                            ForEach(connectableNodeIDs, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                        .frame(width: 220)
                    }
                    TextField("Node ID", text: $connectNodeID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("Connect Node") {
                        let target = !connectNodeID.isEmpty ? connectNodeID : (connectableNodeIDs.first ?? "")
                        if !target.isEmpty {
                            connectNodeID = target
                            sodsStore.connectNode(target)
                            store.connectNode(target)
                            if !bleDiscoveryEnabled {
                                bleDiscoveryEnabled = true
                            }
                            if networkScanMode == .continuous && !scanner.isScanning {
                                onStartScan()
                            }
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("Flash Target")
                        .font(.system(size: 11))
                    Picker("Target", selection: $flashManager.selectedTarget) {
                        ForEach(FlashTarget.allCases) { target in
                            Text(target.label).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button("Flash Firmware") {
                        showFlashConfirm = true
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(flashManager.isStarting)
                    .confirmationDialog(
                        "Flash firmware to \(flashManager.selectedTarget.label)?",
                        isPresented: $showFlashConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Flash \(flashManager.selectedTarget.label)", role: .destructive) {
                            flashManager.startSelectedTarget()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will open the station flasher for the selected target. Confirm before continuing.")
                    }

                    Button("Open Station Flasher") {
                        flashManager.openLocalFlasher()
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    if flashManager.canOpenFlasher {
                        Button("Open Flasher") {
                            flashManager.openFlasher()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }

                    if flashManager.isRunning {
                        Button("Stop Server") {
                            flashManager.stop()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                    Button("Find Newly Flashed Device") { onFindDevice() }
                    .buttonStyle(SecondaryActionButtonStyle())
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
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(terminalCommand, forType: .string)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                }

                flashPrepSection
            }
            .padding(6)
            .onAppear { flashManager.refreshPrepStatus() }
            .onChange(of: flashManager.selectedTarget) { _ in
                flashManager.refreshPrepStatus()
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
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(flashManager.prepStatus.buildCommand, forType: .string)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    Spacer()
                }
            }
        }
    }

    private func actions(for node: NodeRecord) -> [NodeAction] {
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
            items.append(NodeAction(title: "Ping", action: { store.pingNode(node.id) }))
        }
        if supportsReport {
            items.append(NodeAction(title: "Generate Report", action: { onGenerateScanReport() }))
        }
        return items
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
    let onRefresh: () -> Void
    @State private var showActions = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { timeline in
            let status = nodeStatus()
            let activity = min(1.0, Double(eventCount) / 40.0)
            let presentation = NodePresentation.forNode(
                id: node.id,
                keys: [node.id, "node:\(node.id)"],
                isOnline: status.isOnline,
                activityScore: activity
            )
            let isRefreshing = {
                let state = presence?.state.lowercased() ?? ""
                return state == "connecting" || state == "scanning"
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
                if let errorLine = lastErrorLine() {
                    Text(errorLine)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryColor)
                }

                HStack(spacing: 8) {
                    Button(isRefreshing ? "Refreshing…" : "Refresh/Reconnect") { onRefresh() }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(isRefreshing)
                    Button("Actions") { showActions.toggle() }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.85))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .popover(isPresented: $showActions, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                ModalHeaderView(title: "Node Actions", onBack: nil, onClose: { showActions = false })
                                if actions.isEmpty {
                                    Text("No actions available.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(actions) { action in
                                        Button(action.title) { action.action() }
                                            .buttonStyle(SecondaryActionButtonStyle())
                                    }
                                }
                            }
                            .padding(12)
                            .frame(minWidth: 240)
                            .background(Theme.panel)
                        }
                    Spacer()
                }
            }
            .padding(12)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .cornerRadius(12)
            .shadow(color: presentation.shouldGlow ? Color(presentation.baseColor).opacity(glowAlpha) : .clear, radius: glowRadius)
        }
    }

    private func nodeStatus() -> (label: String, isOnline: Bool, lastSeenText: String) {
        let lastSeen = presence?.lastSeen ?? Int((node.lastSeen ?? node.lastHeartbeat)?.timeIntervalSince1970 ?? 0) * 1000
        let lastSeenText = lastSeen > 0
        ? Date(timeIntervalSince1970: TimeInterval(lastSeen) / 1000).formatted(date: .abbreviated, time: .shortened)
        : "Not seen yet"
        let state = presence?.state ?? "offline"
        switch state {
        case "online":
            return ("Online", true, lastSeenText)
        case "connecting":
            return ("Connecting", false, lastSeenText)
        case "error":
            return ("Error", false, lastSeenText)
        default:
            return ("Offline", false, lastSeenText)
        }
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
        let host = presence?.hostname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = presence?.ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = presence?.mac?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                let isOnline = node.presenceState == .connected || node.presenceState == .idle || node.presenceState == .scanning
                                let presentation = NodePresentation.forNode(
                                    id: node.id,
                                    keys: [node.id, "node:\(node.id)"],
                                    isOnline: isOnline,
                                    activityScore: 0
                                )
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
                                    Button("Add") {
                                        appendNodeID(node.id)
                                    }
                                    .buttonStyle(SecondaryActionButtonStyle())
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
                        Button("Start Session") {
                            let nodes = sessionNodesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            sessionManager.start(nodes: nodes, sources: selectedSources())
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(sessionManager.isActive)
                        Button("Stop Session") {
                            sessionManager.stop(log: LogStore.shared)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!sessionManager.isActive)
                    }
                }
                .padding(6)
            }
            HStack {
                Button("Refresh") { onRefresh() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Button("Clear Selection") {
                    selectedCase = nil
                    sessionNodesText = ""
                }
                .buttonStyle(SecondaryActionButtonStyle())
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
                    Button("Open Case Folder") {
                        caseManager.openCaseFolder(selectedCase)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    Button("Generate Case Report") {
                        caseManager.generateCaseReport(selectedCase, log: LogStore.shared)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    Button("Ship Now") {
                        vaultTransport.shipNow(log: LogStore.shared)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
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
                TextField("pi-logger.local", text: $shipper.host)
                    .textFieldStyle(.roundedBorder)
                Text("User")
                    .frame(width: 70, alignment: .leading)
                TextField("pi", text: $shipper.user)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Destination")
                    .frame(width: 90, alignment: .leading)
                TextField("/var/sods/vault/sods/", text: $shipper.destinationPath)
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
                Button("Ship Now") {
                    shipper.save()
                    shipper.shipNow(log: LogStore.shared)
                }
                Button("Reveal Shipper State") {
                    onRevealShipper()
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
                Button("Prune Now") { onPrune() }
                Spacer()
                Button("Reveal Resources Folder") { onRevealResources() }
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
                Button("Export Audit Log") {
                    onExportAudit()
                }
                Button("View Latest Audit") {
                    if let url = LogStore.latestAuditURL(log: logStore) {
                        NSWorkspace.shared.open(url)
                    } else {
                        logStore.log(.warn, "No audit file exists yet in ~/SODS/reports/audit-raw/")
                    }
                }
                Button("View Latest Readable") {
                    if let url = LogStore.latestReadableAuditURL(log: logStore) {
                        NSWorkspace.shared.open(url)
                    } else {
                        logStore.log(.warn, "No readable audit file exists yet in ~/SODS/reports/audit-readable/")
                    }
                }
                Button("Export Runtime Log (TXT)") {
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
                Button("Clear") {
                    logStore.clear()
                }
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
private func buildReadableLog(rawFilename: String, scanner: NetworkScanner, bleScanner: BLEScanner, scanToggles: LogScanToggles) -> String {
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

private func portLabelsString(_ ports: [Int]) -> String {
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

private func exportCSV(_ snapshot: ExportSnapshot) -> String {
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
}

private func sodsRootPath() -> String {
    if let env = ProcessInfo.processInfo.environment["SODS_ROOT"], !env.isEmpty {
        return env
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/sods/SODS"
}

private func nodeAgentRootPath() -> String {
    "\(sodsRootPath())/firmware/node-agent"
}

private func p4RootPath() -> String {
    "\(sodsRootPath())/firmware/sods-p4-godbutton"
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
                Button("ESP32 DevKit") { onFlashEsp32() }
                    .buttonStyle(PrimaryActionButtonStyle())
                Button("ESP32-C3 DevKit") { onFlashEsp32c3() }
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            HStack(spacing: 10) {
                Button("Ops Portal CYD") { onFlashPortalCyd() }
                    .buttonStyle(PrimaryActionButtonStyle())
                Button("ESP32-P4 God Button") { onFlashP4() }
                    .buttonStyle(PrimaryActionButtonStyle())
            }

            Button("Open Web Tools Folder") { onOpenWebTools() }
                .buttonStyle(SecondaryActionButtonStyle())
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
    case esp32p4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .esp32dev:
            return "ESP32 DevKit v1"
        case .esp32c3:
            return "ESP32-C3 DevKitM-1"
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
        case .esp32p4:
            return "chip=esp32p4"
        }
    }

    var buildCommand: String {
        switch self {
        case .esp32dev:
            return "cd \(nodeAgentRootPath()) && ./tools/build-stage-esp32dev.sh"
        case .esp32c3:
            return "cd \(nodeAgentRootPath()) && ./tools/build-stage-esp32c3.sh"
        case .esp32p4:
            return "cd \(sodsRootPath()) && ./tools/p4-stage.sh"
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
        case .esp32p4:
            root = p4RootPath()
            toolsDir = "\(root)/tools"
            scriptPath = ""
        }

        if !scriptPath.isEmpty && FileManager.default.fileExists(atPath: scriptPath) {
            let commandLine = "cd \(root) && \(scriptPath) --port \(port)"
            let config = ProcessConfig(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", "\(scriptPath) --port \(port)"],
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
        case .esp32p4:
            root = p4RootPath()
        }
        let webTools = "\(root)/esp-web-tools"
        let firmwareBase = "\(webTools)/firmware"

        var missing: [String] = []

        let manifestPath: String
        switch target {
        case .esp32dev:
            manifestPath = "\(webTools)/manifest.json"
        case .esp32c3:
            manifestPath = "\(webTools)/manifest-esp32c3.json"
        case .esp32p4:
            manifestPath = "\(webTools)/manifest-p4.json"
        }

        if !FileManager.default.fileExists(atPath: manifestPath) {
            missing.append(displayPath(manifestPath))
        }

        let (bootCandidates, partCandidates, fwCandidates): ([String], [String], [String])
        switch target {
        case .esp32dev:
            bootCandidates = [
                "\(firmwareBase)/esp32dev/bootloader.bin",
                "\(firmwareBase)/bootloader.bin"
            ]
            partCandidates = [
                "\(firmwareBase)/esp32dev/partitions.bin",
                "\(firmwareBase)/partitions.bin"
            ]
            fwCandidates = [
                "\(firmwareBase)/esp32dev/firmware.bin",
                "\(firmwareBase)/firmware.bin"
            ]
        case .esp32c3:
            bootCandidates = [
                "\(firmwareBase)/esp32c3/bootloader.bin"
            ]
            partCandidates = [
                "\(firmwareBase)/esp32c3/partitions.bin"
            ]
            fwCandidates = [
                "\(firmwareBase)/esp32c3/firmware.bin"
            ]
        case .esp32p4:
            bootCandidates = [
                "\(firmwareBase)/p4/bootloader.bin"
            ]
            partCandidates = [
                "\(firmwareBase)/p4/partitions.bin"
            ]
            fwCandidates = [
                "\(firmwareBase)/p4/firmware.bin"
            ]
        }

        if !anyExists(bootCandidates) {
            missing.append(displayPath(bootCandidates[0]))
        }
        if !anyExists(partCandidates) {
            missing.append(displayPath(partCandidates[0]))
        }
        if !anyExists(fwCandidates) {
            missing.append(displayPath(fwCandidates[0]))
        }

        return FlashPrepStatus(
            isReady: missing.isEmpty,
            missingItems: missing,
            buildCommand: target.buildCommand
        )
    }

    private func anyExists(_ paths: [String]) -> Bool {
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        return false
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
