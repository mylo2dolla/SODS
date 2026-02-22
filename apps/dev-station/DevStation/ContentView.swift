import SwiftUI
import UniformTypeIdentifiers
import Foundation
import CoreBluetooth
import Network
import AppKit

struct ContentView: View {
    enum DeviceLifecycleStage: String {
        case staged
        case flashing
        case flashed
        case discovered
        case claimed
        case online
        case offline

        var label: String {
            switch self {
            case .staged: return "Staged"
            case .flashing: return "Flashing"
            case .flashed: return "Waiting for first hello"
            case .discovered: return "Discovered"
            case .claimed: return "Claimed"
            case .online: return "Online"
            case .offline: return "Offline"
            }
        }

        var detail: String {
            switch self {
            case .staged: return "Firmware artifacts staged locally."
            case .flashing: return "Flasher open. Complete USB flash."
            case .flashed: return "Waiting for network/BLE hello."
            case .discovered: return "Device observed. Claim to persist."
            case .claimed: return "Persistent record created."
            case .online: return "Presence verified."
            case .offline: return "Claimed but not responding."
            }
        }
    }
    enum ViewMode: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case systemManager = "System Manager"
        case scanning = "Scanners"
        case interesting = "Cameras/Interesting"
        case allHosts = "All Hosts"
        case ble = "BLE Discovery"
        case spectral = "Analyzer"
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
    @StateObject private var nodeRegistry = NodeRegistry.shared
    @StateObject private var controlPlaneStore = ControlPlaneStore.shared
    @StateObject private var stationProcessManager = StationProcessManager.shared
    @StateObject private var systemManagerStore = SystemManagerStore()
    @AppStorage("consentAcknowledged") private var consentAcknowledged = false
    @AppStorage("bleFindFingerprintID") private var bleFindFingerprintID = ""
    @AppStorage("SODSShowScanDetails") private var showScanDetails = false

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
    @State private var bleDiscoveryEnabled = true
    @State private var networkScanMode: ScanMode = .oneShot
    @State private var bleScanMode: ScanMode = .continuous
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
    @State private var showInterestingDetail = false
    @State private var showAllHostsDetail = false
    @State private var showBleDetail = false
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
    @State private var baseURLValidationMessage: String?
    @State private var baseURLApplyInFlight = false
    @State private var showBaseURLToast = false
    @State private var baseURLToastMessage = ""
    @State private var flashLifecycleStage: DeviceLifecycleStage?
    @State private var flashLifecycleTarget: FlashTarget?
    @State private var flashLifecycleNodeID: String?
    @State private var didBootstrapStack = false
    @State private var stackReconnectInFlight = false
    @State private var fullFleetReconnectInFlight = false
    @State private var fleetStatusOverall = "offline"
    @State private var fleetStatusUpdatedAt: Date?
    @State private var fleetStatusDetail = "No fleet status yet."
    @State private var fleetTargetRows: [FleetTargetStatusRow] = []
    @AppStorage("TargetLockNodeID") private var targetLockNodeID: String = ""
    @StateObject private var rateLimiter = ActionRateLimiter.shared

    var body: some View {
        mainContent
            .toolbar { toolbarContent }
            .overlay(alignment: .top) {
                if showBaseURLToast {
                    baseURLToastView
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(item: $modalCoordinator.activeSheet) { sheet in
                switch sheet {
                case .toolRegistry:
                    ToolRegistryView(
                        registry: toolRegistry,
                        baseURL: sodsStore.baseURL,
                        onFlash: { showFlashPopover = true },
                        onInspect: { endpoint in modalCoordinator.present(.apiInspector(endpoint: endpoint)) },
                        onRunTool: { tool in
                            // Tools are buttons: default behavior is execute.
                            // If a tool truly needs input, it should fail explicitly rather than silently opening a runner.
                            runToolDirectly(tool)
                        },
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
                        onRegisterNode: { payload, candidate, alias in
                            if let nodeID = nodeRegistry.registerFromWhoami(
                                host: candidate.ip,
                                payload: payload,
                                preferredLabel: alias
                            ) {
                                if let alias, !alias.isEmpty {
                                    aliasStore.setAlias(id: nodeID, alias: alias)
                                }
                                markFlashClaimed(nodeID: nodeID)
                                sodsStore.identifyNode(nodeID)
                                sodsStore.refreshStatus()
                            }
                        },
                        onRegisterFallback: { candidate, alias in
                            let seed = (candidate.mac ?? candidate.ip ?? candidate.ssid ?? "portal").lowercased()
                            let compact = seed.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                            let suffix = String(compact.suffix(10))
                            var nodeID = "portal-\(suffix.isEmpty ? "unknown" : suffix)"
                            if let existing = nodeRegistry.nodes.first(where: { $0.id == nodeID }) {
                                let existingMac = existing.mac?.lowercased() ?? ""
                                let nextMac = candidate.mac?.lowercased() ?? ""
                                if !nextMac.isEmpty && !existingMac.isEmpty && existingMac != nextMac {
                                    nodeID = "\(nodeID)-\(Int(Date().timeIntervalSince1970))"
                                }
                            }
                            let label = (alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? alias!
                                : (candidate.ssid ?? candidate.ip ?? candidate.mac ?? nodeID))
                            nodeRegistry.register(
                                nodeID: nodeID,
                                label: label,
                                hostname: nil,
                                ip: candidate.ip,
                                mac: candidate.mac,
                                type: .unknown,
                                capabilities: ["flash", "identify", "scan"]
                            )
                            if let ip = candidate.ip, !ip.isEmpty {
                                aliasStore.setAlias(id: ip, alias: label)
                            }
                            if let mac = candidate.mac, !mac.isEmpty {
                                aliasStore.setAlias(id: mac, alias: label)
                            }
                            aliasStore.setAlias(id: nodeID, alias: label)
                            connectNodeID = nodeID
                            markFlashClaimed(nodeID: nodeID)
                            sodsStore.identifyNode(nodeID)
                            sodsStore.refreshStatus()
                        },
                        onClose: { modalCoordinator.dismiss() }
                    )
                case .consent:
                    ConsentView {
                        consentAcknowledged = true
                        modalCoordinator.dismiss()
                    }
                case .rtspCredentials:
                    VStack(alignment: .leading, spacing: 12) {
                        ModalHeaderView(
                            title: "RTSP Credentials",
                            onBack: nil,
                            onClose: {
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            }
                        )
                        Text("Provide credentials to include in RTSP path probes for this session only.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("Username", text: $rtspPromptUsername)
                        SecureField("Password", text: $rtspPromptPassword)
                        HStack {
                            Button {
                                runRtspTry(with: nil)
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            } label: {
                                Image(systemName: "person.crop.circle.badge.xmark")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Try Without Credentials")
                            .accessibilityLabel(Text("Try Without Credentials"))

                            Button {
                                runRtspTry(with: (rtspPromptUsername, rtspPromptPassword))
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            } label: {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Use Credentials")
                            .accessibilityLabel(Text("Use Credentials"))

                            Button {
                                showRtspCredentialsPrompt = false
                                modalCoordinator.dismiss()
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Cancel")
                            .accessibilityLabel(Text("Cancel"))
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

    private var mainContent: some View {
        let base = mainContentBase
        let lifecycle = applyMainContentLifecycle(to: base)
        return applyMainContentUpdates(to: lifecycle)
    }

    private var mainContentBase: some View {
        Group {
            if usesIndependentScrollLayout {
                independentScrollContent
            } else {
                stackedScrollContent
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func applyMainContentLifecycle<V: View>(to view: V) -> some View {
        view
            .onAppear {
                if !consentAcknowledged { modalCoordinator.present(.consent) }
                if scopeCIDR.isEmpty, let subnet = IPv4Subnet.active() {
                    scopeCIDR = "\(subnet.addressString)/\(subnet.prefixLength)"
                }
                scanner.configureDevStationLogging(logStore)
                applyLaunchOverrides()
                sodsURLText = sodsStore.baseURL
                if let error = sodsStore.baseURLError, !error.isEmpty {
                    baseURLValidationMessage = error
                    showBaseURLToast(error)
                }
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
                for node in piAuxStore.activeNodes {
                    nodeRegistry.observe(node)
                }
                refreshFleetStatusFromDisk()
                nodeRegistry.updateFromPresence(sodsStore.nodePresence)
                rehydrateCoreNodes()
                entityStore.ingestNodes(nodeRegistry.nodes)
                IdentityResolver.shared.updateFromNodes(nodeRegistry.nodes)
                IdentityResolver.shared.updateFromSignals(sodsStore.nodes)
                refreshConnectSelection()
                if flashManager.prepStatus.isReady, flashLifecycleStage == nil {
                    flashLifecycleStage = .staged
                }
                bootstrapStackOnLaunchIfNeeded()
                kickoffRoundupIfRequested()
                Task.detached {
                    await ArtifactStore.shared.runCleanup(log: logStore)
                }
                systemManagerStore.startPolling()
                UIHeartbeatWriter.shared.startIfConfigured()
            }
            .onDisappear {
                systemManagerStore.stopPolling()
                UIHeartbeatWriter.shared.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bleMetadataUpdated)) { _ in
                bleTableWarning = BLEMetadataStore.shared.tableWarning()
            }
            .onReceive(sodsStore.$baseURLNotice) { notice in
                guard let notice, !notice.isEmpty else { return }
                sodsURLText = sodsStore.baseURL
                baseURLValidationMessage = nil
                showBaseURLToast(notice)
                sodsStore.clearBaseURLNotice()
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
            .onReceive(NotificationCenter.default.publisher(for: .openScanningViewCommand)) { _ in
                viewMode = .scanning
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectNodeCommand)) { _ in
                viewMode = .nodes
                guard !connectNodeID.isEmpty else { return }
                NodeRegistry.shared.setConnecting(nodeID: connectNodeID, connecting: true)
                sodsStore.connectNode(connectNodeID)
                sodsStore.identifyNode(connectNodeID)
                sodsStore.refreshStatus()
                piAuxStore.connectNode(connectNodeID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigatePreviousViewCommand)) { _ in
                goToPreviousView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateNextViewCommand)) { _ in
                goToNextView()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sodsDeepLinkCommand)) { note in
                guard let url = note.object as? URL else { return }
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .targetLockNodeCommand)) { note in
                if let id = note.object as? String {
                    targetLockNodeID = id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGodMenuCommand)) { _ in
                toolRegistry.reload()
                runbookRegistry.reload()
                showGodMenu = true
            }
    }

    private func applyMainContentUpdates<V: View>(to view: V) -> some View {
        view
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
                for node in piAuxStore.activeNodes {
                    nodeRegistry.observe(node)
                }
                entityStore.ingestNodes(nodeRegistry.nodes)
                refreshConnectSelection()
            }
            .onChange(of: sodsStore.nodes) { _ in
                IdentityResolver.shared.updateFromSignals(sodsStore.nodes)
                refreshConnectSelection()
            }
            .onChange(of: sodsStore.baseURL) { newValue in
                sodsURLText = newValue
                baseURLValidationMessage = nil
            }
            .onChange(of: sodsStore.nodePresence) { _ in
                nodeRegistry.updateFromPresence(sodsStore.nodePresence)
                rehydrateCoreNodes()
                entityStore.ingestNodes(nodeRegistry.nodes)
                refreshConnectSelection()
                updateFlashLifecycleFromPresence()
            }
            .onChange(of: nodeRegistry.nodes) { _ in
                entityStore.ingestNodes(nodeRegistry.nodes)
                IdentityResolver.shared.updateFromNodes(nodeRegistry.nodes)
                refreshConnectSelection()
                if let nodeID = flashLifecycleNodeID,
                   nodeRegistry.nodes.contains(where: { $0.id == nodeID }) {
                    if flashLifecycleStage == .discovered || flashLifecycleStage == .flashed {
                        flashLifecycleStage = .claimed
                    }
                }
            }
            .onChange(of: scanner.isScanning) { _ in
                updateLocalScanningState()
            }
            .onChange(of: bleScanner.isScanning) { _ in
                updateLocalScanningState()
            }
            .onChange(of: flashManager.prepStatus) { status in
                if status.isReady, flashLifecycleStage == nil {
                    flashLifecycleStage = .staged
                }
            }
            .onChange(of: selectedBleID) { newValue in
                if viewMode == .ble {
                    showBleDetail = newValue != nil
                }
                guard let id = newValue else { return }
                if let peripheral = entityStore.blePeripherals.first(where: { $0.id == id }) {
                    entityStore.select(id: peripheral.fingerprintID, kind: .ble)
                }
            }
            .onChange(of: showRtspCredentialsPrompt) { show in
                if show { modalCoordinator.present(.rtspCredentials) }
            }
    }

    private var independentScrollContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            logSection
        }
    }

    private var stackedScrollContent: some View {
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
    }

    private var usesIndependentScrollLayout: Bool {
        switch viewMode {
        case .systemManager, .scanning, .interesting, .allHosts, .ble, .spectral:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        TopControlStripView(
            baseURLText: $sodsURLText,
            baseURLValidationMessage: baseURLValidationMessage,
            baseURLApplyInFlight: baseURLApplyInFlight,
            showScanDetails: $showScanDetails,
            showGodMenu: $showGodMenu,
            showFlashPopover: $showFlashPopover,
            subnetDescription: scanner.subnetDescription,
            stationHealthLabel: sodsStore.health.label,
            stationHealthColor: Color(sodsStore.health.color),
            opsFeedStatusLabel: opsFeedStatusLabel,
            opsFeedStatusColor: opsFeedStatusColor,
            nodeCount: sodsStore.nodes.count,
            lastIngestText: sodsStore.lastPoll?.formatted(date: .omitted, time: .standard),
            scanStatusLabel: scanner.isScanning ? "Yes" : "No",
            hostCount: entityStore.hosts.count,
            bleStatusLabel: bleScanner.stateDescription,
            scanProgress: scanner.progress.map {
                TopControlStripScanProgress(scannedHosts: $0.scannedHosts, totalHosts: $0.totalHosts)
            },
            scanStatusMessage: scanner.statusMessage,
            bleAvailabilityMessage: bleScanner.isAvailableForScan ? nil : bleAvailabilityMessage(),
            onApplyBaseURL: {
                applyBaseURLInput(sodsURLText)
            },
            onResetBaseURL: {
                sodsStore.resetBaseURL()
                sodsURLText = sodsStore.baseURL
                baseURLValidationMessage = nil
                showBaseURLToast("Base URL reset to \(sodsStore.baseURL)")
            },
            onInspectAPI: {
                modalCoordinator.present(.apiInspector(endpoint: .status))
            },
            onOpenSpectrum: {
                viewMode = .spectral
            },
            onPrepareGodMenu: {
                toolRegistry.reload()
                runbookRegistry.reload()
            },
            godSections: {
                godButtonSections()
            },
            flashPopoverContent: {
                FlashPopoverView(
                    status: sodsStore.health,
                    onFlashEsp32: { startFlash(target: .esp32dev, autoOpenFlasher: true, autoOpenFindDevice: true) },
                    onFlashEsp32c3: { startFlash(target: .esp32c3, autoOpenFlasher: true, autoOpenFindDevice: true) },
                    onFlashPortalCyd: { startFlash(target: .portalCyd, autoOpenFlasher: true, autoOpenFindDevice: true) },
                    onFlashP4: { startFlash(target: .esp32p4, autoOpenFlasher: true, autoOpenFindDevice: true) },
                    onOpenWebTools: { openFlashPath("/flash/") }
                )
            }
        )
    }

    @ViewBuilder
    private var contentSection: some View {
        if viewMode == .dashboard {
                    DashboardView(
                        stationProcess: stationProcessManager,
                        scanner: scanner,
                        bleScanner: bleScanner,
                        piAuxStore: piAuxStore,
                        entityStore: entityStore,
                        sodsStore: sodsStore,
                        controlPlane: controlPlaneStore,
                        vaultTransport: vaultTransport,
                        systemSnapshot: systemManagerStore.snapshot,
                        connectingNodeIDs: nodeRegistry.connectingNodeIDs,
                        inboxStatus: inboxStatus,
                        retentionDays: inboxRetentionDays,
                        retentionMaxGB: inboxMaxGB,
                onvifDiscoveryEnabled: onvifDiscoveryEnabled,
                serviceDiscoveryEnabled: serviceDiscoveryEnabled,
                arpWarmupEnabled: arpWarmupEnabled,
                bleDiscoveryEnabled: bleScanner.isScanning,
                safeModeEnabled: scanner.safeModeEnabled,
                onlyLocalSubnet: onlyLocalSubnet,
                stackReconnectInFlight: stackReconnectInFlight,
                fullFleetReconnectInFlight: fullFleetReconnectInFlight,
                fleetStatusOverall: fleetStatusOverall,
                fleetStatusUpdatedAt: fleetStatusUpdatedAt,
                fleetStatusDetail: fleetStatusDetail,
                fleetTargetRows: fleetTargetRows,
                onOpenNodes: {
                    viewMode = .nodes
                },
                onStartScan: {
                    startNetworkScan()
                },
                onStopScan: {
                    stopAllScanning()
                },
                onGenerateScanReport: {
                    generateScanReport()
                },
                onStartStation: {
                    startStationFromDashboard()
                },
                onReconnectStation: {
                    reconnectStationFromDashboard()
                },
                onReconnectControlPlane: {
                    reconnectControlPlaneFromDashboard()
                },
                onRestartRelay: {
                    restartPiAuxRelayFromDashboard()
                },
                onReconnectStack: {
                    reconnectEntireStackFromDashboard()
                },
                onReconnectFullFleet: {
                    reconnectFullFleetFromDashboard()
                },
                onRefreshFleetStatus: {
                    refreshFleetStatusFromDashboard()
                },
                onOpenSystemManager: {
                    openSystemManagerFromDashboard(optimize: false)
                },
                onOptimizeSystemManager: {
                    openSystemManagerFromDashboard(optimize: true)
                },
                stationActionSections: { dashboardStationSections() },
                scanActionSections: { dashboardScanSections() },
                eventsActionSections: { dashboardEventsSections() },
                vaultActionSections: { dashboardVaultSections() },
                inboxActionSections: { dashboardInboxSections() }
            )
        } else if viewMode == .systemManager {
            SystemManagerView(store: systemManagerStore)
        } else if viewMode == .scanning {
            ScanningView(
                scanner: scanner,
                bleScanner: bleScanner,
                sodsStore: sodsStore,
                piAuxStore: piAuxStore,
                nodes: entityStore.nodes,
                nodePresence: sodsStore.nodePresence,
                connectingNodeIDs: nodeRegistry.connectingNodeIDs,
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
                onStartNetworkScan: {
                    startNetworkScan()
                },
                onStopAllScanning: {
                    stopAllScanning()
                },
                onSetBLEScanning: { enabled in
                    setBLEScanning(enabled)
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
                onRestoreCoreNodes: {
                    restoreCoreNodesFromNodesView()
                },
                onOpenNodes: {
                    viewMode = .nodes
                },
                onOpenNodeInNodes: { nodeID in
                    openNodeInNodesView(nodeID: nodeID)
                },
                onRefreshNode: { nodeID in
                    refreshNodeConnection(nodeID: nodeID)
                },
                onIdentifyNode: { nodeID in
                    identifyNode(nodeID: nodeID)
                },
                onProbeNode: { nodeID in
                    probeNode(nodeID: nodeID)
                },
                onSetNodeScan: { nodeID, enabled in
                    setNodeScan(nodeID: nodeID, enabled: enabled)
                }
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
                connectingNodeIDs: nodeRegistry.connectingNodeIDs,
                scanner: scanner,
                flashManager: flashManager,
                connectCandidates: connectCandidates,
                discoveredNodes: discoveredNodes,
                flashLifecycleStage: flashLifecycleStage,
                flashLifecycleTarget: flashLifecycleTarget,
                flashLifecycleNodeID: flashLifecycleNodeID,
                bleDiscoveryEnabled: $bleDiscoveryEnabled,
                networkScanMode: $networkScanMode,
                connectNodeID: $connectNodeID,
                showFlashConfirm: $showFlashConfirm,
                onStartScan: {
                    startNetworkScan()
                },
                onStopScan: {
                    stopAllScanning()
                },
                onGenerateScanReport: {
                    generateScanReport()
                },
                onFindDevice: { openFindDevice() },
                onFlashStarted: { target in markFlashStarted(target: target) },
                onFlashAwaitingHello: { markFlashAwaitingHello() },
                onFlashClaimed: { nodeID in markFlashClaimed(nodeID: nodeID) }
            )
        } else if viewMode == .buttons {
            PresetButtonsView(
                registry: presetRegistry,
                onRunPreset: { preset in runPresetDirectly(preset) },
                onOpenRunner: { preset in modalCoordinator.present(.presetRunner(preset: preset)) },
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
        .onChange(of: selectedIP) { newValue in
            if viewMode == .interesting {
                showInterestingDetail = newValue != nil
            }
        }
        .sheet(isPresented: Binding(
            get: { showInterestingDetail && viewMode == .interesting && selectedIP != nil },
            set: { showInterestingDetail = $0 }
        )) {
            interestingDetailSheet
        }
        .frame(maxHeight: .infinity)
    }

    private var interestingDetailSheet: some View {
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
            },
            onBack: {
                showInterestingDetail = false
            },
            onClose: {
                showInterestingDetail = false
                selectedIP = nil
            }
        )
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var allHostsDetailSheet: some View {
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
            },
            onBack: {
                showAllHostsDetail = false
            },
            onClose: {
                showAllHostsDetail = false
                selectedIP = nil
            }
        )
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var bleDetailSheet: some View {
        BLEDetailView(
            peripheral: selectedBlePeripheral,
            prober: bleProber,
            findFingerprintID: $bleFindFingerprintID,
            aliasForPeripheral: { peripheral in
                IdentityResolver.shared.resolveLabel(keys: [peripheral.fingerprintID, peripheral.id.uuidString])
            },
            onGenerateScanReport: { generateScanReport() },
            onRevealLatestReport: { revealLatestReport() },
            onExportAudit: { exportAudit() },
            onExportRuntimeLog: { exportRuntimeLog() },
            onRevealExports: { revealExports() },
            onShipNow: { vaultTransport.shipNow(log: logStore) },
            onBack: {
                showBleDetail = false
            },
            onClose: {
                showBleDetail = false
                selectedBleID = nil
            }
        )
        .frame(minWidth: 420, minHeight: 320)
    }

    private var allHostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
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
                    allHostsActionButtons
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Search IP or hostname", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 10) {
                        Toggle("Show ARP-only", isOn: $showArpOnly)
                            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                        Toggle("Show Alive Only", isOn: $showAliveOnly)
                            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                        Toggle("Show High Confidence Only", isOn: $showHighConfidenceOnly)
                            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    }
                    HStack(spacing: 10) {
                        allHostsActionButtons
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
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 0) {
                HostTable(
                    hosts: filteredHosts,
                    selectedIP: $selectedIP,
                    aliasForHost: { host in aliasForDevice(ip: host.ip, host: host, device: nil) }
                )
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: selectedIP) { newValue in
            if viewMode == .allHosts {
                showAllHostsDetail = newValue != nil
            }
        }
        .sheet(isPresented: Binding(
            get: { showAllHostsDetail && viewMode == .allHosts && selectedIP != nil },
            set: { showAllHostsDetail = $0 }
        )) {
            allHostsDetailSheet
        }
    }

    private var allHostsActionButtons: some View {
        Group {
            Button {
                scanner.refreshARP()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Refresh ARP")
            .accessibilityLabel(Text("Refresh ARP"))

            Button {
                OUIStore.shared.importFromOpenPanel(log: logStore)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Import OUI File")
            .accessibilityLabel(Text("Import OUI File"))

            Button {
                exportHosts()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Export")
            .accessibilityLabel(Text("Export"))

            Button {
                revealExports()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Reveal Exports")
            .accessibilityLabel(Text("Reveal Exports"))
        }
    }

    private var bleSection: some View {
        BLEListView(
            scanner: bleScanner,
            peripherals: entityStore.blePeripherals,
            aliasForPeripheral: { peripheral in
                IdentityResolver.shared.resolveLabel(keys: [peripheral.fingerprintID, peripheral.id.uuidString])
            },
            selectedID: $selectedBleID,
            findFingerprintID: $bleFindFingerprintID,
            warningText: bleTableWarning,
            onSelectRow: {
                if viewMode == .ble {
                    showBleDetail = true
                }
            }
        )
        .sheet(isPresented: Binding(
            get: { showBleDetail && viewMode == .ble && selectedBlePeripheral != nil },
            set: { showBleDetail = $0 }
        )) {
            bleDetailSheet
        }
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
        ToolbarItemGroup(placement: .navigation) {
            Text("SODS Dev Station")
                .font(.system(size: 16, weight: .semibold))
            Button { openSODSTools() } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .semibold))
            }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Tools")
                .accessibilityLabel(Text("Tools"))

            Button { modalCoordinator.present(.consent) } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Guide")
                .accessibilityLabel(Text("Guide"))

            Button { modalCoordinator.present(.aliasManager) } label: {
                Image(systemName: "tag")
                    .font(.system(size: 13, weight: .semibold))
            }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Aliases")
                .accessibilityLabel(Text("Aliases"))
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Button {
                    goToPreviousView()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Previous Page")
                .accessibilityLabel(Text("Previous Page"))

                Menu {
                    ForEach(ViewMode.allCases) { mode in
                        Button {
                            viewMode = mode
                        } label: {
                            if mode == viewMode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(viewMode.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.panelAlt)
                    .overlay(
                        Capsule()
                            .stroke(Theme.border.opacity(0.8), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .help("Jump To Page")
                .accessibilityLabel(Text("Page Switcher"))

                Button {
                    goToNextView()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Next Page")
                .accessibilityLabel(Text("Next Page"))
            }
        }
    }

    private var selectedDevice: Device? {
        guard let selectedIP = selectedIP else { return nil }
        return AppTruth.shared.resolveDevice(ip: selectedIP, scanner: scanner)
    }

    private var selectedBlePeripheral: BLEPeripheral? {
        guard let selectedBleID = selectedBleID else { return nil }
        if let peripheral = entityStore.blePeripherals.first(where: { $0.id == selectedBleID }) {
            return peripheral
        }
        return bleScanner.peripherals.first(where: { $0.id == selectedBleID })
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

    private func readCredential(_ ip: String, field: String) -> String {
        let key = credentialsKey(ip, field: field)
        if let value = try? SecureStore.string(for: key) {
            return value
        }
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: key) {
            do {
                try SecureStore.setString(legacy, for: key)
                defaults.removeObject(forKey: key)
                logStore.log(.info, "Migrated \(field) credential for \(ip) to Keychain")
            } catch {
                logStore.log(.error, "Failed migrating \(field) credential for \(ip): \(error.localizedDescription)")
            }
            return legacy
        }
        return ""
    }

    private func writeCredential(_ value: String, ip: String, field: String) {
        let key = credentialsKey(ip, field: field)
        do {
            if value.isEmpty {
                try SecureStore.remove(key)
            } else {
                try SecureStore.setString(value, for: key)
            }
            UserDefaults.standard.removeObject(forKey: key)
        } catch {
            logStore.log(.error, "Failed storing \(field) credential for \(ip) in Keychain: \(error.localizedDescription)")
        }
    }

    private func loadCredentials(for ip: String) {
        credentialIP = ip
        credentialUsername = readCredential(ip, field: "username")
        credentialPassword = readCredential(ip, field: "password")
        credentialsAutofilled = !credentialUsername.isEmpty || !credentialPassword.isEmpty
    }

    private func cachedCredentials(for ip: String) -> (String, String) {
        let username = readCredential(ip, field: "username")
        let password = readCredential(ip, field: "password")
        return (username, password)
    }

    private func saveCredentials(for ip: String, username: String, password: String) {
        writeCredential(username, ip: ip, field: "username")
        writeCredential(password, ip: ip, field: "password")
        if !didLogCredentialStorage {
            didLogCredentialStorage = true
            logStore.log(.info, "Credentials stored in Keychain")
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

    private func startNetworkScan() {
        let scope = makeScope()
        scanner.startScan(
            enableOnvifDiscovery: onvifDiscoveryEnabled,
            enableServiceDiscovery: serviceDiscoveryEnabled,
            enableArpWarmup: arpWarmupEnabled,
            scope: scope,
            mode: networkScanMode
        )
        piAuxStore.setNodeScanning(nodeID: piAuxStore.localNodeIdentifier, enabled: true)
        piAuxStore.refreshLocalNodeHeartbeat()
    }

    private func setBLEScanning(_ enabled: Bool) {
        if bleDiscoveryEnabled != enabled {
            bleDiscoveryEnabled = enabled
            return
        }
        if enabled {
            if !bleScanner.isScanning {
                bleScanner.startScan(mode: bleScanMode)
            }
        } else if bleScanner.isScanning {
            bleScanner.stopScan()
        }
        updateLocalScanningState()
    }

    private func requestOneShotBLEScan() {
        if bleDiscoveryEnabled {
            bleDiscoveryEnabled = false
        } else if bleScanner.isScanning {
            bleScanner.stopScan()
        }
        bleScanner.startScan(mode: .oneShot)
        updateLocalScanningState()
    }

    private func refreshNodeConnection(nodeID: String) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        if trimmedID == "mac16" {
            refreshFleetStatusFromDisk()
            rehydrateCoreNodes()
            entityStore.ingestNodes(nodeRegistry.nodes)
            sodsStore.refreshStatus()
            return
        }
        NodeRegistry.shared.setConnecting(nodeID: trimmedID, connecting: true)
        sodsStore.connectNode(trimmedID)
        sodsStore.identifyNode(trimmedID)
        sodsStore.refreshStatus()
        piAuxStore.connectNode(trimmedID)
    }

    private func identifyNode(nodeID: String) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        sodsStore.identifyNode(trimmedID)
        sodsStore.refreshStatus()
    }

    private func probeNode(nodeID: String) {
        refreshNodeConnection(nodeID: nodeID)
    }

    private func setNodeScan(nodeID: String, enabled: Bool) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        sodsStore.setNodeCapability(nodeID: trimmedID, capability: "scan", enabled: enabled)
        sodsStore.refreshStatus()
    }

    private func openNodeInNodesView(nodeID: String) {
        let trimmedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedID.isEmpty {
            targetLockNodeID = trimmedID
            connectNodeID = trimmedID
        }
        viewMode = .nodes
    }

    private func goToPreviousView() {
        navigateView(by: -1)
    }

    private func goToNextView() {
        navigateView(by: 1)
    }

    private func navigateView(by offset: Int) {
        let allViews = ViewMode.allCases
        guard !allViews.isEmpty, let currentIndex = allViews.firstIndex(of: viewMode) else { return }
        let nextIndex = (currentIndex + offset + allViews.count) % allViews.count
        viewMode = allViews[nextIndex]
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

    private var discoveredNodes: [DiscoveredNodeItem] {
        let claimedIDs = Set(nodeRegistry.nodes.map { $0.id })
        return sodsStore.nodePresence.values.compactMap { presence in
            let nodeID = presence.nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nodeID.isEmpty, !claimedIDs.contains(nodeID) else { return nil }
            let label = (presence.hostname ?? presence.ip ?? nodeID).trimmingCharacters(in: .whitespacesAndNewlines)
            let lastSeen = presence.lastSeen > 0 ? Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000.0) : nil
            return DiscoveredNodeItem(id: nodeID, label: label.isEmpty ? nodeID : label, lastSeen: lastSeen, presence: presence)
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private var connectCandidates: [ConnectCandidate] {
        var items: [String: ConnectCandidate] = [:]
        for node in nodeRegistry.nodes {
            let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = label.isEmpty ? node.id : label
            items[node.id] = ConnectCandidate(id: node.id, label: display, isClaimed: true, lastSeen: node.lastSeen ?? node.lastHeartbeat)
        }
        for item in discoveredNodes where items[item.id] == nil {
            items[item.id] = ConnectCandidate(id: item.id, label: item.label, isClaimed: false, lastSeen: item.lastSeen)
        }
        return items.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func connectableNodeIDs() -> [String] {
        connectCandidates.map { $0.id }
    }

    private func refreshConnectSelection() {
        let ids = connectCandidates.map { $0.id }
        if ids.isEmpty {
            connectNodeID = ""
            return
        }
        if connectNodeID.isEmpty || !ids.contains(connectNodeID) {
            connectNodeID = ids[0]
        }
    }

    private func godButtonSections() -> [ActionMenuSection] {
        let isBleTab = viewMode == .ble
        let isNodesTab = viewMode == .nodes
        let lockedNode = targetLockNodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : nodeRegistry.nodes.first(where: { $0.id == targetLockNodeID })
        let isTargetLocked = lockedNode != nil
        let nowItems: [ActionMenuItem] = {
            var items: [ActionMenuItem] = []
            if let lockedNode {
                items.append(ActionMenuItem(
                    title: "Clear Target Lock (\(lockedNode.label))",
                    systemImage: "scope",
                    enabled: true,
                    reason: nil,
                    action: { targetLockNodeID = "" }
                ))
                items.append(ActionMenuItem(
                    title: "Connect + Identify (\(lockedNode.label))",
                    systemImage: "link",
                    enabled: true,
                    reason: nil,
                    action: {
                        Task {
                            let gate = await MainActor.run {
                                rateLimiter.canFire(key: "target.connectIdentify:\(lockedNode.id)", cooldownSeconds: 1.0)
                            }
                            guard gate.ok else {
                                await MainActor.run {
                                    showBaseURLToast("Cooldown: \(Int(ceil(gate.remaining)))s")
                                }
                                return
                            }
                            await MainActor.run {
                                rateLimiter.markFired(key: "target.connectIdentify:\(lockedNode.id)")
                                NodeRegistry.shared.setConnecting(nodeID: lockedNode.id, connecting: true)
                                sodsStore.connectNode(lockedNode.id)
                                sodsStore.identifyNode(lockedNode.id)
                                sodsStore.refreshStatus()
                                piAuxStore.connectNode(lockedNode.id)
                            }
                        }
                    }
                ))
            }
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
                        requestOneShotBLEScan()
                    }
                ))
            }
            if isNodesTab {
                items.append(ActionMenuItem(
                    title: "Connect Node",
                    systemImage: "link",
                    enabled: !isTargetLocked,
                    reason: nil,
                        action: {
                            let target = !connectNodeID.isEmpty ? connectNodeID : (self.connectCandidates.first?.id ?? "")
                            guard !target.isEmpty else { return }
                            connectNodeID = target
                            NodeRegistry.shared.setConnecting(nodeID: target, connecting: true)
                            sodsStore.connectNode(target)
                            sodsStore.identifyNode(target)
                            sodsStore.refreshStatus()
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
                    action: { runRunbookImmediately(runbook) }
                ))
            }
            return items
        }()

        let inspectItems: [ActionMenuItem] = stationInspectItems()

        let connectItems: [ActionMenuItem] = [
            ActionMenuItem(title: "Connect Node", systemImage: "link", enabled: true, reason: nil, action: {
                let target = !connectNodeID.isEmpty ? connectNodeID : (self.connectCandidates.first?.id ?? "")
                guard !target.isEmpty else { return }
                connectNodeID = target
                NodeRegistry.shared.setConnecting(nodeID: target, connecting: true)
                sodsStore.connectNode(target)
                sodsStore.identifyNode(target)
                sodsStore.refreshStatus()
                piAuxStore.connectNode(target)
            })
        ]

        let nodeControlItems = dynamicNodeControlItems()

        let flashItems: [ActionMenuItem] = [
            ActionMenuItem(title: "Find Newly Flashed Device", systemImage: "magnifyingglass", enabled: true, reason: nil, action: {
                markFlashAwaitingHello()
                openFindDevice()
            })
        ]

        let exportItems: [ActionMenuItem] = exportMenuItems()

        let agentItems: [ActionMenuItem] = {
            let target = lockedNode?.id
            let scope = isTargetLocked ? "tier1" : "all"
            let reason = isTargetLocked ? "app-god-button-target" : "app-god-button"

            func item(_ title: String, _ systemImage: String, _ action: String) -> ActionMenuItem {
                ActionMenuItem(
                    title: title,
                    systemImage: systemImage,
                    enabled: true,
                    reason: nil,
                    action: {
                        Task {
                            let allowed = await MainActor.run { () -> Bool in
                                let key = "god.action:\(action):\(target ?? scope)"
                                let gate = rateLimiter.canFire(key: key, cooldownSeconds: 1.0)
                                if gate.ok {
                                    rateLimiter.markFired(key: key)
                                    return true
                                }
                                return false
                            }
                            if !allowed { return }
                            let result = await GodGatewayClient.postAction(
                                action: action,
                                scope: scope,
                                target: target,
                                reason: reason,
                                args: [:]
                            )
                            await MainActor.run {
                                showBaseURLToast(result.ok ? "God OK: \(action)" : "God FAIL: \(action)")
                            }
                        }
                    }
                )
            }

            let suffix = isTargetLocked ? " (Target)" : ""
            return [
                item("Rollcall" + suffix, "person.3.sequence", "ritual.rollcall"),
                item("Services Snapshot" + suffix, "waveform.path.ecg", "snapshot.services"),
                item("LAN Scan" + suffix, "dot.radiowaves.left.and.right", "scan.lan.fast"),
                item("Ports Top" + suffix, "point.3.connected.trianglepath.dotted", "scan.lan.ports.top"),
                item("Wi-Fi Snapshot" + suffix, "wifi", "scan.wifi.snapshot"),
                item("BLE Sweep" + suffix, "antenna.radiowaves.left.and.right", "scan.ble.sweep"),
            ]
        }()

        var sections: [ActionMenuSection] = []
        if !nowItems.isEmpty { sections.append(ActionMenuSection(title: "Now", items: nowItems)) }
        if !agentItems.isEmpty { sections.append(ActionMenuSection(title: "Agents", items: agentItems)) }
        let toolItems = toolRegistry.tools.map { tool in
            ActionMenuItem(
                title: tool.title ?? tool.name,
                systemImage: "wrench.and.screwdriver",
                enabled: true,
                reason: nil,
                action: { runToolImmediately(tool) }
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
                action: { runRunbookImmediately(runbook) }
            )
        }
        if !runbookItems.isEmpty {
            sections.append(ActionMenuSection(title: "Runbooks", items: runbookItems))
        }
        sections.append(ActionMenuSection(title: "Inspect", items: inspectItems))
        sections.append(ActionMenuSection(title: "Connect / Control", items: connectItems))
        if !nodeControlItems.isEmpty {
            sections.append(ActionMenuSection(title: "Node Control", items: nodeControlItems))
        }
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

    private var opsFeedStatusLabel: String {
        if let logger = sodsStore.loggerStatus {
            if let ok = logger.ok {
                return ok ? "Connected" : "Degraded"
            }
            if let status = logger.status, !status.isEmpty {
                return status
            }
        }
        return "Unknown"
    }

    private var opsFeedStatusColor: Color {
        if let logger = sodsStore.loggerStatus, let ok = logger.ok {
            return ok ? .green : .orange
        }
        return .secondary
    }

    private func dynamicNodeControlItems() -> [ActionMenuItem] {
        let claimedNodes = nodeRegistry.nodes
        guard !claimedNodes.isEmpty else { return [] }
        let selectedID = !connectNodeID.isEmpty ? connectNodeID : claimedNodes.first?.id ?? ""
        guard let selectedNode = claimedNodes.first(where: { $0.id == selectedID }) ?? claimedNodes.first else { return [] }
        var items: [ActionMenuItem] = []
        let profile = NodeFirmwareProfile.infer(nodeID: selectedNode.id, hostname: selectedNode.hostname, capabilities: selectedNode.capabilities)
        let effectiveCaps = Set((selectedNode.capabilities + profile.defaultCapabilities).map { $0.lowercased() })
        let supportsScan = effectiveCaps.contains("scan")
        let supportsFrames = effectiveCaps.contains("frames")
        let supportsProbe = effectiveCaps.contains("probe")
        let supportsPing = effectiveCaps.contains("ping")
        let supportsGod = effectiveCaps.contains("god") || profile == .p4GodButton

        items.append(
            ActionMenuItem(
                title: "Connect \(selectedNode.label)",
                systemImage: "link",
                enabled: true,
                reason: nil,
                action: {
                    NodeRegistry.shared.setConnecting(nodeID: selectedNode.id, connecting: true)
                    sodsStore.connectNode(selectedNode.id)
                    sodsStore.identifyNode(selectedNode.id)
                    sodsStore.refreshStatus()
                }
            )
        )
        if supportsGod {
            items.append(
                ActionMenuItem(
                    title: "God On (\(selectedNode.id))",
                    systemImage: "bolt.fill",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "god", enabled: true) }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "God Off (\(selectedNode.id))",
                    systemImage: "bolt.slash",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "god", enabled: false) }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "God On (All Nodes)",
                    systemImage: "bolt.circle",
                    enabled: true,
                    reason: nil,
                    action: {
                        for node in claimedNodes {
                            let nodeProfile = NodeFirmwareProfile.infer(nodeID: node.id, hostname: node.hostname, capabilities: node.capabilities)
                            let nodeCaps = Set((node.capabilities + nodeProfile.defaultCapabilities).map { $0.lowercased() })
                            if nodeCaps.contains("god") || nodeProfile == .p4GodButton {
                                sodsStore.setNodeCapability(nodeID: node.id, capability: "god", enabled: true)
                            }
                        }
                    }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "God Off (All Nodes)",
                    systemImage: "bolt.slash.circle",
                    enabled: true,
                    reason: nil,
                    action: {
                        for node in claimedNodes {
                            let nodeProfile = NodeFirmwareProfile.infer(nodeID: node.id, hostname: node.hostname, capabilities: node.capabilities)
                            let nodeCaps = Set((node.capabilities + nodeProfile.defaultCapabilities).map { $0.lowercased() })
                            if nodeCaps.contains("god") || nodeProfile == .p4GodButton {
                                sodsStore.setNodeCapability(nodeID: node.id, capability: "god", enabled: false)
                            }
                        }
                    }
                )
            )
        }
        if supportsScan {
            items.append(
                ActionMenuItem(
                    title: "Start Node Scan (\(selectedNode.id))",
                    systemImage: "dot.radiowaves.left.and.right",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "scan", enabled: true) }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "Stop Node Scan (\(selectedNode.id))",
                    systemImage: "stop.circle",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "scan", enabled: false) }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "Start All Node Scans",
                    systemImage: "play.circle",
                    enabled: true,
                    reason: nil,
                    action: {
                        for node in claimedNodes where node.capabilities.contains("scan") {
                            sodsStore.setNodeCapability(nodeID: node.id, capability: "scan", enabled: true)
                        }
                    }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "Stop All Node Scans",
                    systemImage: "stop.circle",
                    enabled: true,
                    reason: nil,
                    action: {
                        for node in claimedNodes where node.capabilities.contains("scan") {
                            sodsStore.setNodeCapability(nodeID: node.id, capability: "scan", enabled: false)
                        }
                    }
                )
            )
        }
        if supportsFrames {
            items.append(
                ActionMenuItem(
                    title: "Enable Frames (\(selectedNode.id))",
                    systemImage: "waveform.path.ecg",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "frames", enabled: true) }
                )
            )
            items.append(
                ActionMenuItem(
                    title: "Disable Frames (\(selectedNode.id))",
                    systemImage: "waveform.path",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "frames", enabled: false) }
                )
            )
        }
        if supportsProbe {
            items.append(
                ActionMenuItem(
                    title: "Probe Node (\(selectedNode.id))",
                    systemImage: "scope",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "probe", enabled: true) }
                )
            )
        }
        if supportsPing {
            items.append(
                ActionMenuItem(
                    title: "Ping Node (\(selectedNode.id))",
                    systemImage: "dot.radiowaves.left.and.right",
                    enabled: true,
                    reason: nil,
                    action: { sodsStore.setNodeCapability(nodeID: selectedNode.id, capability: "ping", enabled: true) }
                )
            )
        }
        return items
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
                requestOneShotBLEScan()
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

    private func runToolImmediately(_ tool: ToolDefinition) {
        guard let url = URL(string: sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tool/run") else {
            LogStore.logAsync(.warn, "God Button tool failed: invalid station URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": tool.name,
            "input": [String: String]()
        ])
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let output = String(data: data, encoding: .utf8) ?? ""
                if (200...299).contains(status) {
                    LogStore.logAsync(.info, "God Button ran tool \(tool.name): HTTP \(status)")
                } else {
                    LogStore.logAsync(.warn, "God Button tool \(tool.name) failed: HTTP \(status) \(output)")
                }
                toolRegistry.reload()
                runbookRegistry.reload()
            } catch {
                LogStore.logAsync(.warn, "God Button tool \(tool.name) error: \(error.localizedDescription)")
            }
        }
    }

    private func runRunbookImmediately(_ runbook: RunbookDefinition) {
        guard let url = URL(string: sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/runbook/run") else {
            LogStore.logAsync(.warn, "God Button runbook failed: invalid station URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": runbook.id,
            "input": [String: String]()
        ])
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let output = String(data: data, encoding: .utf8) ?? ""
                if (200...299).contains(status) {
                    LogStore.logAsync(.info, "God Button ran runbook \(runbook.id): HTTP \(status)")
                } else {
                    LogStore.logAsync(.warn, "God Button runbook \(runbook.id) failed: HTTP \(status) \(output)")
                }
                runbookRegistry.reload()
            } catch {
                LogStore.logAsync(.warn, "God Button runbook \(runbook.id) error: \(error.localizedDescription)")
            }
        }
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

    private func flashTarget(from path: String) -> FlashTarget? {
        switch path {
        case "/flash/esp32":
            return .esp32dev
        case "/flash/esp32c3":
            return .esp32c3
        case "/flash/portal-cyd":
            return .portalCyd
        case "/flash/p4":
            return .esp32p4
        default:
            return nil
        }
    }

    private func markFlashStarted(target: FlashTarget?) {
        guard let target else { return }
        flashLifecycleTarget = target
        flashLifecycleNodeID = nil
        flashLifecycleStage = .flashing
    }

    private func markFlashAwaitingHello() {
        guard flashLifecycleStage != nil || flashLifecycleTarget != nil else { return }
        flashLifecycleStage = .flashed
    }

    private func markFlashDiscovered(nodeID: String) {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        flashLifecycleNodeID = trimmed
        flashLifecycleStage = .discovered
    }

    private func markFlashClaimed(nodeID: String) {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        flashLifecycleNodeID = trimmed
        flashLifecycleStage = .claimed
        updateFlashLifecycleFromPresence()
    }

    private func updateFlashLifecycleFromPresence() {
        guard let stage = flashLifecycleStage else { return }
        if (stage == .flashing || stage == .flashed) {
            if let candidate = discoveredNodes.first {
                markFlashDiscovered(nodeID: candidate.id)
            }
        }
        guard let nodeID = flashLifecycleNodeID,
              let presence = sodsStore.nodePresence[nodeID] else { return }
        let state = presence.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["online", "idle", "scanning", "connected"].contains(state),
           stage == .claimed || stage == .online {
            flashLifecycleStage = .online
        } else if stage == .claimed || stage == .online {
            flashLifecycleStage = .offline
        }
    }

    private func openFindDevice() {
        modalCoordinator.present(.findDevice)
    }

    private var baseURLToastView: some View {
        Text(baseURLToastMessage)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .padding(.top, 12)
    }

    private func showBaseURLToast(_ message: String) {
        baseURLToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showBaseURLToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showBaseURLToast = false
            }
        }
    }

    private func shouldRunToolDirectly(_ tool: ToolDefinition) -> Bool {
        let raw = (tool.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.isEmpty || raw == "none" || raw == "{}"
    }

    private func runToolDirectly(_ tool: ToolDefinition) {
        guard let url = URL(string: sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tool/run") else {
            showBaseURLToast("Invalid station URL")
            return
        }
        showBaseURLToast("Running \(tool.name)…")
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["name": tool.name, "input": [:]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    await MainActor.run {
                        showBaseURLToast("Tool failed (\(http.statusCode)): \(tool.name)")
                    }
                    return
                }
                var openedViewer = false
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let urls = obj["urls"] as? [String], let first = urls.first, let viewer = URL(string: first) {
                        await MainActor.run {
                            modalCoordinator.present(.viewer(url: viewer))
                        }
                        openedViewer = true
                    } else if let result = obj["result_json"] as? [String: Any],
                              let urlString = result["url"] as? String,
                              let viewer = URL(string: urlString) {
                        await MainActor.run {
                            modalCoordinator.present(.viewer(url: viewer))
                        }
                        openedViewer = true
                    }
                }
                await MainActor.run {
                    showBaseURLToast(openedViewer ? "Ran \(tool.name) (viewer opened)" : "Ran \(tool.name)")
                }
            } catch {
                await MainActor.run {
                    showBaseURLToast("Tool error: \(tool.name)")
                }
            }
        }
    }

    private func runPresetDirectly(_ preset: PresetDefinition) {
        guard let url = URL(string: sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/preset/run") else {
            showBaseURLToast("Invalid station URL")
            return
        }
        let title = preset.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (title?.isEmpty == false) ? title! : preset.id
        showBaseURLToast("Running \(label)…")
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["id": preset.id]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    await MainActor.run {
                        showBaseURLToast("Preset failed (\(http.statusCode)): \(label)")
                    }
                    return
                }
                var openedViewer = false
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let urls = obj["urls"] as? [String], let first = urls.first, let viewer = URL(string: first) {
                        await MainActor.run { modalCoordinator.present(.viewer(url: viewer)) }
                        openedViewer = true
                    } else if let result = obj["result_json"] as? [String: Any],
                              let urlString = result["url"] as? String,
                              let viewer = URL(string: urlString) {
                        await MainActor.run { modalCoordinator.present(.viewer(url: viewer)) }
                        openedViewer = true
                    }
                }
                await MainActor.run {
                    showBaseURLToast(openedViewer ? "Ran \(label) (viewer opened)" : "Ran \(label)")
                }
            } catch {
                await MainActor.run {
                    showBaseURLToast("Preset error: \(label)")
                }
            }
        }
    }

    private func openFlashPath(_ path: String, showFinder: Bool = false) {
        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = flashTarget(from: path)
        markFlashStarted(target: target)
        stationProcessManager.ensureRunning(baseURL: base)
        Task {
            if await waitForStation(baseURL: base, timeout: 6.0) {
                if let url = URL(string: base + path) {
                    NSWorkspace.shared.open(url)
                }
            } else if let url = URL(string: base + path) {
                NSWorkspace.shared.open(url)
            }
            if showFinder {
                await MainActor.run {
                    markFlashAwaitingHello()
                    openFindDevice()
                }
            }
        }
    }

    private func startFlash(target: FlashTarget, autoOpenFlasher: Bool, autoOpenFindDevice: Bool) {
        markFlashStarted(target: target)
        flashManager.selectedTarget = target
        if autoOpenFlasher {
            flashManager.startSelectedTarget()
        }
        markFlashAwaitingHello()
        if autoOpenFindDevice {
            openFindDevice()
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
        guard let url = StationEndpointResolver.endpointURL(baseURL: baseURL, path: "/api/status") else { return false }
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

    private func startStationFromDashboard() {
        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        stationProcessManager.ensureRunning(baseURL: base)
        Task {
            let ready = await waitForStation(baseURL: base, timeout: 10.0)
            await MainActor.run {
                sodsStore.refreshStatus()
                sodsStore.connect()
                if ready {
                    showBaseURLToast("Station started.")
                    logStore.log(.info, "Dashboard start station succeeded at \(base)")
                } else {
                    showBaseURLToast("Station start attempted. Verify SODS root and port 9123.")
                    logStore.log(.warn, "Dashboard start station timed out at \(base)")
                }
            }
        }
    }

    private func bootstrapStackOnLaunchIfNeeded() {
        guard !didBootstrapStack else { return }
        didBootstrapStack = true

        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        stationProcessManager.ensureRunning(baseURL: base)
        if !piAuxStore.isRunning {
            piAuxStore.start()
        }
        piAuxStore.refreshLocalNodeHeartbeat()
        controlPlaneStore.refresh()
        refreshFleetStatusFromDisk()

        Task {
            let ready = await waitForStation(baseURL: base, timeout: 8.0)
            await MainActor.run {
                if ready {
                    sodsStore.connect()
                    sodsStore.refreshStatus()
                }
                controlPlaneStore.refresh()
                refreshFleetStatusFromDisk()
            }
        }
    }

    private func reconnectStationFromDashboard() {
        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        stationProcessManager.reconnect(baseURL: base)
        Task {
            let ready = await waitForStation(baseURL: base, timeout: 10.0)
            await MainActor.run {
                sodsStore.connect()
                sodsStore.refreshStatus()
                if ready {
                    showBaseURLToast("Station reconnected.")
                    logStore.log(.info, "Dashboard reconnect station succeeded at \(base)")
                } else {
                    showBaseURLToast("Station reconnect timed out.")
                    logStore.log(.warn, "Dashboard reconnect station timed out at \(base)")
                }
            }
        }
    }

    private func reconnectControlPlaneFromDashboard() {
        controlPlaneStore.refresh()
        controlPlaneStore.probeTokenOnce()
        controlPlaneStore.probeGatewayOnce()
        showBaseURLToast("Control plane checks refreshed.")
        logStore.log(.info, "Dashboard requested control-plane reconnect probes")
    }

    private func restartPiAuxRelayFromDashboard() {
        piAuxStore.start()
        piAuxStore.refreshLocalNodeHeartbeat()
        showBaseURLToast("Pi-Aux relay restarted.")
        logStore.log(.info, "Dashboard restarted Pi-Aux relay")
    }

    private func reconnectEntireStackFromDashboard() {
        guard !stackReconnectInFlight else { return }
        stackReconnectInFlight = true
        showBaseURLToast("Reconnecting stack...")

        let base = sodsStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        stationProcessManager.reconnect(baseURL: base)
        piAuxStore.start()
        piAuxStore.refreshLocalNodeHeartbeat()
        controlPlaneStore.refresh()
        controlPlaneStore.probeTokenOnce()
        controlPlaneStore.probeGatewayOnce()

        Task {
            let stationReady = await waitForStation(baseURL: base, timeout: 12.0)
            await MainActor.run {
                sodsStore.connect()
                sodsStore.refreshStatus()
                controlPlaneStore.refresh()
                stackReconnectInFlight = false
                refreshFleetStatusFromDisk()
                if stationReady {
                    showBaseURLToast("Stack reconnected.")
                    logStore.log(.info, "Dashboard full stack reconnect succeeded at \(base)")
                } else {
                    showBaseURLToast("Stack reconnect finished with station still offline.")
                    logStore.log(.warn, "Dashboard full stack reconnect timed out at \(base)")
                }
            }
        }
    }

    private func fleetStatusFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SODS/control-plane-status.json")
    }

    private func rehydrateCoreNodes() {
        _ = nodeRegistry.ensureCoreNodes(
            presence: sodsStore.nodePresence,
            fleetStatusFileURL: fleetStatusFileURL()
        )
    }

    private func restoreCoreNodesFromNodesView() {
        let changed = nodeRegistry.ensureCoreNodes(
            presence: sodsStore.nodePresence,
            fleetStatusFileURL: fleetStatusFileURL()
        )
        entityStore.ingestNodes(nodeRegistry.nodes)
        refreshConnectSelection()
        if changed {
            showBaseURLToast("Core nodes restored.")
            logStore.log(.info, "Core nodes restored from Nodes tab")
        } else {
            showBaseURLToast("Core nodes already up to date.")
        }
    }

    private func refreshFleetStatusFromDashboard() {
        refreshFleetStatusFromDisk()
        let summary = "Fleet status: \(fleetStatusOverall)"
        showBaseURLToast(summary)
        logStore.log(.info, summary)
    }

    private func openSystemManagerFromDashboard(optimize: Bool) {
        viewMode = .systemManager
        systemManagerStore.startPolling()
        if optimize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                systemManagerStore.optimizeCleanRAMGuided()
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let action = DevStationDeepLinkResolver.resolve(url) else {
            logStore.log(.warn, "Ignored unsupported deep link: \(url.absoluteString)")
            return
        }
        switch action {
        case .openSystemManager(let optimize):
            openSystemManagerFromDashboard(optimize: optimize)
        }
    }

    private func refreshFleetStatusFromDisk() {
        let url = fleetStatusFileURL()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fleetStatusOverall = "offline"
            fleetStatusUpdatedAt = nil
            fleetStatusDetail = "No fleet status file. Run full fleet reconnect."
            fleetTargetRows = []
            rehydrateCoreNodes()
            return
        }

        let overall = (obj["overall"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "offline"
        fleetStatusOverall = overall.isEmpty ? "offline" : overall

        if let ts = obj["ts"] as? String, !ts.isEmpty {
            fleetStatusUpdatedAt = ISO8601DateFormatter().date(from: ts)
        } else {
            fleetStatusUpdatedAt = nil
        }

        let targets = (obj["targets"] as? [[String: Any]]) ?? []
        var rows: [FleetTargetStatusRow] = []
        rows.reserveCapacity(targets.count)
        var failedTargets = 0
        for item in targets {
            let name = (item["name"] as? String) ?? "unknown"
            let reachable = (item["reachable"] as? Bool) ?? false
            let ok = (item["ok"] as? Bool) ?? false
            let services = (item["services"] as? [[String: Any]]) ?? []
            let failedChecks = services.filter { (($0["ok"] as? Bool) ?? false) == false }.count
            let actions = (item["actions"] as? [String]) ?? []
            let lastAction = actions.last ?? ""
            var detail = reachable ? "reachable" : "unreachable"
            if failedChecks > 0 {
                detail = "\(failedChecks) failed checks"
            } else if ok {
                detail = "all checks passed"
            }
            if !lastAction.isEmpty {
                detail += " • \(lastAction)"
            }
            rows.append(FleetTargetStatusRow(name: name, reachable: reachable, ok: ok, detail: detail))
            if !ok {
                failedTargets += 1
            }
        }

        fleetTargetRows = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if rows.isEmpty {
            fleetStatusDetail = "No target entries in fleet status."
        } else if failedTargets == 0 {
            fleetStatusDetail = "All fleet targets healthy."
        } else {
            fleetStatusDetail = "\(failedTargets) fleet targets degraded."
        }
        rehydrateCoreNodes()
    }

    private func reconnectFullFleetFromDashboard() {
        guard !fullFleetReconnectInFlight else { return }
        fullFleetReconnectInFlight = true
        showBaseURLToast("Running full fleet reconnect...")
        refreshFleetStatusFromDisk()

        let root = StoragePaths.sodsRootPath()
        let scriptPath = "\(root)/tools/control-plane-up.sh"
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            fullFleetReconnectInFlight = false
            showBaseURLToast("Missing script: tools/control-plane-up.sh")
            logStore.log(.error, "Full fleet reconnect script missing at \(scriptPath)")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [scriptPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "\"\(scriptPath)\""]

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.fullFleetReconnectInFlight = false
                    self.showBaseURLToast("Fleet reconnect failed to start.")
                    self.logStore.log(.error, "Fleet reconnect start failed: \(error.localizedDescription)")
                }
                return
            }

            while process.isRunning {
                Thread.sleep(forTimeInterval: 1.0)
                DispatchQueue.main.async {
                    self.refreshFleetStatusFromDisk()
                }
            }
            process.waitUntilExit()

            DispatchQueue.main.async {
                self.fullFleetReconnectInFlight = false
                self.refreshFleetStatusFromDisk()
                if process.terminationStatus == 0 && self.fleetStatusOverall == "ok" {
                    self.showBaseURLToast("Full fleet reconnect complete.")
                    self.logStore.log(.info, "Full fleet reconnect succeeded.")
                } else {
                    self.showBaseURLToast("Full fleet reconnect completed with degraded status.")
                    self.logStore.log(.warn, "Full fleet reconnect finished with status=\(self.fleetStatusOverall), exit=\(process.terminationStatus)")
                }
            }
        }
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
            logStore.log(.info, "RTSP path try finished for \(ip): \(successes.count) ok")
            scanner.applyManualRTSPProbeResults(forIP: ip, results: results)
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

enum DevStationViewModeResolver {
    static func resolveStartView(_ rawValue: String) -> ContentView.ViewMode? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let normalized = normalizedToken(cleaned)
        switch normalized {
        case "scan", "scanning", "scanners":
            return .scanning
        case "system", "taskmanager", "systemmanager", "ram":
            return .systemManager
        case "analyzer", "spectrum", "spectral":
            return .spectral
        default:
            break
        }

        if let exact = ContentView.ViewMode.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(cleaned) == .orderedSame
        }) {
            return exact
        }

        return ContentView.ViewMode.allCases.first(where: {
            normalizedToken($0.rawValue) == normalized
        })
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

enum DevStationDeepLinkAction: Equatable {
    case openSystemManager(optimize: Bool)
}

enum DevStationDeepLinkResolver {
    static func resolve(_ url: URL) -> DevStationDeepLinkAction? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "devstation" else { return nil }

        let host = (url.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target: String
        if !host.isEmpty {
            target = host
        } else {
            target = path.replacingOccurrences(of: "/", with: "")
        }
        guard target == "system-manager" || target == "systemmanager" else { return nil }

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.lowercased() == "action" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let optimize = query == "optimize"
            || query == "clean"
            || query == "clean-ram"
            || query == "cleanram"

        return .openSystemManager(optimize: optimize)
    }
}

private extension ContentView {
    func applyBaseURLInput(_ rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard !baseURLApplyInFlight else { return }
        baseURLApplyInFlight = true
        Task { @MainActor in
            let applied = await sodsStore.updateBaseURL(candidate)
            baseURLApplyInFlight = false
            if applied {
                baseURLValidationMessage = nil
                sodsURLText = sodsStore.baseURL
            } else {
                let message = sodsStore.baseURLError ?? "Base URL must start with http:// or https://"
                baseURLValidationMessage = message
                sodsURLText = sodsStore.baseURL
                showBaseURLToast(message)
            }
        }
    }

    func applyLaunchOverrides() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--station") {
            let next = (idx + 1 < args.count) ? args[idx + 1] : ""
            let cleaned = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                applyBaseURLInput(cleaned)
            }
        }

        if let idx = args.firstIndex(of: "--start-view") {
            let next = (idx + 1 < args.count) ? args[idx + 1] : ""
            let cleaned = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            if let match = DevStationViewModeResolver.resolveStartView(cleaned) {
                viewMode = match
            }
        }
    }

    func kickoffRoundupIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--roundup") else {
            roundUpClaimedNodesConnectIdentify()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                roundUpClaimedNodesConnectIdentify()
            }
            return
        }
        let next = (idx + 1 < args.count) ? args[idx + 1] : ""
        let mode = next.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode == "connect-identify" || mode == "connect+identify" || mode == "connectidentify" || mode.isEmpty {
            roundUpClaimedNodesConnectIdentify()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                roundUpClaimedNodesConnectIdentify()
            }
            return
        }
        if mode == "status" || mode == "refresh" {
            sodsStore.refreshStatus()
            return
        }
        roundUpClaimedNodesConnectIdentify()
    }

    func roundUpClaimedNodesConnectIdentify() {
        let claimed = nodeRegistry.nodes
        guard !claimed.isEmpty else { return }
        let presence = sodsStore.nodePresence
        for node in claimed {
            if node.connectionState == .offline || node.connectionState == .error || presence[node.id] == nil {
                NodeRegistry.shared.setConnecting(nodeID: node.id, connecting: true)
                sodsStore.connectNode(node.id)
                sodsStore.identifyNode(node.id)
            }
        }
        sodsStore.refreshStatus()
    }
}
