import SwiftUI
import AppKit
import ScannerSpectrumCore

extension Notification.Name {
    static let sodsReplaySeek = Notification.Name("sods.replay.seek")
}

struct VisualizerView: View {
    @ObservedObject var store: SODSStore
    @ObservedObject var entityStore: EntityStore
    let onOpenTools: () -> Void
    @State private var baseURLText: String = ""
    @State private var baseURLValidationMessage: String?
    @State private var baseURLApplyInFlight = false
    @State private var showBaseURLToast = false
    @State private var baseURLToastMessage = ""
    @State private var paused: Bool = false
    @State private var decayRate: Double = 1.0
    // Default to a calmer (less CPU-intensive) baseline; user can turn it up.
    @State private var timeScale: Double = 0.85
    @State private var maxParticles: Double = 900
    // Default to Calm for performance; Storm can be enabled when you want density.
    @State private var intensityMode: SignalIntensity = .calm
    @State private var replayEnabled: Bool = false
    @State private var replayOffset: Double = 0
    @State private var replayAutoPlay: Bool = false
    @State private var replaySpeed: Double = 1.0
    @State private var ghostTrails: Bool = false
    @State private var topologyClarity: Bool = true
    @State private var protocolLanes: Bool = true
    @State private var recentOnlyLinks: Bool = true
    @State private var targetSpotlight: Bool = true
    @State private var selectedNodeIDs: Set<String> = []
    @State private var selectedKinds: Set<String> = []
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var activityTick: Date = Date()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sidebar
                    .frame(minWidth: 320, maxWidth: 360)
                SharedSpectrumRendererView(
                    events: filteredEvents,
                    frames: displayFrames,
                    paused: paused,
                    maxParticles: Int(maxParticles)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 12) {
                sidebar
                SharedSpectrumRendererView(
                    events: filteredEvents,
                    frames: displayFrames,
                    paused: paused,
                    maxParticles: Int(maxParticles)
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .padding(12)
        .background(Theme.background)
        .overlay(alignment: .top) {
            if showBaseURLToast {
                baseURLToastView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            baseURLText = store.baseURL
            if let error = store.baseURLError, !error.isEmpty {
                baseURLValidationMessage = error
                showBaseURLToast(error)
            } else {
                baseURLValidationMessage = nil
            }
        }
        .onChange(of: store.baseURL) { newValue in
            baseURLText = newValue
            baseURLValidationMessage = nil
        }
        .onReceive(store.$baseURLNotice) { notice in
            guard let notice, !notice.isEmpty else { return }
            baseURLText = store.baseURL
            baseURLValidationMessage = nil
            showBaseURLToast(notice)
            store.clearBaseURLNotice()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard replayEnabled, replayAutoPlay else { return }
            replayOffset += replaySpeed
            if replayOffset > 60 { replayOffset = 0 }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            activityTick = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sodsReplaySeek)) { notification in
            if let value = notification.object as? Double {
                replayOffset = max(0, min(60, value))
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            sidebarContent
        }
        .modifier(Theme.cardStyle())
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            legendSection
            nodesSection
            kindsSection
            devicesSection
            Spacer()
        }
    }

    private var header: some View {
        let dataSource = dataSourceStatus
        return VStack(alignment: .leading, spacing: 6) {
            Text("SODS Analyzer")
                .font(.system(size: 16, weight: .semibold))
            Text("Strange Ops Dev Station • inferred signal field")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(store.health.color))
                    .frame(width: 8, height: 8)
                Text(store.health.label)
                    .font(.system(size: 11))
                Spacer()
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(dataSource.color)
                    .frame(width: 8, height: 8)
                Text("Frames: \(dataSource.label)")
                    .font(.system(size: 11))
                Spacer()
            }
            if store.realFramesActive, let last = store.lastFramesAt {
                Text("Last frames: \(last.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if framesAreDerived, let last = latestFallbackFrameTime {
                Text("Last activity: \(last.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if framesAreDerived {
                Text("Source: events")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if let source = store.frames.first?.source {
                Text("Source: \(source)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var dataSourceStatus: (label: String, color: Color) {
        if replayEnabled {
            return ("Playback", Color.orange)
        }
        if store.realFramesActive || hasRecentLiveEvents {
            return ("Live", Color.green)
        }
        return ("Idle", Color.gray)
    }

    private var controls: some View {
        GroupBox("Controls") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("SODS URL")
                        .font(.system(size: 11))
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(baseURLApplyInFlight)
                    Button {
                        let candidate = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !candidate.isEmpty else { return }
                        guard !baseURLApplyInFlight else { return }
                        baseURLApplyInFlight = true
                        Task { @MainActor in
                            let applied = await store.updateBaseURL(candidate)
                            baseURLApplyInFlight = false
                            if applied {
                                baseURLValidationMessage = nil
                                baseURLText = store.baseURL
                            } else {
                                let message = store.baseURLError ?? "Base URL must start with http:// or https://"
                                baseURLValidationMessage = message
                                baseURLText = store.baseURL
                                showBaseURLToast(message)
                            }
                        }
                    } label: {
                        Image(systemName: baseURLApplyInFlight ? "hourglass.circle" : "checkmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help(baseURLApplyInFlight ? "Validating Base URL" : "Apply")
                    .accessibilityLabel(Text(baseURLApplyInFlight ? "Validating Base URL" : "Apply"))
                    .disabled(baseURLApplyInFlight)

                    Button {
                        store.resetBaseURL()
                        baseURLText = store.baseURL
                        baseURLValidationMessage = nil
                        showBaseURLToast("Base URL reset to \(store.baseURL)")
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Reset")
                    .accessibilityLabel(Text("Reset"))
                    .disabled(baseURLApplyInFlight)
                }
                if let message = baseURLValidationMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                HStack(spacing: 8) {
                    Button { paused.toggle() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help(paused ? "Play" : "Pause")
                    .accessibilityLabel(Text(paused ? "Play" : "Pause"))
                    Picker("Intensity", selection: $intensityMode) {
                        ForEach(SignalIntensity.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow(title: "Decay", value: $decayRate, range: 0.6...2.0, format: "%.2f")
                    sliderRow(title: "Time", value: $timeScale, range: 0.5...2.0, format: "%.2f")
                    sliderRow(title: "Particles", value: $maxParticles, range: 600...2400, format: "%.0f")
                }
                HStack(spacing: 8) {
                    Button {
                        if store.isRecording {
                            store.stopRecording()
                        } else {
                            store.startRecording()
                        }
                    } label: {
                        Image(systemName: store.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help(store.isRecording ? "Stop Recording" : "Start Recording")
                    .accessibilityLabel(Text(store.isRecording ? "Stop Recording" : "Start Recording"))

                    Button {
                        store.clearRecording()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Clear Recording")
                    .accessibilityLabel(Text("Clear Recording"))

                    Button {
                        saveRecording()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Save Recording")
                    .accessibilityLabel(Text("Save Recording"))

                    Button {
                        loadRecording()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Load Recording")
                    .accessibilityLabel(Text("Load Recording"))
                    Text("\(store.recordedEvents.count) events")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Toggle("Playback", isOn: $replayEnabled)
                    .font(.system(size: 11))
                if replayEnabled {
                    Toggle("Auto Play", isOn: $replayAutoPlay)
                        .font(.system(size: 11))
                    sliderRow(title: "Offset", value: $replayOffset, range: 0...60, format: "%.0fs")
                    sliderRow(title: "Speed", value: $replaySpeed, range: 0.25...4.0, format: "%.2fx")
                }
                Toggle("Ghost trails", isOn: $ghostTrails)
                    .font(.system(size: 11))
                Toggle("Topology clarity", isOn: $topologyClarity)
                    .font(.system(size: 11))
                Toggle("Protocol lanes", isOn: $protocolLanes)
                    .font(.system(size: 11))
                Toggle("Recent-only links", isOn: $recentOnlyLinks)
                    .font(.system(size: 11))
                Toggle("Target spotlight", isOn: $targetSpotlight)
                    .font(.system(size: 11))
            }
            .padding(6)
        }
    }

    private var legendSection: some View {
        GroupBox("What you're seeing") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    legendRow(color: SignalColor.kindAccent(kind: "ble.seen"), label: "BLE • dot + tight ring")
                    legendRow(color: SignalColor.kindAccent(kind: "wifi.status", channel: "6"), label: "Wi‑Fi 2.4G • wave ring")
                    legendRow(color: SignalColor.kindAccent(kind: "wifi.status", channel: "36"), label: "Wi‑Fi 5G • wave ring")
                    legendRow(color: SignalColor.kindAccent(kind: "rf"), label: "RF • wave burst")
                    legendRow(color: SignalColor.kindAccent(kind: "node.heartbeat"), label: "Node • diamond halo")
                    legendRow(color: SignalColor.kindAccent(kind: "tool"), label: "Action • pulse burst")
                    legendRow(color: SignalColor.kindAccent(kind: "error"), label: "Error • starburst")
                    Text("Type-first color coding: hue = signal class, tint = device identity.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Brightness = recency + strength. Trails fade with time.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Depth = size/blur/alpha/parallax cues.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("Legend + interpretation")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(6)
        }
    }

    private func legendRow(color: NSColor, label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(color))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10))
        }
    }

    private func saveRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "sods-recording-\(DateFormatter.recordingStamp.string(from: Date())).ndjson"
        panel.directoryURL = StoragePaths.recordingsBase()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = store.saveRecording(to: url)
        }
    }

    private func loadRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = StoragePaths.recordingsBase()
        if panel.runModal() == .OK, let url = panel.url {
            if store.loadRecording(from: url) {
                replayEnabled = true
                replayOffset = 0
            }
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
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

    private var nodesSection: some View {
        GroupBox("Nodes") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.nodes) { node in
                    let activity = activityScore(for: node.id)
                    let presentation = NodePresentation.forSignalNode(node, presence: store.nodePresence[node.id], activityScore: activity)
                    NodeRow(
                        node: node,
                        alias: nodeAliases[node.id] ?? nodeAliases["node:\(node.id)"],
                        presence: store.nodePresence[node.id],
                        presentation: presentation,
                        selected: selectedNodeIDs.contains(node.id),
                        onToggle: {
                            toggleFilter(id: node.id, in: &selectedNodeIDs)
                        },
                        onOpenWhoami: {
                            store.openEndpoint(for: node, path: "/whoami")
                        },
                        onOpenHealth: {
                            store.openEndpoint(for: node, path: "/health")
                        },
                        onOpenMetrics: {
                            store.openEndpoint(for: node, path: "/metrics")
                        },
                        onOpenTools: { onOpenTools() }
                    )
                }
            }
            .padding(6)
        }
    }

    private var kindsSection: some View {
        GroupBox("Kinds") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(availableKinds, id: \.self) { kind in
                    FilterRow(
                        label: kind,
                        color: SignalColor.kindAccent(kind: kind),
                        selected: selectedKinds.contains(kind),
                        onToggle: {
                            toggleFilter(id: kind, in: &selectedKinds)
                        }
                    )
                }
            }
            .padding(6)
        }
    }

    private var devicesSection: some View {
        GroupBox("Devices") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(availableDevices, id: \.self) { deviceID in
                    let label = deviceLabel(for: deviceID)
                    FilterRow(
                        label: label,
                        color: SignalColor.deviceColor(id: deviceID),
                        selected: selectedDeviceIDs.contains(deviceID),
                        onToggle: {
                            toggleFilter(id: deviceID, in: &selectedDeviceIDs)
                        }
                    )
                }
            }
            .padding(6)
        }
    }

    private var availableKinds: [String] {
        let kinds = Set(liveEvents.map { $0.kind })
        return kinds.sorted()
    }

    private var availableDevices: [String] {
        let devices = liveEvents.compactMap { $0.deviceID }
        return Array(Set(devices)).sorted()
    }

    private func deviceLabel(for deviceID: String) -> String {
        if let alias = nodeAliases[deviceID], !alias.isEmpty, alias != deviceID {
            return "\(alias) (\(deviceID))"
        }
        return deviceID
    }

    private var liveEvents: [NormalizedEvent] {
        let combined = store.events + localEvents
        if combined.count > 1400 {
            return Array(combined.suffix(1400))
        }
        return combined
    }

    private var hasRecentLiveEvents: Bool {
        !fallbackFrames.isEmpty
    }

    private var filteredEvents: [NormalizedEvent] {
        let sourceEvents = replayEnabled ? store.recordedEvents : liveEvents
        let base = sourceEvents.filter { event in
            if !selectedNodeIDs.isEmpty && !selectedNodeIDs.contains(event.nodeID) { return false }
            if !selectedKinds.isEmpty && !selectedKinds.contains(event.kind) { return false }
            if !selectedDeviceIDs.isEmpty {
                guard let deviceID = event.deviceID else { return false }
                if !selectedDeviceIDs.contains(deviceID) { return false }
            }
            return true
        }
        guard replayEnabled else { return base }
        let now = Date()
        let cursor = now.addingTimeInterval(-replayOffset)
        let window: TimeInterval = 3.0
        return base.filter { event in
            let ts = event.eventTs ?? event.recvTs ?? now
            return abs(ts.timeIntervalSince(cursor)) <= window
        }
    }

    private var fallbackFrames: [SignalFrame] {
        let now = Date()
        let window: TimeInterval = 4.0
        let cutoff = now.addingTimeInterval(-window)
        let recent = filteredEvents.filter { event in
            let ts = event.eventTs ?? event.recvTs ?? now
            return ts >= cutoff
        }
        guard !recent.isEmpty else { return [] }
        return recent.suffix(140).compactMap { event in
            let ts = event.eventTs ?? event.recvTs ?? now
            let kind = event.kind.lowercased()

            // Honesty rule: only derive fallback frames from actual signal events with real signal fields.
            // No default RSSI/channel/device fallbacks.
            let source: String
            if kind.contains("ble") {
                source = "ble"
            } else if kind.contains("wifi") {
                source = "wifi"
            } else {
                return nil
            }

            guard let deviceID = event.deviceID, !deviceID.isEmpty else { return nil }
            guard let strength = event.signal.strength else { return nil }
            guard let channelRaw = event.signal.channel, let channel = Int(channelRaw), channel > 0 else { return nil }

            let frequency: Int = {
                if source == "ble" {
                    if channel == 37 { return 2402 }
                    if channel == 38 { return 2426 }
                    if channel == 39 { return 2480 }
                    return 0
                }
                // Wi-Fi: support common 2.4GHz + 5GHz channels only.
                if channel >= 1 && channel <= 13 { return 2412 + (channel - 1) * 5 }
                if channel == 14 { return 2484 }
                if channel >= 36 && channel <= 165 { return 5000 + channel * 5 }
                return 0
            }()
            guard frequency > 0 else { return nil }

            let style = SignalVisualStyle.from(event: event, now: now)
            let (nx, ny, nz) = normalizedFramePosition(for: event)
            return SignalFrame(
                t: Int(ts.timeIntervalSince1970 * 1000),
                source: source,
                nodeID: event.nodeID,
                deviceID: deviceID,
                channel: channel,
                frequency: frequency,
                rssi: strength,
                x: nx,
                y: ny,
                z: nz,
                color: FrameColor(h: style.hue * 360.0, s: style.saturation, l: style.brightness),
                glow: style.glow,
                persistence: 0.45,
                velocity: nil,
                confidence: style.confidence
            )
        }
    }

    private var framesAreDerived: Bool {
        !store.realFramesActive && !fallbackFrames.isEmpty
    }

    private var displayFrames: [SignalFrame] {
        store.realFramesActive ? store.frames : fallbackFrames
    }

    private var latestFallbackFrameTime: Date? {
        guard !fallbackFrames.isEmpty else { return nil }
        let latest = fallbackFrames.max(by: { $0.t < $1.t })?.t ?? 0
        guard latest > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(latest) / 1000)
    }

    private var nodeAliases: [String: String] {
        IdentityResolver.shared.updateFromSignals(store.nodes)
        for event in liveEvents {
            let data = event.data
            let ssid = data["ssid"]?.stringValue ?? ""
            let hostname = data["hostname"]?.stringValue ?? ""
            let ip = data["ip"]?.stringValue ?? data["ip_addr"]?.stringValue ?? ""
            let bssid = data["bssid"]?.stringValue ?? data["mac"]?.stringValue ?? ""
            let alias = hostname.isEmpty ? (ssid.isEmpty ? (ip.isEmpty ? "" : ip) : ssid) : hostname
            if let deviceID = event.deviceID, !alias.isEmpty {
                IdentityResolver.shared.record(keys: [deviceID], label: alias)
            } else if !bssid.isEmpty, !alias.isEmpty {
                IdentityResolver.shared.record(keys: [bssid], label: alias)
            }
        }
        return IdentityResolver.shared.aliasMap()
    }

    private var localEvents: [NormalizedEvent] {
        let obsByID = latestObservationByID
        let now = Date()
        let recencyWindow: TimeInterval = 8.0
        let sourceNodeID = resolvedDerivedNodeID
        var output: [NormalizedEvent] = []

        for peripheral in entityStore.blePeripherals.prefix(120) {
            let timestamp = obsByID[peripheral.fingerprintID]?.timestamp ?? peripheral.lastSeen
            guard now.timeIntervalSince(timestamp) <= recencyWindow else { continue }
            let label = IdentityResolver.shared.resolveLabel(keys: [peripheral.fingerprintID, peripheral.id.uuidString]) ?? peripheral.name ?? peripheral.fingerprintID
            var data: [String: JSONValue] = [
                "rssi": .number(Double(peripheral.smoothedRSSI)),
                "fingerprint": .string(peripheral.fingerprintID),
                "name": .string(peripheral.name ?? "")
            ]
            if !peripheral.serviceUUIDs.isEmpty {
                data["services"] = .string(peripheral.serviceUUIDs.joined(separator: ","))
            }
            if let vendor = peripheral.fingerprint.manufacturerCompanyName, !vendor.isEmpty {
                data["vendor"] = .string(vendor)
            }
            output.append(
                NormalizedEvent(
                    localNodeID: sourceNodeID,
                    kind: "ble.seen",
                    summary: "BLE \(label)",
                    data: data,
                    deviceID: "ble:\(peripheral.fingerprintID)",
                    eventTs: timestamp
                )
            )
        }

        for device in entityStore.devices.prefix(120) {
            guard let timestamp = obsByID[device.ip]?.timestamp,
                  now.timeIntervalSince(timestamp) <= recencyWindow else { continue }
            var data: [String: JSONValue] = [
                "ip": .string(device.ip),
                "mac": .string(device.macAddress ?? "")
            ]
            if let vendor = device.vendor, !vendor.isEmpty { data["vendor"] = .string(vendor) }
            if let title = device.httpTitle, !title.isEmpty { data["http_title"] = .string(title) }
            output.append(
                NormalizedEvent(
                    localNodeID: sourceNodeID,
                    kind: "net.device",
                    summary: "Device \(device.ip)",
                    data: data,
                    deviceID: device.ip,
                    eventTs: timestamp
                )
            )
        }

        for host in entityStore.hosts.prefix(120) where host.isAlive {
            guard let timestamp = obsByID[host.ip]?.timestamp,
                  now.timeIntervalSince(timestamp) <= recencyWindow else { continue }
            var data: [String: JSONValue] = [
                "ip": .string(host.ip),
                "mac": .string(host.macAddress ?? "")
            ]
            if let vendor = host.vendor, !vendor.isEmpty { data["vendor"] = .string(vendor) }
            if let hostname = host.hostname, !hostname.isEmpty { data["hostname"] = .string(hostname) }
            output.append(
                NormalizedEvent(
                    localNodeID: sourceNodeID,
                    kind: "net.host",
                    summary: "Host \(host.ip)",
                    data: data,
                    deviceID: host.ip,
                    eventTs: timestamp
                )
            )
        }

        return output
    }

    private var resolvedDerivedNodeID: String {
        if selectedNodeIDs.count == 1, let selected = selectedNodeIDs.first {
            return selected
        }
        let scanningPresence = store.nodePresence.values
            .filter { $0.state.lowercased() == "scanning" }
            .sorted { $0.lastSeen > $1.lastSeen }
            .first
        if let scanningID = scanningPresence?.nodeID.trimmingCharacters(in: .whitespacesAndNewlines),
           !scanningID.isEmpty {
            return scanningID
        }
        if let recentNode = store.nodes.sorted(by: { $0.lastSeen > $1.lastSeen }).first {
            return recentNode.id
        }
        if let lastEventNode = store.events.last?.nodeID.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastEventNode.isEmpty {
            return lastEventNode
        }
        return NodeType.unknown.rawValue
    }

    private var latestObservationByID: [String: Observation] {
        var map: [String: Observation] = [:]
        for obs in entityStore.observations {
            map[obs.entityID] = obs
        }
        return map
    }

    private func normalizedFramePosition(for event: NormalizedEvent) -> (Double?, Double?, Double?) {
        let kind = event.kind.lowercased()
        let kindOffset = kind.contains("wifi") ? 0.08 : kind.contains("ble") ? -0.06 : 0.0
        let baseHue = Double(SignalColor.stableHue(for: event.deviceID ?? event.nodeID))
        let channelValue = Double(event.signal.channel ?? "") ?? baseHue * 180
        let angle = (channelValue.truncatingRemainder(dividingBy: 180) / 180.0) * Double.pi * 2 + kindOffset
        let radius = kind.contains("ble") ? 0.32 : kind.contains("wifi") ? 0.52 : 0.7
        let x = cos(angle) * radius
        let y = sin(angle) * radius
        let strength = event.signal.strength ?? -60
        let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
        let idOffset = stableDepthOffset(for: event.deviceID ?? event.nodeID)
        let z = clamp(0.25 + strengthNorm * 0.55 + idOffset, min: 0.1, max: 1.0)
        let nx = clamp(0.5 + (x / 1.2))
        let ny = clamp(0.5 + (y / 1.2))
        return (nx, ny, z)
    }

    private func clamp(_ value: Double, min: Double = 0.0, max: Double = 1.0) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private var nodePresentationByID: [String: NodePresentation] {
        var map: [String: NodePresentation] = [:]
        for node in store.nodes {
            let presentation = NodePresentation.forSignalNode(node, presence: store.nodePresence[node.id], activityScore: activityScore(for: node.id))
            map[node.id] = presentation
            map["node:\(node.id)"] = presentation
        }
        return map
    }

    private func activityScore(for nodeID: String) -> Double {
        let now = activityTick
        let window: TimeInterval = 20
        let recent = liveEvents.suffix(240).filter { event in
            guard event.nodeID == nodeID else { return false }
            let ts = event.eventTs ?? event.recvTs ?? now
            return now.timeIntervalSince(ts) <= window
        }
        guard !recent.isEmpty else { return 0.0 }
        let weighted = recent.reduce(0.0) { partial, event in
            let strength = event.signal.strength ?? -65
            let norm = max(0.0, min(1.0, ((-strength) - 30.0) / 70.0))
            return partial + norm
        }
        let base = min(1.0, weighted / Double(max(1, recent.count)))
        return max(0.2, min(1.0, base))
    }

    // persistence handled inside SignalFieldView

    private func toggleFilter(id: String, in set: inout Set<String>) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }
}

private struct SharedSpectrumRendererView: View {
    let events: [NormalizedEvent]
    let frames: [SignalFrame]
    let paused: Bool
    let maxParticles: Int

    @State private var frozenEvents: [NormalizedEvent] = []
    @State private var frozenFrames: [SignalFrame] = []

    private var effectiveEvents: [NormalizedEvent] {
        let source = paused ? frozenEvents : events
        return Array(source.suffix(max(200, maxParticles * 2)))
    }

    private var effectiveFrames: [SignalFrame] {
        let source = paused ? frozenFrames : frames
        return Array(source.suffix(max(100, maxParticles)))
    }

    private var coreEvents: [ScannerSpectrumCore.NormalizedEvent] {
        effectiveEvents.map { $0.toCoreEvent() }
    }

    private var coreFrames: [ScannerSpectrumCore.SignalFrame] {
        effectiveFrames.map { $0.toCoreFrame() }
    }

    var body: some View {
        ScannerSpectrumCore.SpectrumFieldView(events: coreEvents, frames: coreFrames)
            .onAppear {
                frozenEvents = events
                frozenFrames = frames
            }
            .onChange(of: events) { newValue in
                if !paused {
                    frozenEvents = newValue
                }
            }
            .onChange(of: frames) { newValue in
                if !paused {
                    frozenFrames = newValue
                }
            }
            .onChange(of: paused) { isPaused in
                if isPaused {
                    frozenEvents = events
                    frozenFrames = frames
                }
            }
    }
}

private enum CoreSpectrumBridge {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension NormalizedEvent {
    func toCoreEvent() -> ScannerSpectrumCore.NormalizedEvent {
        let timestamp = eventTs ?? recvTs ?? Date()
        let canonical = ScannerSpectrumCore.CanonicalEvent(
            id: id,
            recvTs: Int((recvTs ?? timestamp).timeIntervalSince1970 * 1000),
            eventTs: CoreSpectrumBridge.iso8601.string(from: timestamp),
            nodeID: nodeID,
            kind: kind,
            severity: severity,
            summary: summary,
            data: data.mapValues { $0.toCoreJSONValue() }
        )
        return ScannerSpectrumCore.NormalizedEvent(from: canonical)
    }
}

private extension SignalFrame {
    func toCoreFrame() -> ScannerSpectrumCore.SignalFrame {
        ScannerSpectrumCore.SignalFrame(
            t: t,
            source: source,
            nodeID: nodeID,
            deviceID: deviceID,
            channel: channel,
            frequency: frequency,
            rssi: rssi,
            x: x,
            y: y,
            z: z,
            color: color.toCoreColor(),
            glow: glow,
            persistence: persistence,
            velocity: velocity,
            confidence: confidence
        )
    }
}

private extension FrameColor {
    func toCoreColor() -> ScannerSpectrumCore.FrameColor {
        ScannerSpectrumCore.FrameColor(h: h, s: s, l: l)
    }
}

private extension JSONValue {
    func toCoreJSONValue() -> ScannerSpectrumCore.JSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .number(value)
        case .bool(let value):
            return .bool(value)
        case .object(let value):
            let mapped = value.mapValues { $0.toCoreJSONValue() }
            return .object(mapped)
        case .array(let value):
            return .array(value.map { $0.toCoreJSONValue() })
        case .null:
            return .null
        }
    }
}

struct NodeRow: View {
    let node: SignalNode
    let alias: String?
    let presence: NodePresence?
    let presentation: NodePresentation
    let selected: Bool
    let onToggle: () -> Void
    let onOpenWhoami: () -> Void
    let onOpenHealth: () -> Void
    let onOpenMetrics: () -> Void
    let onOpenTools: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(presentation.displayColor))
                    .frame(width: 8, height: 8)
                    .shadow(color: presentation.shouldGlow ? Color(presentation.baseColor).opacity(0.35) : .clear, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.id)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(presentation.isOffline ? Theme.muted : Theme.textPrimary)
                    if let alias, !alias.isEmpty, alias != node.id {
                        Text(alias)
                            .font(.system(size: 10))
                            .foregroundColor(presentation.isOffline ? Theme.muted : .secondary)
                    }
                    Text(node.hostname ?? node.ip ?? "Unknown host")
                        .font(.system(size: 10))
                        .foregroundColor(presentation.isOffline ? Theme.muted : .secondary)
                    if let lastSeen = lastSeenLabel() {
                        Text("Last seen: \(lastSeen)")
                            .font(.system(size: 10))
                            .foregroundColor(presentation.isOffline ? Theme.muted : .secondary)
                    }
                    if let lastError = lastErrorLabel() {
                        Text("Last error: \(lastError)")
                            .font(.system(size: 10))
                            .foregroundColor(presentation.isOffline ? Theme.muted : .secondary)
                    }
                }
                Spacer()
                Text(presentation.isOffline ? "Offline" : (node.isStale ? "Stale" : "Live"))
                    .font(.system(size: 10))
                    .foregroundColor(presentation.isOffline ? Theme.muted : (node.isStale ? .orange : .green))
            }
            HStack(spacing: 6) {
                Button { onToggle() } label: {
                    Image(systemName: selected ? "eye.slash" : "eye")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help(selected ? "Hide" : "Show")
                    .accessibilityLabel(Text(selected ? "Hide" : "Show"))
                Button { onOpenWhoami() } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Whoami")
                    .accessibilityLabel(Text("Whoami"))
                    .disabled(node.ip == nil)
                Button { onOpenHealth() } label: {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Health")
                    .accessibilityLabel(Text("Health"))
                    .disabled(node.ip == nil)
                Button { onOpenMetrics() } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Metrics")
                    .accessibilityLabel(Text("Metrics"))
                    .disabled(node.ip == nil)
                Button { onOpenTools() } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Tools")
                    .accessibilityLabel(Text("Tools"))
                Spacer()
            }
        }
        .padding(6)
        .background(selected ? Theme.panelAlt : Theme.panel)
        .cornerRadius(6)
        .shadow(color: presentation.shouldGlow ? Color(presentation.baseColor).opacity(0.25) : .clear, radius: 6)
        .animation(.easeInOut(duration: 0.25), value: presentation.isOffline)
        .animation(.easeOut(duration: 0.35), value: presentation.activityScore)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }

    private func lastSeenLabel() -> String? {
        if let presence, presence.lastSeen > 0 {
            return Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000).formatted(date: .abbreviated, time: .shortened)
        }
        if node.lastSeen != .distantPast {
            return node.lastSeen.formatted(date: .abbreviated, time: .shortened)
        }
        return nil
    }

    private func lastErrorLabel() -> String? {
        let error = presence?.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return error.isEmpty ? nil : error
    }
}

private extension DateFormatter {
    static let recordingStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct FilterRow: View {
    let label: String
    let color: NSColor
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(color))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(selected ? "Hide" : "Show")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(selected ? Theme.panelAlt : .clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SignalFieldView: View {
    let events: [NormalizedEvent]
    let traceEvents: [NormalizedEvent]
    let frames: [SignalFrame]
    let framesAreDerived: Bool
    let paused: Bool
    let decayRate: Double
    let timeScale: Double
    let maxParticles: Int
    let intensity: SignalIntensity
    let replayEnabled: Bool
    let replayOffset: Double
    let ghostTrails: Bool
    let topologyClarity: Bool
    let protocolLanes: Bool
    let recentOnlyLinks: Bool
    let targetSpotlight: Bool
    let aliases: [String: String]
    let nodePresentations: [String: NodePresentation]
    let focusID: String?
    @ObservedObject var entityStore: EntityStore
    let onOpenTools: () -> Void

    @StateObject private var engine = SignalFieldEngine()
    @State private var mousePoint: CGPoint = .zero
    @State private var lastMouseMove: Date = .distantPast
    @State private var selectedNode: SignalFieldEngine.ProjectedNode?
    @State private var hoveredEdge: SignalFieldEngine.ProjectedEdge?
    @State private var selectedEdge: SignalFieldEngine.ProjectedEdge?
    @State private var focusedNodeID: String?
    @State private var pinnedNodeIDs: Set<String> = []
    @State private var quickOverlayVisible: Bool = false
    @State private var quickOverlayHideAt: Date = .distantPast

    var body: some View {
        ZStack {
            // Keep the field bounded while staying fluid enough to avoid choppy motion.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let parallax = Parallax.offset(mousePoint: mousePoint, size: size, now: timeline.date, lastMove: lastMouseMove)
                    let isActive = fieldIsActive(now: timeline.date)
                    engine.render(
                        context: &context,
                        size: size,
                        now: timeline.date,
                        events: events,
                        frames: frames,
                        paused: paused,
                        decayRate: decayRate,
                        timeScale: timeScale,
                        maxParticles: maxParticles,
                        intensity: intensity,
                        parallax: parallax,
                        selectedID: selectedNode?.id,
                        focusID: focusID ?? focusedNodeID,
                        ghostTrails: ghostTrails,
                        topologyClarity: topologyClarity,
                        protocolLanes: protocolLanes,
                        recentOnlyLinks: recentOnlyLinks,
                        targetSpotlight: targetSpotlight,
                        nodePresentations: nodePresentations,
                        framesAreDerived: framesAreDerived,
                        isActive: isActive
                    )
                }
            }
            .overlay(MouseTracker { location in
                mousePoint = location
                lastMouseMove = Date()
                hoveredEdge = engine.nearestEdge(to: location)
            })
            .onChange(of: focusID ?? "") { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                focusedNodeID = trimmed.isEmpty ? nil : trimmed
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                if let hit = engine.nearestNode(to: value.location) {
                    selectedNode = hit
                    selectedEdge = nil
                    quickOverlayVisible = false
                } else if let edgeHit = engine.nearestEdge(to: value.location) {
                    selectedEdge = edgeHit
                    selectedNode = nil
                    quickOverlayVisible = false
                } else {
                    selectedNode = nil
                    selectedEdge = nil
                    quickOverlayVisible = true
                    quickOverlayHideAt = Date().addingTimeInterval(2.5)
                }
            })

            if let hoveredEdge, selectedNode == nil, selectedEdge == nil {
                EdgeHoverTooltipView(edge: hoveredEdge)
                    .position(
                        x: max(180, min(mousePoint.x + 220, 1200)),
                        y: max(84, min(mousePoint.y + 36, 700))
                    )
                    .transition(.opacity)
            }

            if quickOverlayVisible {
                let now = Date()
                let isLive = fieldIsActive(now: now)
                QuickOverlayView(
                    activeCount: max(frames.count, events.count),
                    hottestSource: hottestLabel,
                    status: isLive ? "Live" : "Idle",
                    focused: focusedLabel
                )
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if Date() >= quickOverlayHideAt {
                            quickOverlayVisible = false
                        }
                    }
                }
            }

            if let node = selectedNode {
                let detail = resolveDetail(for: node)
                let actions = buildActions(for: detail)
                ZStack {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNode = nil
                        }

                    NodeInspectorView(
                        node: node,
                        presentation: nodePresentations[node.id] ?? NodePresentation.forNode(
                            id: node.id,
                            keys: [node.id],
                            isOnline: true,
                            activityScore: 0
                        ),
                        alias: aliases[node.id],
                        suggestions: Array(Set(aliases.values)).sorted(),
                        detail: detail,
                        actions: actions,
                        focused: focusedNodeID == node.id,
                        pinned: pinnedNodeIDs.contains(node.id),
                        onFocus: {
                            focusedNodeID = (focusedNodeID == node.id) ? nil : node.id
                            persistState()
                        },
                        onPin: {
                            if pinnedNodeIDs.contains(node.id) {
                                pinnedNodeIDs.remove(node.id)
                            } else {
                                pinnedNodeIDs.insert(node.id)
                            }
                            persistState()
                        },
                        onSaveAlias: { alias in
                            SODSStore.shared.setAlias(id: node.id, alias: alias)
                        },
                        onClose: {
                            selectedNode = nil
                        }
                    )
                    .frame(maxWidth: 780)
                    .padding(28)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .zIndex(20)
            }

            if let selectedEdge {
                ZStack {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.selectedEdge = nil
                        }
                    EdgeTracePanelView(
                        edge: selectedEdge,
                        traces: edgeTraceEntries(for: selectedEdge),
                        onClose: { self.selectedEdge = nil }
                    )
                    .frame(maxWidth: 820)
                    .padding(28)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .zIndex(21)
            }

            if !fieldIsActive(now: Date()) {
                IdleOverlayView()
            }

            if !pinnedNodeIDs.isEmpty {
                PinnedNodesView(
                    pinned: pinnedNodeIDs.sorted(),
                    aliases: aliases,
                    onClear: { pinnedNodeIDs.removeAll(); persistState() },
                    onFocus: { id in focusedNodeID = id; persistState() }
                )
            }

            if replayEnabled {
                ReplayBarView(progress: replayOffset / 60.0, label: "\(Int(replayOffset))s", onSeek: { progress in
                    let next = progress * 60.0
                    NotificationCenter.default.post(name: .sodsReplaySeek, object: next)
                })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .onAppear {
            loadPersistedState()
        }
    }

    private var hottestLabel: String {
        if let hottest = frames.max(by: { ($0.glow ?? 0) < ($1.glow ?? 0) }) {
            return resolvedDisplayLabel(primaryID: hottest.deviceID)
        }
        if let hottestEvent = events.max(by: { (a, b) in
            let sa = a.signal.strength ?? -100
            let sb = b.signal.strength ?? -100
            return sa < sb
        }) {
            let id = hottestEvent.deviceID ?? hottestEvent.nodeID
            return resolvedDisplayLabel(primaryID: id, nodeID: hottestEvent.nodeID)
        }
        return "idle"
    }

    private var focusedLabel: String? {
        guard let focusedNodeID else { return nil }
        return resolvedDisplayLabel(primaryID: focusedNodeID)
    }

    private func resolvedDisplayLabel(primaryID: String, nodeID: String? = nil) -> String {
        var keys: [String] = [primaryID]
        if !primaryID.hasPrefix("node:") {
            keys.append("node:\(primaryID)")
        }
        if let nodeID, !nodeID.isEmpty {
            keys.append(nodeID)
            keys.append("node:\(nodeID)")
        }
        if let resolved = IdentityResolver.shared.resolveLabel(keys: keys), !resolved.isEmpty {
            return resolved
        }
        for key in keys {
            if let alias = aliases[key], !alias.isEmpty {
                return alias
            }
        }
        return primaryID
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        if let focused = defaults.string(forKey: "SODSFocusNodeID") {
            focusedNodeID = focused
        }
        if let pinned = defaults.array(forKey: "SODSPinnedNodeIDs") as? [String] {
            pinnedNodeIDs = Set(pinned)
        }
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(focusedNodeID, forKey: "SODSFocusNodeID")
        defaults.set(Array(pinnedNodeIDs), forKey: "SODSPinnedNodeIDs")
    }

    private var activityWindow: TimeInterval { 4.5 }

    private func fieldIsActive(now: Date) -> Bool {
        if replayEnabled {
            return !frames.isEmpty || !events.isEmpty
        }
        if !frames.isEmpty { return true }
        return events.contains { event in
            let ts = event.eventTs ?? event.recvTs ?? now
            return now.timeIntervalSince(ts) <= activityWindow
        }
    }

    private func resolveDetail(for node: SignalFieldEngine.ProjectedNode) -> SignalDetail {
        let id = node.id
        let nodeID: String? = {
            if id.hasPrefix("node:") {
                return String(id.dropFirst(5))
            }
            if entityStore.nodes.contains(where: { $0.id == id }) {
                return id
            }
            return nil
        }()

        let latestEvent = events.reversed().first { event in
            if event.deviceID == id { return true }
            if event.nodeID == id { return true }
            if let nodeID, event.nodeID == nodeID { return true }
            if let nodeID, event.deviceID == "node:\(nodeID)" { return true }
            return false
        }
        let latestFrame = frames.reversed().first { frame in
            if frame.deviceID == id { return true }
            if let nodeID, frame.deviceID == nodeID { return true }
            if let nodeID, frame.deviceID == "node:\(nodeID)" { return true }
            return false
        }

        let nodeRecord = nodeID.flatMap { lookupNodeRecord($0) }
        let bleID = id.hasPrefix("ble:") ? String(id.dropFirst(4)) : id
        let blePeripheral = entityStore.blePeripherals.first { $0.fingerprintID == bleID || $0.fingerprintID == id }
        let device = entityStore.devices.first { $0.id == id || $0.ip == id }
        let host = entityStore.hosts.first { $0.ip == id }

        let alias = resolvedDisplayLabel(primaryID: id, nodeID: nodeID)
        let label = nodeRecord?.label
            ?? (alias == id ? nil : alias)
            ?? blePeripheral?.name
            ?? device?.httpTitle
            ?? host?.hostname
            ?? id

        let kindRaw = latestEvent?.kind ?? latestFrame?.source ?? (nodeRecord != nil ? "node" : "signal")
        let renderKind = latestEvent.map { SignalRenderKind.from(event: $0) } ?? SignalRenderKind.from(source: kindRaw)
        let kindLabel = renderKind == .generic ? kindRaw : renderKind.label

        let lastSeen: Date? = {
            if let event = latestEvent {
                return event.eventTs ?? event.recvTs
            }
            if let frame = latestFrame {
                return Date(timeIntervalSince1970: TimeInterval(frame.t) / 1000)
            }
            if let nodeRecord = nodeRecord {
                return nodeRecord.lastSeen ?? nodeRecord.lastHeartbeat
            }
            return blePeripheral?.lastSeen
        }()

        let rssi: Double? = latestEvent?.signal.strength ?? latestFrame?.rssi ?? blePeripheral?.smoothedRSSI
        let channel: String? = latestEvent?.signal.channel ?? latestFrame.map { "\($0.channel)" }
        let lastError = nodeRecord?.lastError

        return SignalDetail(
            id: id,
            nodeID: nodeID ?? nodeRecord?.id,
            label: label,
            kind: kindRaw,
            kindLabel: kindLabel,
            lastSeen: lastSeen,
            lastError: lastError,
            rssi: rssi,
            channel: channel,
            ip: nodeRecord?.ip ?? device?.ip ?? host?.ip,
            hostname: nodeRecord?.hostname ?? host?.hostname,
            mac: nodeRecord?.mac ?? host?.macAddress ?? device?.macAddress,
            capabilities: nodeRecord?.capabilities ?? []
        )
    }

    private func lookupNodeRecord(_ nodeID: String) -> NodeRecord? {
        entityStore.nodes.first { $0.id == nodeID }
    }

    private func buildActions(for detail: SignalDetail) -> [SignalAction] {
        var actions: [SignalAction] = [
            SignalAction(title: "Tools", enabled: true, action: { onOpenTools() }),
            SignalAction(title: "God Button", enabled: true, action: {
                NotificationCenter.default.post(name: .targetLockNodeCommand, object: detail.nodeID ?? detail.id)
            })
        ]
        guard let nodeID = detail.nodeID else { return actions }

        let caps = detail.capabilities
        let canIdentify = caps.isEmpty || caps.contains("identify") || caps.contains("whoami")
        let hostHint = (detail.ip?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? detail.ip
            : detail.hostname
        let canRouteToNode = (hostHint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        actions.append(
            SignalAction(title: "Connect", enabled: canRouteToNode, action: {
                NodeRegistry.shared.setConnecting(nodeID: nodeID, connecting: true)
                SODSStore.shared.connectNode(nodeID, hostHint: hostHint)
                SODSStore.shared.identifyNode(nodeID, hostHint: hostHint)
                SODSStore.shared.refreshStatus()
            })
        )

        if canIdentify {
            actions.append(
                SignalAction(title: "Identify", enabled: canRouteToNode, action: {
                    SODSStore.shared.identifyNode(nodeID, hostHint: hostHint)
                    SODSStore.shared.refreshStatus()
                })
            )
        }

        if let signalNode = signalNode(from: detail) {
            actions.append(
                SignalAction(title: "Whoami", enabled: signalNode.ip != nil, action: {
                    SODSStore.shared.openEndpoint(for: signalNode, path: "/whoami")
                })
            )
            actions.append(
                SignalAction(title: "Health", enabled: signalNode.ip != nil, action: {
                    SODSStore.shared.openEndpoint(for: signalNode, path: "/health")
                })
            )
            actions.append(
                SignalAction(title: "Metrics", enabled: signalNode.ip != nil, action: {
                    SODSStore.shared.openEndpoint(for: signalNode, path: "/metrics")
                })
            )
        }

        var deduped: [SignalAction] = []
        var seen = Set<String>()
        for action in actions {
            if seen.insert(action.title).inserted {
                deduped.append(action)
            }
        }
        return deduped
    }

    private func signalNode(from detail: SignalDetail) -> SignalNode? {
        guard let nodeID = detail.nodeID else { return nil }
        return SignalNode(
            id: nodeID,
            lastSeen: detail.lastSeen ?? .distantPast,
            ip: detail.ip,
            hostname: detail.hostname,
            mac: detail.mac,
            lastKind: detail.kind
        )
    }

    private func edgeTraceEntries(for edge: SignalFieldEngine.ProjectedEdge) -> [EdgeTraceEntry] {
        let now = Date()
        return traceEvents
            .reversed()
            .compactMap { event -> EdgeTraceEntry? in
                guard let sample = SignalFieldEngine.classifyEdgeSample(from: event, now: now) else { return nil }
                guard sample.signalType == edge.signalType else { return nil }
                guard sample.transport == edge.transport else { return nil }
                guard sample.sourceID == edge.sourceID else { return nil }
                guard sample.targetID == edge.targetID else { return nil }
                let timestamp = event.eventTs ?? event.recvTs ?? now
                let latency = SignalFieldEngine.extractLatencyMs(from: event.data)
                let bytes = SignalFieldEngine.estimateEventBytes(event)
                return EdgeTraceEntry(
                    id: event.id,
                    kind: event.kind,
                    summary: event.summary,
                    timestamp: timestamp,
                    sourceID: sample.sourceID,
                    targetID: sample.targetID,
                    latencyMs: latency,
                    bytes: bytes,
                    status: sample.status
                )
            }
            .prefix(24)
            .map { $0 }
    }
}

struct LegendOverlayView: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    legendRow(color: SignalColor.kindAccent(kind: "ble.seen"), label: "BLE • dot + tight ring")
                    legendRow(color: SignalColor.kindAccent(kind: "wifi.status", channel: "6"), label: "Wi‑Fi 2.4G • wave ring")
                    legendRow(color: SignalColor.kindAccent(kind: "wifi.status", channel: "36"), label: "Wi‑Fi 5G • wave ring")
                    legendRow(color: SignalColor.kindAccent(kind: "rf"), label: "RF • wave burst")
                    legendRow(color: SignalColor.kindAccent(kind: "node.heartbeat"), label: "Node • diamond halo")
                    legendRow(color: SignalColor.kindAccent(kind: "tool"), label: "Action • pulse burst")
                    legendRow(color: SignalColor.kindAccent(kind: "error"), label: "Error • starburst")
                    Text("Type-first color coding: hue = signal class, tint = device identity.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Brightness = recency + strength. Trails fade with time.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Depth = size/blur/alpha/parallax cues.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("What you're seeing")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func legendRow(color: NSColor, label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(color))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10))
        }
    }
}

struct QuickOverlayView: View {
    let activeCount: Int
    let hottestSource: String
    let status: String
    let focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signal Field")
                .font(.system(size: 12, weight: .semibold))
            Text("Status: \(status)")
                .font(.system(size: 11))
            Text("Active sources: \(activeCount)")
                .font(.system(size: 11))
            Text("Hottest: \(hottestSource)")
                .font(.system(size: 11))
            if let focused {
                Text("Focus: \(focused)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(10)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PinnedNodesView: View {
    let pinned: [String]
    let aliases: [String: String]
    let onClear: () -> Void
    let onFocus: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pinned")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { onClear() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Clear")
                .accessibilityLabel(Text("Clear"))
            }
            ForEach(pinned, id: \.self) { id in
                HStack(spacing: 6) {
                    Text(aliases[id] ?? id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button { onFocus(id) } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Focus")
                    .accessibilityLabel(Text("Focus"))
                }
            }
        }
        .padding(10)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(10)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

struct ReplayBarView: View {
    let progress: Double
    let label: String
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("Replay \(label)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            GeometryReader { geo in
                let width = geo.size.width
                let filled = max(0, min(1, progress)) * width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelAlt)
                    Capsule().fill(Color.red.opacity(0.7)).frame(width: filled)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let p = max(0, min(1, value.location.x / max(1, width)))
                    onSeek(p)
                })
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(10)
        .padding(16)
        .frame(maxWidth: 240, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct SignalDetail: Hashable {
    let id: String
    let nodeID: String?
    let label: String
    let kind: String
    let kindLabel: String
    let lastSeen: Date?
    let lastError: String?
    let rssi: Double?
    let channel: String?
    let ip: String?
    let hostname: String?
    let mac: String?
    let capabilities: [String]
}

struct SignalAction: Identifiable {
    let id = UUID()
    let title: String
    let enabled: Bool
    let action: () -> Void
}

struct EdgeTraceEntry: Identifiable, Hashable {
    let id: String
    let kind: String
    let summary: String
    let timestamp: Date
    let sourceID: String
    let targetID: String
    let latencyMs: Double?
    let bytes: Double
    let status: SpectrumEdgeStatus
}

struct EdgeHoverTooltipView: View {
    let edge: SignalFieldEngine.ProjectedEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(edge.sourceLabel) → \(edge.targetLabel)")
                .font(.system(size: 11, weight: .semibold))
            Text("Type: \(edge.signalType.label) • Transport: \(edge.transport.label)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(String(format: "rps %.2f • latency %.0fms • bytes/s %.0f", edge.metrics.rps, edge.metrics.latencyMs, edge.metrics.bytesPerSec))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text("Last seen: \(edge.metrics.lastSeenText) • \(edge.status.label)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
}

struct EdgeTracePanelView: View {
    let edge: SignalFieldEngine.ProjectedEdge
    let traces: [EdgeTraceEntry]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edge Trace")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(edge.sourceLabel) → \(edge.targetLabel)")
                        .font(.system(size: 11))
                    Text("Type: \(edge.signalType.label) • Transport: \(edge.transport.label) • \(edge.status.label)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Close")
                .accessibilityLabel(Text("Close"))
                .keyboardShortcut(.cancelAction)
            }
            if traces.isEmpty {
                Text("No matching traces in current event window.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(traces) { trace in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(trace.summary)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(trace.kind)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text(
                                    String(
                                        format: "%@ • latency %.0fms • bytes %.0f • %@",
                                        trace.timestamp.formatted(date: .abbreviated, time: .standard),
                                        trace.latencyMs ?? 0,
                                        trace.bytes,
                                        trace.status.label
                                    )
                                )
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Theme.panelAlt)
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct NodeInspectorView: View {
    let node: SignalFieldEngine.ProjectedNode
    let presentation: NodePresentation
    let alias: String?
    let suggestions: [String]
    let detail: SignalDetail
    let actions: [SignalAction]
    let focused: Bool
    let pinned: Bool
    let onFocus: () -> Void
    let onPin: () -> Void
    let onSaveAlias: (String) -> Void
    let onClose: () -> Void

    @State private var aliasText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Node Inspector")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Close")
                .accessibilityLabel(Text("Close"))
                .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(presentation.displayColor))
                    .frame(width: 10, height: 10)
                    .shadow(color: presentation.shouldGlow ? Color(presentation.baseColor).opacity(0.35) : .clear, radius: 6)
                Text(detail.label)
                    .font(.system(size: 11, weight: .semibold))
                Text("(\(detail.id))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Kind: \(detail.kindLabel)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if let lastSeen = detail.lastSeen {
                    Text("Last seen: \(lastSeen.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let lastError = detail.lastError, !lastError.isEmpty {
                    Text("Last error: \(lastError)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let rssi = detail.rssi {
                    Text("RSSI: \(String(format: "%.0f", rssi)) dBm")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let channel = detail.channel, !channel.isEmpty {
                    Text("Channel: \(channel)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let host = detail.hostname, !host.isEmpty {
                    Text("Host: \(host)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let ip = detail.ip, !ip.isEmpty {
                    Text("IP: \(ip)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let mac = detail.mac, !mac.isEmpty {
                    Text("MAC: \(mac)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if !detail.capabilities.isEmpty {
                    Text("Capabilities: \(detail.capabilities.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Alias")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("set alias", text: $aliasText)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { aliasText = alias ?? "" }
                if !aliasText.isEmpty {
                    let matches = suggestions.filter { $0.localizedCaseInsensitiveContains(aliasText) }.prefix(4)
                    if !matches.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(matches), id: \.self) { item in
                                Button(item) { aliasText = item }
                                    .buttonStyle(SecondaryActionButtonStyle())
                            }
                        }
                    }
                }
                Button { onSaveAlias(aliasText) } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Save Alias")
                .accessibilityLabel(Text("Save Alias"))
            }
            if !actions.isEmpty {
                let columns = [GridItem(.adaptive(minimum: 132), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(actions) { action in
                        HStack(spacing: 8) {
                            Text(action.title)
                                .font(.system(size: 11))
                                .foregroundColor(action.enabled ? Theme.textPrimary : Theme.textSecondary)
                            Spacer()
                            Button { action.action() } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(!action.enabled)
                            .help(action.title)
                            .accessibilityLabel(Text(action.title))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.panelAlt)
                        .cornerRadius(8)
                    }
                }
            } else {
                Text("No actions available.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text("Depth: \(String(format: "%.2f", node.depth))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button { onFocus() } label: {
                    Image(systemName: focused ? "scope" : "scope")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help(focused ? "Unfocus" : "Focus")
                .accessibilityLabel(Text(focused ? "Unfocus" : "Focus"))

                Button { onPin() } label: {
                    Image(systemName: pinned ? "pin.slash" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help(pinned ? "Unpin" : "Pin")
                .accessibilityLabel(Text(pinned ? "Unpin" : "Pin"))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct IdleOverlayView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Field idle")
                .font(.system(size: 14, weight: .semibold))
            Text("Start a scan or run a tool to seed the field.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Flash is the only action that opens a browser.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

enum SpectrumSignalType: String, Hashable, Codable {
    case control = "CONTROL"
    case event = "EVENT"
    case evidence = "EVIDENCE"
    case media = "MEDIA"
    case mgmt = "MGMT"

    var label: String { rawValue }

    var edgeColor: NSColor {
        switch self {
        case .control:
            return NSColor(calibratedRed: 0.62, green: 0.39, blue: 1.0, alpha: 1.0) // purple
        case .event:
            return NSColor(calibratedRed: 0.25, green: 0.86, blue: 0.94, alpha: 1.0) // cyan
        case .evidence:
            return NSColor(calibratedRed: 0.97, green: 0.78, blue: 0.30, alpha: 1.0) // gold
        case .media:
            return NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.84, alpha: 1.0) // magenta
        case .mgmt:
            return NSColor(calibratedRed: 0.98, green: 0.57, blue: 0.24, alpha: 1.0) // orange
        }
    }
}

enum SpectrumTransport: String, Hashable, Codable {
    case http = "HTTP/REST"
    case livekit = "WebSocket/LiveKit"
    case ssh = "SSH"
    case ble = "BLE"
    case wifiPassive = "Wi-Fi Passive"
    case serial = "Serial/USB"
    case unknown = "Unknown"

    var label: String { rawValue }
}

enum SpectrumEdgeStatus: String, Hashable, Codable {
    case active
    case idle
    case error

    var label: String { rawValue.capitalized }
}

struct SpectrumEdgeMetrics: Hashable {
    let rps: Double
    let bytesPerSec: Double
    let latencyMs: Double
    let lastSeenMs: Double
    let lastSeenText: String
    let signalStrengthDbm: Double?
}

struct SpectrumEdgeSample: Hashable {
    let sourceID: String
    let targetID: String
    let signalType: SpectrumSignalType
    let transport: SpectrumTransport
    let status: SpectrumEdgeStatus
    let eventTime: Date
    let latencyMs: Double
    let bytes: Double
    let signalStrengthDbm: Double?
}

// Spectrum Visualizer Core: consumes frames/events and produces a living field state.
final class SignalFieldEngine: ObservableObject {
    private var sources: [String: SignalSource] = [:]
    private var particles: [SignalParticle] = []
    private var processedIDs: Set<String> = []
    private var lastUpdate: Date?
    private var smoothedDeltaTime: Double?
    private var lastProjected: [ProjectedNode] = []
    private var lastProjectedEdges: [ProjectedEdge] = []
    private var pulses: [FieldPulse] = []
    private var lastPulseBySource: [String: Date] = [:]
    private var edgePulses: [EdgePulse] = []
    private var lastEdgePulseBySource: [String: Date] = [:]
    private var edgeGraph: [AggregatedEdge] = []
    private var edgeGraphToken: String = ""
    private var lastEdgeGraphRefresh: Date = .distantPast
    // Keep the field readable: directional line pulses are primary, particles are disabled.
    private let linePulseOnly = true

    struct ProjectedNode: Hashable {
        let id: String
        let point: CGPoint
        let color: NSColor
        let depth: CGFloat
    }

    struct ProjectedEdge: Hashable {
        let id: String
        let sourceID: String
        let targetID: String
        let sourceLabel: String
        let targetLabel: String
        let sourcePoint: CGPoint
        let targetPoint: CGPoint
        let signalType: SpectrumSignalType
        let transport: SpectrumTransport
        let status: SpectrumEdgeStatus
        let typeColor: NSColor
        let deviceTint: NSColor
        let lineWidth: CGFloat
        let alpha: Double
        let metrics: SpectrumEdgeMetrics
    }

    private struct AggregatedEdge: Hashable {
        let id: String
        let sourceID: String
        let targetID: String
        let signalType: SpectrumSignalType
        let transport: SpectrumTransport
        let status: SpectrumEdgeStatus
        let rps: Double
        let bytesPerSec: Double
        let latencyMs: Double
        let lastSeenMs: Double
        let lastSeenText: String
        let signalStrengthDbm: Double?
    }

    struct FieldPulse: Hashable {
        let id: UUID
        let sourceID: String
        let position: SIMD3<Double>
        let color: NSColor
        let renderKind: SignalRenderKind
        let birth: Date
        let lifespan: TimeInterval
        let strength: Double
    }

    struct EdgePulse: Hashable {
        let id: UUID
        let throttleKey: String
        let fromID: String
        let toID: String
        let birth: Date
        let lifespan: TimeInterval
        let strength: Double
        let color: NSColor
        let renderKind: SignalRenderKind
    }

    struct GhostPoint: Hashable {
        let sourceID: String
        let position: SIMD3<Double>
        let color: NSColor
        let ts: Date
    }

    func render(
        context: inout GraphicsContext,
        size: CGSize,
        now: Date,
        events: [NormalizedEvent],
        frames: [SignalFrame],
        paused: Bool,
        decayRate: Double,
        timeScale: Double,
        maxParticles: Int,
        intensity: SignalIntensity,
        parallax: CGPoint,
        selectedID: String?,
        focusID: String?,
        ghostTrails: Bool,
        topologyClarity: Bool,
        protocolLanes: Bool,
        recentOnlyLinks: Bool,
        targetSpotlight: Bool,
        nodePresentations: [String: NodePresentation],
        framesAreDerived: Bool,
        isActive: Bool
    ) {
        drawBackground(context: &context, size: size, now: now, isActive: isActive)

        if !paused {
            if isActive {
                if !frames.isEmpty {
                    ingest(frames: frames, now: now, intensity: intensity)
                    if framesAreDerived {
                        ingest(events: events, intensity: intensity, now: now)
                    }
                } else {
                    ingest(events: events, intensity: intensity, now: now)
                }
            }
            step(now: now, timeScale: timeScale, decayRate: decayRate, isActive: isActive)
        } else {
            lastUpdate = now
            smoothedDeltaTime = nil
        }

        // Enforce particle budget *before* drawing so rendering cost doesn't spike.
        // Calm should be dramatically quieter; Storm can be dense but still bounded.
        let particleBudget = linePulseOnly ? 0 : max(120, min(maxParticles, intensity.particleCap))
        if linePulseOnly {
            particles.removeAll(keepingCapacity: true)
            pulses.removeAll(keepingCapacity: true)
        } else if particles.count > particleBudget {
            particles = Array(particles.suffix(particleBudget))
        }

        let activityFade: CGFloat = isActive ? 1.0 : 0.25
        if !linePulseOnly {
            drawBins(context: &context, size: size, frames: frames, now: now, focusID: focusID, activityFade: activityFade, intensity: intensity)
        }
        lastProjected = drawSources(context: &context, size: size, now: now, parallax: parallax, selectedID: selectedID, focusID: focusID, nodePresentations: nodePresentations, activityFade: activityFade, targetSpotlight: targetSpotlight)
        refreshEdgeGraphIfNeeded(events: events, now: now)
        if ghostTrails {
            if isActive {
                updateGhosts(now: now, nodePresentations: nodePresentations, intensity: intensity)
            }
            drawGhosts(context: &context, size: size, parallax: parallax, focusID: focusID, activityFade: activityFade)
        }
        lastProjectedEdges = drawConnections(context: &context, focusID: focusID, activityFade: activityFade, intensity: intensity, topologyClarity: topologyClarity, recentOnlyLinks: recentOnlyLinks, now: now)
        drawEdgePulses(context: &context, now: now, focusID: focusID, activityFade: activityFade, intensity: intensity, protocolLanes: protocolLanes, targetSpotlight: targetSpotlight)
        if !linePulseOnly {
            drawPulses(context: &context, size: size, now: now, parallax: parallax, focusID: focusID, activityFade: activityFade, targetSpotlight: targetSpotlight)
            drawParticles(context: &context, size: size, now: now, parallax: parallax, focusID: focusID, activityFade: activityFade, budget: particleBudget, targetSpotlight: targetSpotlight)
        }
    }

    private func ingest(events: [NormalizedEvent], intensity: SignalIntensity, now: Date) {
        // Events lists can be long; we only need the tail to catch new arrivals.
        for event in events.suffix(intensity.eventTailLimit) {
            guard processedIDs.insert(event.id).inserted else { continue }
            let key = event.deviceID ?? event.nodeID
            let source = sources[key] ?? SignalSource(id: key)
            source.update(from: event)
            sources[key] = source
            if let sample = Self.classifyEdgeSample(from: event, now: now) {
                ensureEdgeEndpoint(sample.sourceID, event: event, now: now)
                ensureEdgeEndpoint(sample.targetID, event: event, now: now)
            }
            if !linePulseOnly {
                let emitted = SignalEmitter.emit(from: source, event: event, intensity: intensity, now: now)
                particles.append(contentsOf: emitted)
            }

            // BLE can be extremely chatty (metadata/enrichment events). Only emit effects when the device
            // is actually "broadcasting" (i.e., we have strength / a real seen-type signal).
            let isBLE = event.kind.lowercased().contains("ble")
            if !isBLE || SignalEmitter.isBLEBroadcasting(event: event) {
                if !linePulseOnly {
                    seedPulse(id: key, source: source, event: event, now: now, intensity: intensity)
                    if let nodeID = source.lastNodeID, !nodeID.isEmpty, nodeID != "unknown" {
                        let lane = edgeLaneKey(for: event)
                        let commandLike = isCommandLike(kind: event.kind)
                        let fromID = commandLike ? "node:\(nodeID)" : key
                        let toID = commandLike ? key : "node:\(nodeID)"
                        seedEdgePulse(
                            throttleKey: "\(key)|\(nodeID)|\(lane)|\(commandLike ? "out" : "in")",
                            fromID: fromID,
                            toID: toID,
                            strength: source.lastStrength ?? -70,
                            color: SignalColor.typeFirstColor(
                                renderKind: SignalRenderKind.from(event: event),
                                deviceID: key,
                                channel: event.signal.channel
                            ),
                            renderKind: SignalRenderKind.from(event: event),
                            now: now,
                            intensity: intensity
                        )
                    }
                }
            }
        }
        if processedIDs.count > 4000 {
            processedIDs.removeAll(keepingCapacity: true)
        }
    }

    private func ingest(frames: [SignalFrame], now: Date, intensity: SignalIntensity) {
        for frame in frames {
            let key = frame.deviceID
            let source = sources[key] ?? SignalSource(id: key)
            source.update(from: frame)
            sources[key] = source
            let style = SignalFrameStyle.from(frame: frame)
            let renderKind = SignalRenderKind.from(source: frame.source)
            let typeColor = SignalColor.typeFirstColor(
                renderKind: renderKind,
                deviceID: key,
                channel: "\(frame.channel)"
            )
            if !linePulseOnly {
                particles.append(
                    SignalParticle(
                        id: UUID(),
                        kind: .spark,
                        sourceID: key,
                        position: source.position,
                        velocity: SIMD3<Double>(0, 0, 0),
                        birth: now,
                        lifespan: 1.2,
                        baseSize: 10 + style.glow * 12,
                        color: typeColor,
                        strength: max(0.2, style.confidence * 1.4),
                        glow: style.glow,
                        ringRadius: 0,
                        ringWidth: 1.6,
                        trail: [],
                        renderKind: renderKind
                    )
                )
                seedPulse(
                    id: key,
                    color: typeColor,
                    strength: style.glow,
                    source: source,
                    now: now,
                    renderKind: renderKind,
                    intensity: intensity
                )
                if let nodeID = source.lastNodeID, !nodeID.isEmpty, nodeID != "unknown" {
                    seedEdgePulse(
                        throttleKey: "\(key)|\(nodeID)|\(edgeLaneKey(for: frame))|in",
                        fromID: key,
                        toID: "node:\(nodeID)",
                        strength: frame.rssi,
                        color: typeColor,
                        renderKind: renderKind,
                        now: now,
                        intensity: intensity
                    )
                }
            }
        }
    }

    private func step(now: Date, timeScale: Double, decayRate: Double, isActive: Bool) {
        let rawDt: Double
        if let last = lastUpdate {
            rawDt = min(0.05, max(1.0 / 120.0, now.timeIntervalSince(last))) * timeScale
        } else {
            rawDt = (1.0 / 60.0) * timeScale
        }
        lastUpdate = now
        let clampedDt = max(1.0 / 240.0, min(0.05, rawDt))
        if let previous = smoothedDeltaTime {
            smoothedDeltaTime = previous + (clampedDt - previous) * 0.18
        } else {
            smoothedDeltaTime = clampedDt
        }
        let dt = smoothedDeltaTime ?? clampedDt
        let decay = max(0.2, min(2.2, decayRate))
        if isActive {
            applyAttraction()
            applyRepulsion()
        }
        for source in sources.values {
            source.step(dt: dt, isActive: isActive)
        }
        if linePulseOnly {
            particles.removeAll(keepingCapacity: true)
            pulses.removeAll(keepingCapacity: true)
        } else {
            particles = particles.compactMap { particle in
                var particle = particle
                particle.update(dt: dt, decay: decay)
                if particle.isExpired(now: now) {
                    return nil
                }
                return particle
            }
            pulses = pulses.filter { now.timeIntervalSince($0.birth) <= $0.lifespan }
        }
    }

    private func applyAttraction() {
        let nodes = Array(sources.values)
        guard nodes.count > 1, nodes.count <= 120 else { return }
        for i in 0..<(nodes.count - 1) {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                if a.group != b.group { continue }
                let delta = b.position - a.position
                let dist2 = max(0.0001, delta.x * delta.x + delta.y * delta.y)
                if dist2 > 0.08 && dist2 < 0.6 {
                    let strength = (dist2 - 0.08) * 0.04
                    let dir = delta / sqrt(dist2)
                    a.velocity += dir * strength
                    b.velocity -= dir * strength
                }
            }
        }
    }

    private func applyRepulsion() {
        let nodes = Array(sources.values)
        guard nodes.count > 1, nodes.count <= 120 else { return }
        for i in 0..<(nodes.count - 1) {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                let delta = a.position - b.position
                let dist2 = max(0.0001, delta.x * delta.x + delta.y * delta.y)
                if dist2 < 0.18 {
                    let strength = (0.18 - dist2) * 0.34
                    let dir = delta / sqrt(dist2)
                    a.velocity += dir * strength
                    b.velocity -= dir * strength
                }
            }
        }
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize, now: Date, isActive: Bool) {
        let rect = CGRect(origin: .zero, size: size)
        let idleTone: Double = isActive ? 0.0 : 0.12
        let gradient = Gradient(colors: [
            Color(red: 0.05 + idleTone, green: 0.05 + idleTone, blue: 0.08 + idleTone),
            Color(red: 0.06 + idleTone, green: 0.06 + idleTone, blue: 0.11 + idleTone),
            Color(red: 0.03 + idleTone, green: 0.03 + idleTone, blue: 0.06 + idleTone)
        ])
        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let hazeGradient = Gradient(colors: [
            Color(red: 0.16, green: 0.06, blue: 0.12, opacity: 0.12),
            Color(red: 0.02, green: 0.02, blue: 0.05, opacity: 0.0)
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - size.width * 0.46, y: center.y - size.height * 0.46, width: size.width * 0.92, height: size.height * 0.92)),
            with: .radialGradient(hazeGradient, center: center, startRadius: 0, endRadius: min(size.width, size.height) * 0.58)
        )

        // Darken the core so live signals "sit" in the field instead of on a grey plate.
        let coreVignette = Gradient(colors: [
            Color.black.opacity(isActive ? 0.34 : 0.46),
            Color.black.opacity(0.0)
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - size.width * 0.28, y: center.y - size.height * 0.28, width: size.width * 0.56, height: size.height * 0.56)),
            with: .radialGradient(coreVignette, center: center, startRadius: 0, endRadius: min(size.width, size.height) * 0.38)
        )

        for ring in 1...2 {
            let radius = min(size.width, size.height) * 0.12 * CGFloat(ring)
            let ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: ringRect), with: .color(Color.white.opacity(0.02)), lineWidth: 1)
        }

        let starCount = 16
        for i in 0..<starCount {
            let seed = Double(i) * 0.31
            let x = (sin(seed * 12.1) * 0.5 + 0.5) * size.width
            let y = (cos(seed * 9.7) * 0.5 + 0.5) * size.height
            let twinkle = sin(now.timeIntervalSince1970 * 0.2 + seed) * 0.5 + 0.5
            let alpha = (isActive ? 0.02 : 0.01) + (isActive ? 0.018 : 0.008) * twinkle
            let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
            context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(alpha)))
        }

        if !isActive {
            let pulse = 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 0.6)
            let idleGradient = Gradient(colors: [
                Color(red: 0.2, green: 0.2, blue: 0.25, opacity: 0.08 + 0.06 * pulse),
                Color(red: 0.05, green: 0.05, blue: 0.08, opacity: 0.0)
            ])
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - size.width * 0.35, y: center.y - size.height * 0.35, width: size.width * 0.7, height: size.height * 0.7)),
                with: .radialGradient(idleGradient, center: center, startRadius: 0, endRadius: min(size.width, size.height) * 0.5)
            )
            context.fill(Path(rect), with: .color(Color.black.opacity(0.28)))
        }
    }

    private func drawBins(context: inout GraphicsContext, size: CGSize, frames: [SignalFrame], now: Date, focusID: String?, activityFade: CGFloat, intensity: SignalIntensity) {
        guard !frames.isEmpty else { return }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let minDim = min(size.width, size.height)
        for frame in frames.prefix(intensity.frameBinLimit) {
            let channelMax: Double
            if frame.source == "ble" { channelMax = 39 }
            else if frame.source == "wifi" { channelMax = 165 }
            else { channelMax = 13 }
            let norm = channelMax > 0 ? min(1.0, max(0.0, Double(frame.channel) / channelMax)) : 0.5
            let angle = Angle(radians: norm * Double.pi * 2)
            let radiusBase: Double = frame.source == "ble" ? 0.22 : frame.source == "wifi" ? 0.34 : 0.46
            let radius = minDim * (radiusBase + Double(frame.persistence) * 0.08)
            let arcWidth = minDim * 0.02
            let start = Angle(radians: angle.radians - 0.08)
            let end = Angle(radians: angle.radians + 0.08)
            let dimmed = focusID != nil && focusID != frame.deviceID
            let frameTint = NSColor(
                calibratedHue: CGFloat(frame.color.h / 360.0),
                saturation: CGFloat(frame.color.s),
                brightness: CGFloat(frame.color.l),
                alpha: 1.0
            )
            let typeColor = SignalColor.renderKindAccent(
                renderKind: SignalRenderKind.from(source: frame.source),
                channel: "\(frame.channel)"
            )
            let color = Color(SignalColor.mix(typeColor, frameTint, ratio: 0.18))
            var path = Path()
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            let alpha = (dimmed ? 0.08 : 0.18) * activityFade
            context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: arcWidth)
        }
    }

    private func drawSources(
        context: inout GraphicsContext,
        size: CGSize,
        now: Date,
        parallax: CGPoint,
        selectedID: String?,
        focusID: String?,
        nodePresentations: [String: NodePresentation],
        activityFade: CGFloat,
        targetSpotlight: Bool
    ) -> [ProjectedNode] {
        var projected: [ProjectedNode] = []
        for source in sources.values {
            let depth = depthScalar(id: source.id, z: source.position.z, now: now)
            let basePoint = source.project(in: size, parallax: .zero)
            let point = CGPoint(x: basePoint.x + parallax.x * depth, y: basePoint.y + parallax.y * depth)
            let depthFade = depthFade(for: depth)
            let strength = source.lastStrength ?? -65
            let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
            let renderKind: SignalRenderKind = {
                if let lastKind = source.lastKind, !lastKind.isEmpty {
                    return SignalRenderKind.from(source: lastKind)
                }
                return SignalRenderKind.from(source: source.group)
            }()
            let typeColor = SignalColor.renderKindAccent(renderKind: renderKind, channel: source.lastChannel)
            let deviceTint = SignalColor.deviceColor(id: source.id, saturation: 0.58, brightness: 0.94)
            let typeFirstColor = SignalColor.mix(typeColor, deviceTint, ratio: 0.22)
            let glowScale = CGFloat(1.0 + strengthNorm * 0.55)
            let glow = CGSize(width: 34 * depth * glowScale, height: 34 * depth * glowScale)
            let core = CGSize(width: 13.6 * depth, height: 13.6 * depth)
            let dimmed = focusID != nil && focusID != source.id
            let presentation = nodePresentations[source.id] ?? nodePresentations["node:\(source.id)"]
            let displayColor: NSColor
            if let presentationColor = presentation?.displayColor {
                displayColor = SignalColor.mix(typeFirstColor, presentationColor, ratio: 0.28)
            } else {
                displayColor = typeFirstColor
            }
            let isNodeSource = nodePresentations[source.id] != nil || nodePresentations["node:\(source.id)"] != nil || source.id.hasPrefix("node:")
            let coreTint: NSColor = {
                if presentation?.isOffline == true { return displayColor }
                if isNodeSource { return SignalColor.mix(displayColor, NSColor.systemRed, ratio: 0.55) }
                return displayColor
            }()
            let color = Color(displayColor).opacity(dimmed ? 0.25 : 1.0)
            let lastSeen = source.lastSeen ?? now
            let age = max(0.0, now.timeIntervalSince(lastSeen))
            let recency = exp(-age / 6.0)
            let vitality = max(0.12, min(1.0, 0.2 + recency * 0.6 + strengthNorm * 0.35))
            let vitalityScale = CGFloat(vitality)
            let focusScale: CGFloat = dimmed ? (targetSpotlight ? 0.26 : 0.45) : 1.0
            let alphaScale = activityFade * depthFade * focusScale * vitalityScale
            let glowBoost = CGFloat(0.55 + strengthNorm * 0.9)
            let glowAlpha = presentation?.shouldGlow == false ? 0.0 : (dimmed ? 0.08 : 0.2) * alphaScale * glowBoost
            let coreAlpha = presentation?.isOffline == true ? 0.35 * alphaScale : (dimmed ? 0.4 : 0.9) * alphaScale
            let activity = presentation?.activityScore ?? 0.0
            let accentColor = SignalColor.mix(displayColor, NSColor.systemRed, ratio: 0.55)
            let blurStrength = max(0.0, (0.95 - depth) * 0.7)

            let glowRect = CGRect(x: point.x - glow.width / 2, y: point.y - glow.height / 2, width: glow.width, height: glow.height)
            if glowAlpha > 0 {
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(glowAlpha)))
            }

            let coreRect = CGRect(x: point.x - core.width / 2, y: point.y - core.height / 2, width: core.width, height: core.height)
            if blurStrength > 0.01 {
                let blurRect = coreRect.insetBy(dx: -core.width * 0.6, dy: -core.height * 0.6)
                context.fill(Path(ellipseIn: blurRect), with: .color(color.opacity(blurStrength * 0.12)))
            }
            let coreDrawColor = Color(coreTint).opacity(coreAlpha)
            if isNodeSource {
                context.fill(diamondPath(in: coreRect), with: .color(coreDrawColor))
            } else {
                context.fill(Path(ellipseIn: coreRect), with: .color(coreDrawColor))
            }
            if activity > 0.01, presentation?.isOffline == false {
                let pulse = NodePresentation.pulse(now: now, seed: source.id)
                let ringScale = CGFloat((1.4 + activity * 2.2) * pulse) * depth
                let ringSize = CGSize(width: core.width * ringScale, height: core.height * ringScale)
                let ringRect = CGRect(
                    x: point.x - ringSize.width / 2,
                    y: point.y - ringSize.height / 2,
                    width: ringSize.width,
                    height: ringSize.height
                )
                let ringAlpha = min(0.22, 0.08 + activity * 0.18) * (dimmed ? 0.5 : 1.0) * Double(alphaScale)
                context.stroke(Path(ellipseIn: ringRect), with: .color(color.opacity(ringAlpha)), lineWidth: 1.2)
            }
            if isNodeSource {
                let ringRect = coreRect.insetBy(dx: -4 * depth, dy: -4 * depth)
                let ringAlpha = (presentation?.isOffline == true ? 0.15 : 0.35) * alphaScale
                context.stroke(Path(ellipseIn: ringRect), with: .color(Color(accentColor).opacity(ringAlpha)), lineWidth: 1.2)
            }
            if let selectedID, selectedID == source.id {
                context.stroke(Path(ellipseIn: glowRect), with: .color(color.opacity(0.9)), lineWidth: 2.0)
            }
            projected.append(ProjectedNode(id: source.id, point: point, color: displayColor, depth: depth))
        }
        return projected
    }

    private func drawParticles(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, focusID: String?, activityFade: CGFloat, budget: Int, targetSpotlight: Bool) {
        for particle in particles.suffix(budget) {
            let dimmed = focusID != nil && focusID != particle.sourceID
            particle.draw(
                context: &context,
                size: size,
                now: now,
                parallax: parallax,
                dimmed: dimmed,
                activityFade: activityFade,
                dimFactor: targetSpotlight ? 0.45 : 1.0
            )
        }
    }

    private func drawConnections(
        context: inout GraphicsContext,
        focusID: String?,
        activityFade: CGFloat,
        intensity: SignalIntensity,
        topologyClarity: Bool,
        recentOnlyLinks: Bool,
        now: Date
    ) -> [ProjectedEdge] {
        guard !edgeGraph.isEmpty, lastProjected.count > 1 else { return [] }
        let projectedByID: [String: ProjectedNode] = Dictionary(uniqueKeysWithValues: lastProjected.map { ($0.id, $0) })

        func resolveProjected(_ id: String) -> ProjectedNode? {
            if let direct = projectedByID[id] { return direct }
            if id.hasPrefix("node:") {
                let raw = String(id.dropFirst("node:".count))
                return projectedByID[raw] ?? projectedByID["node:\(raw)"]
            }
            return projectedByID["node:\(id)"] ?? projectedByID[id.lowercased()]
        }

        var projectedEdges: [ProjectedEdge] = []
        for edge in edgeGraph {
            if recentOnlyLinks, edge.lastSeenMs > 12_000 { continue }
            guard let source = resolveProjected(edge.sourceID), let target = resolveProjected(edge.targetID) else { continue }
            if source.id == target.id { continue }
            if let focusID, focusID != source.id && focusID != target.id { continue }

            let bytesScale = clamp(log10(1 + max(0, edge.bytesPerSec)) / 4.0)
            let strengthBoost = Self.normalizeSignalStrength(edge.signalStrengthDbm)
            let width = CGFloat(1.8 + bytesScale * 4.6 + strengthBoost * 2.2)
            var opacity = edgeOpacity(edge.lastSeenMs, status: edge.status) * Double(activityFade)
            opacity *= 0.72 + 0.5 * strengthBoost
            opacity = min(1.0, opacity)
            if edge.status == .error {
                opacity *= 0.8 + 0.2 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 7.0))
            }
            if topologyClarity && edge.status == .idle {
                opacity *= 0.75
            }

            let metrics = SpectrumEdgeMetrics(
                rps: edge.rps,
                bytesPerSec: edge.bytesPerSec,
                latencyMs: edge.latencyMs,
                lastSeenMs: edge.lastSeenMs,
                lastSeenText: Self.formatLastSeen(ms: edge.lastSeenMs),
                signalStrengthDbm: edge.signalStrengthDbm
            )
            projectedEdges.append(
                ProjectedEdge(
                    id: edge.id,
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    sourceLabel: source.id,
                    targetLabel: target.id,
                    sourcePoint: source.point,
                    targetPoint: target.point,
                    signalType: edge.signalType,
                    transport: edge.transport,
                    status: edge.status,
                    typeColor: edge.signalType.edgeColor,
                    deviceTint: SignalColor.deviceColor(id: edge.sourceID),
                    lineWidth: width,
                    alpha: opacity,
                    metrics: metrics
                )
            )
        }

        projectedEdges.sort { $0.alpha < $1.alpha }
        let cap = max(80, intensity.connectionStrokeCap)
        if projectedEdges.count > cap {
            projectedEdges = Array(projectedEdges.suffix(cap))
        }

        for edge in projectedEdges {
            var path = Path()
            path.move(to: edge.sourcePoint)
            path.addLine(to: edge.targetPoint)
            let strengthBoost = Self.normalizeSignalStrength(edge.metrics.signalStrengthDbm)
            let brightType = SignalColor.mix(edge.typeColor, NSColor.white, ratio: 0.06 + 0.26 * strengthBoost)
            let typeColor = Color(brightType).opacity(edge.alpha)
            let tintColor = Color(edge.deviceTint).opacity(edge.alpha * (0.28 + 0.22 * strengthBoost))
            let width = max(0.8, edge.lineWidth)
            let glowWidth = max(width * (1.7 + CGFloat(strengthBoost) * 0.6), width + 1.4)
            let glowAlpha = min(1.0, edge.alpha * (0.18 + 0.32 * strengthBoost))
            context.stroke(path, with: .color(Color(edge.typeColor).opacity(glowAlpha)), lineWidth: glowWidth)

            switch edge.transport {
            case .http, .unknown, .serial:
                context.stroke(path, with: .color(typeColor), lineWidth: width)
            case .livekit:
                let dx = edge.targetPoint.x - edge.sourcePoint.x
                let dy = edge.targetPoint.y - edge.sourcePoint.y
                let len = max(0.001, sqrt(dx * dx + dy * dy))
                let ux = dx / len
                let uy = dy / len
                let offset: CGFloat = 2.2
                let ax = -uy * offset
                let ay = ux * offset
                var railA = Path()
                railA.move(to: CGPoint(x: edge.sourcePoint.x + ax, y: edge.sourcePoint.y + ay))
                railA.addLine(to: CGPoint(x: edge.targetPoint.x + ax, y: edge.targetPoint.y + ay))
                var railB = Path()
                railB.move(to: CGPoint(x: edge.sourcePoint.x - ax, y: edge.sourcePoint.y - ay))
                railB.addLine(to: CGPoint(x: edge.targetPoint.x - ax, y: edge.targetPoint.y - ay))
                context.stroke(railA, with: .color(typeColor), lineWidth: max(1.0, width * 0.85))
                context.stroke(railB, with: .color(typeColor), lineWidth: max(1.0, width * 0.85))
            case .ssh:
                context.stroke(path, with: .color(typeColor), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [7, 5]))
            case .ble:
                context.stroke(path, with: .color(typeColor), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [1, 5]))
            case .wifiPassive:
                context.stroke(path, with: .color(typeColor.opacity(0.65)), style: StrokeStyle(lineWidth: max(0.8, width * 0.8), lineCap: .round, dash: [1, 7]))
            }
            context.stroke(path, with: .color(tintColor), style: StrokeStyle(lineWidth: max(0.9, width * 0.7), lineCap: .round, dash: [2, 6]))
        }

        return projectedEdges
    }

    private func drawEdgePulses(
        context: inout GraphicsContext,
        now: Date,
        focusID: String?,
        activityFade: CGFloat,
        intensity: SignalIntensity,
        protocolLanes: Bool,
        targetSpotlight: Bool
    ) {
        guard !lastProjectedEdges.isEmpty else { return }
        let nowRef = now.timeIntervalSinceReferenceDate

        for edge in lastProjectedEdges {
            if let focusID, focusID != edge.sourceID && focusID != edge.targetID { continue }
            let dx = edge.targetPoint.x - edge.sourcePoint.x
            let dy = edge.targetPoint.y - edge.sourcePoint.y
            let length = max(0.001, sqrt(dx * dx + dy * dy))
            if length < 8 { continue }
            let ux = dx / length
            let uy = dy / length

            let focusScale: Double = {
                guard let focusID else { return 1.0 }
                if focusID == edge.sourceID || focusID == edge.targetID { return 1.0 }
                return targetSpotlight ? 0.45 : 0.7
            }()
            if edge.status == .idle && edge.metrics.lastSeenMs > 45_000 { continue }

            let normalizedRate = clamp(log10(1.0 + max(0.0, edge.metrics.rps)) / 1.35)
            let strengthBoost = Self.normalizeSignalStrength(edge.metrics.signalStrengthDbm)
            let pulseCount: Int = {
                if edge.status == .error { return 2 }
                if edge.status == .idle { return 1 }
                return 1 + Int(round(normalizedRate * 1.0))
            }()
            let latency = max(10, min(2_000, edge.metrics.latencyMs))
            var speed = 0.16 + (2_000 - latency) / 2_000 * 0.42
            if edge.status == .idle { speed *= 0.58 }
            if edge.status == .error { speed *= 0.9 }

            let laneOffset: CGFloat = {
                guard protocolLanes else { return 0 }
                switch edge.transport {
                case .ble: return -3.0
                case .ssh: return 2.8
                case .livekit: return 3.4
                case .serial: return -2.0
                case .wifiPassive: return 1.5
                default: return 0
                }
            }()
            let laneX = -uy * laneOffset
            let laneY = ux * laneOffset

            for index in 0..<pulseCount {
                let offset = Double(index) / Double(max(1, pulseCount))
                var t = (nowRef * speed + offset).truncatingRemainder(dividingBy: 1.0)
                if t < 0 { t += 1.0 }
                if edge.status == .error {
                    t = min(1.0, max(0.0, t + sin(nowRef * 8 + Double(index)) * 0.015))
                }
                let eased = t * t * (3 - 2 * t)
                let px = edge.sourcePoint.x + dx * CGFloat(eased) + laneX
                let py = edge.sourcePoint.y + dy * CGFloat(eased) + laneY
                let centerWeight = 1.0 - abs(t - 0.5) * 1.6
                let fade = max(0.28, min(1.0, centerWeight))
                let alpha = min(1.0, edge.alpha * Double(activityFade) * fade * focusScale * (0.68 + 1.05 * strengthBoost))
                let size = max(1.8, edge.lineWidth * CGFloat(1.02 + normalizedRate * 0.58 + strengthBoost * 0.58))

                let brightPulse = SignalColor.mix(edge.typeColor, NSColor.white, ratio: 0.12 + 0.36 * strengthBoost)
                let pulseColor = Color(brightPulse).opacity(alpha)
                let glowColor = Color(edge.typeColor).opacity(alpha * (0.34 + 0.5 * strengthBoost))
                let glowRadius = size * (3.6 + CGFloat(strengthBoost) * 1.45)
                context.fill(
                    Path(ellipseIn: CGRect(x: px - glowRadius, y: py - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                    with: .color(glowColor)
                )

                switch edge.transport {
                case .serial:
                    context.fill(
                        Path(CGRect(x: px - size, y: py - size, width: size * 2, height: size * 2)),
                        with: .color(pulseColor)
                    )
                default:
                    context.fill(
                        Path(ellipseIn: CGRect(x: px - size, y: py - size, width: size * 2, height: size * 2)),
                        with: .color(pulseColor)
                    )
                }
                let rimRect = CGRect(x: px - size, y: py - size, width: size * 2, height: size * 2)
                context.stroke(
                    Path(ellipseIn: rimRect),
                    with: .color(Color.white.opacity(alpha * 0.16)),
                    lineWidth: max(0.7, size * 0.28)
                )
            }

            if edge.status == .error {
                let endpointAlpha = edge.alpha * Double(activityFade) * (0.55 + 0.45 * (0.5 + 0.5 * sin(nowRef * 11)))
                context.fill(
                    Path(ellipseIn: CGRect(x: edge.sourcePoint.x - 3, y: edge.sourcePoint.y - 3, width: 6, height: 6)),
                    with: .color(Color(edge.typeColor).opacity(endpointAlpha))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: edge.targetPoint.x - 3, y: edge.targetPoint.y - 3, width: 6, height: 6)),
                    with: .color(Color(edge.typeColor).opacity(endpointAlpha))
                )
            }
        }
    }

    private func refreshEdgeGraphIfNeeded(events: [NormalizedEvent], now: Date) {
        let token = "\(events.count)|\(events.last?.id ?? "")|\(Int(now.timeIntervalSince1970))"
        if token == edgeGraphToken && now.timeIntervalSince(lastEdgeGraphRefresh) < 1.0 {
            return
        }
        edgeGraphToken = token
        lastEdgeGraphRefresh = now
        edgeGraph = buildEdgeGraph(events: events, now: now)
    }

    private func buildEdgeGraph(events: [NormalizedEvent], now: Date) -> [AggregatedEdge] {
        let window: TimeInterval = 12.0
        let cutoff = now.addingTimeInterval(-window)
        struct Bucket {
            var count: Int = 0
            var bytes: Double = 0
            var latencyTotal: Double = 0
            var latencyCount: Int = 0
            var strengthTotal: Double = 0
            var strengthCount: Int = 0
            var lastSeen: Date = .distantPast
            var sawError = false
            var signalType: SpectrumSignalType
            var transport: SpectrumTransport
            var sourceID: String
            var targetID: String
        }
        var buckets: [String: Bucket] = [:]

        for event in events.suffix(1_600) {
            let eventTime = event.eventTs ?? event.recvTs ?? now
            guard eventTime >= cutoff else { continue }
            guard let sample = Self.classifyEdgeSample(from: event, now: now) else { continue }
            let key = "\(sample.sourceID)|\(sample.targetID)|\(sample.signalType.rawValue)|\(sample.transport.rawValue)"
            var bucket = buckets[key] ?? Bucket(
                signalType: sample.signalType,
                transport: sample.transport,
                sourceID: sample.sourceID,
                targetID: sample.targetID
            )
            bucket.count += 1
            bucket.bytes += sample.bytes
            if sample.latencyMs > 0 {
                bucket.latencyTotal += sample.latencyMs
                bucket.latencyCount += 1
            }
            if let strength = sample.signalStrengthDbm {
                bucket.strengthTotal += strength
                bucket.strengthCount += 1
            }
            if eventTime > bucket.lastSeen { bucket.lastSeen = eventTime }
            if sample.status == .error || event.severity.lowercased() == "error" {
                bucket.sawError = true
            }
            buckets[key] = bucket
        }

        var edges: [AggregatedEdge] = []
        edges.reserveCapacity(buckets.count)
        for (key, bucket) in buckets {
            let ageMs = max(0, now.timeIntervalSince(bucket.lastSeen) * 1_000)
            let rps = Double(bucket.count) / window
            let latency = bucket.latencyCount > 0 ? (bucket.latencyTotal / Double(bucket.latencyCount)) : Self.defaultLatency(for: bucket.transport)
            let bytesPerSec = bucket.bytes / window
            let avgStrength = bucket.strengthCount > 0 ? (bucket.strengthTotal / Double(bucket.strengthCount)) : nil
            let status: SpectrumEdgeStatus = bucket.sawError ? .error : (ageMs < 4_000 && rps > 0.05 ? .active : .idle)
            edges.append(
                AggregatedEdge(
                    id: key,
                    sourceID: bucket.sourceID,
                    targetID: bucket.targetID,
                    signalType: bucket.signalType,
                    transport: bucket.transport,
                    status: status,
                    rps: rps,
                    bytesPerSec: bytesPerSec,
                    latencyMs: latency,
                    lastSeenMs: ageMs,
                    lastSeenText: Self.formatLastSeen(ms: ageMs),
                    signalStrengthDbm: avgStrength
                )
            )
        }
        edges.sort { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status.rawValue < rhs.status.rawValue
            }
            return lhs.rps > rhs.rps
        }
        return edges
    }

    private func ensureEdgeEndpoint(_ id: String, event: NormalizedEvent, now: Date) {
        guard !id.isEmpty else { return }
        if let source = sources[id] {
            source.lastSeen = event.eventTs ?? event.recvTs ?? now
            if source.lastKind == nil {
                source.lastKind = event.kind
            }
            return
        }
        let created = SignalSource(id: id)
        created.lastSeen = event.eventTs ?? event.recvTs ?? now
        created.lastKind = event.kind
        created.lastNodeID = event.nodeID
        sources[id] = created
    }

    private static func defaultLatency(for transport: SpectrumTransport) -> Double {
        switch transport {
        case .livekit: return 90
        case .ssh: return 180
        case .ble: return 120
        case .serial: return 20
        case .wifiPassive: return 350
        case .http, .unknown: return 160
        }
    }

    private static func endpointID(from event: NormalizedEvent, keys: [String], preferNode: Bool) -> String? {
        for key in keys {
            if let value = event.data[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return normalizeEndpointID(value, kind: event.kind, preferNode: preferNode)
            }
        }
        if preferNode, event.nodeID != "unknown" && !event.nodeID.isEmpty {
            return "node:\(event.nodeID)"
        }
        if !preferNode, let deviceID = event.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty {
            return normalizeEndpointID(deviceID, kind: event.kind, preferNode: false)
        }
        return nil
    }

    private static func normalizeEndpointID(_ value: String, kind: String, preferNode: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("node:") || trimmed.hasPrefix("ble:") || trimmed.hasPrefix("service:") {
            return trimmed
        }
        let lower = trimmed.lowercased()
        if lower == "vault" || lower == "vault-ingest" {
            return "service:vault"
        }
        if lower == "god-gateway" || lower == "gateway" {
            return "service:god-gateway"
        }
        if kind.lowercased().contains("ble"), lower.contains(":") {
            return "ble:\(lower)"
        }
        if preferNode && !lower.contains(".") && !lower.contains(":") {
            return "node:\(trimmed)"
        }
        return trimmed
    }

    static func extractLatencyMs(from data: [String: JSONValue]) -> Double? {
        let keys = ["latency_ms", "latencyMs", "duration_ms", "durationMs", "latency", "round_trip_ms"]
        for key in keys {
            if let number = data[key]?.doubleValue {
                return number
            }
        }
        return nil
    }

    static func estimateEventBytes(_ event: NormalizedEvent) -> Double {
        var bytes = Double(event.kind.utf8.count + event.summary.utf8.count)
        for (key, value) in event.data {
            bytes += Double(key.utf8.count + (value.stringValue?.utf8.count ?? 12))
        }
        return max(32, bytes)
    }

    static func classifyEdgeSample(from event: NormalizedEvent, now: Date) -> SpectrumEdgeSample? {
        let kind = event.kind.lowercased()
        let eventTime = event.eventTs ?? event.recvTs ?? now

        let signalType: SpectrumSignalType
        if kind.hasPrefix("control.god_button") || kind.contains("god_button") || kind.hasPrefix("control.") {
            signalType = .control
        } else if kind.hasPrefix("agent.exec") || kind.hasPrefix("agent.ssh") || kind.contains("maintenance") || kind.contains("ops.") {
            signalType = .mgmt
        } else if kind.hasPrefix("node.health") || kind.contains("ble.") || kind.contains("wifi") {
            signalType = .event
        } else if kind.contains("vault") || kind.contains("ingest") || kind.contains("evidence") {
            signalType = .evidence
        } else if kind.contains("media") || kind.contains("audio") || kind.contains("video") || kind.contains("rtsp") {
            signalType = .media
        } else {
            signalType = .event
        }

        let transport: SpectrumTransport = {
            if kind.contains("ssh") { return .ssh }
            if kind.contains("livekit") || kind.contains("god_button") || kind.contains("god.") { return .livekit }
            if kind.contains("ble") { return .ble }
            if kind.contains("serial") || kind.contains("usb") || kind.contains("tty") { return .serial }
            if kind.contains("wifi.snapshot") || kind.contains("wifi.passive") { return .wifiPassive }
            return .http
        }()

        let sourceID = endpointID(
            from: event,
            keys: ["src", "source", "from", "scanner_id", "origin", "node_id"],
            preferNode: true
        )
        var targetID = endpointID(
            from: event,
            keys: ["target", "target_id", "targetNode", "to", "dst", "destination", "node_id", "device_id"],
            preferNode: false
        )
        if signalType == .evidence {
            targetID = "service:vault"
        }
        guard let src = sourceID, let dst = targetID, !src.isEmpty, !dst.isEmpty, src != dst else { return nil }
        let latency = extractLatencyMs(from: event.data) ?? defaultLatency(for: transport)
        let bytes = estimateEventBytes(event)
        let status: SpectrumEdgeStatus = (event.severity.lowercased() == "error" || kind.contains("error")) ? .error : .active
        return SpectrumEdgeSample(
            sourceID: src,
            targetID: dst,
            signalType: signalType,
            transport: transport,
            status: status,
            eventTime: eventTime,
            latencyMs: latency,
            bytes: bytes,
            signalStrengthDbm: event.signal.strength
        )
    }

    private static func normalizeSignalStrength(_ value: Double?) -> Double {
        guard let value else { return 0.45 }
        let clamped = max(-95.0, min(-35.0, value))
        return (clamped + 95.0) / 60.0
    }

    private func edgeOpacity(_ ageMs: Double, status: SpectrumEdgeStatus) -> Double {
        let recency = exp(-ageMs / 12_000.0)
        let base = max(0.08, min(1.0, 0.16 + recency * 0.9))
        switch status {
        case .active: return base
        case .idle: return base * 0.55
        case .error: return max(0.25, base * 0.95)
        }
    }

    private static func formatLastSeen(ms: Double) -> String {
        if ms < 1_000 { return "now" }
        if ms < 60_000 { return String(format: "%.0fs ago", ms / 1_000) }
        return String(format: "%.1fm ago", ms / 60_000)
    }

    private func isCommandLike(kind: String) -> Bool {
        let lowered = kind.lowercased()
        return lowered.contains("tool")
            || lowered.contains("action")
            || lowered.contains("command")
            || lowered.contains("runbook")
            || lowered.contains("god")
            || lowered.contains("control")
    }

    private func edgeLaneKey(for event: NormalizedEvent) -> String {
        let kind = event.kind.lowercased()
        if kind.contains("ble") { return "ble" }
        if kind.contains("wifi") {
            if let ch = Int(event.signal.channel ?? "") {
                return ch >= 30 ? "wifi-5g" : "wifi-2g"
            }
            return "wifi"
        }
        if kind.contains("tool") || kind.contains("action") || kind.contains("command") || kind.contains("god") || kind.contains("control") {
            return "cmd"
        }
        if kind.contains("error") { return "error" }
        return "signal"
    }

    private func edgeLaneKey(for frame: SignalFrame) -> String {
        if frame.source == "ble" { return "ble" }
        if frame.source == "wifi" {
            return frame.channel >= 30 ? "wifi-5g" : "wifi-2g"
        }
        return frame.source
    }

    private func groupFor(id: String) -> String {
        String(id.split(separator: ":").first ?? Substring(id))
    }

    private func updateGhosts(now: Date, nodePresentations: [String: NodePresentation], intensity: SignalIntensity) {
        if now.timeIntervalSince(ghostLastFlush) > intensity.ghostFlushInterval {
            ghostLastFlush = now
            for source in sources.values {
                let kind = source.lastKind ?? source.group
                let renderKind = SignalRenderKind.from(source: kind)
                let typedColor = SignalColor.typeFirstColor(
                    renderKind: renderKind,
                    deviceID: source.id,
                    channel: source.lastChannel
                )
                let color: NSColor
                if let presentationColor = nodePresentations[source.id]?.displayColor {
                    color = SignalColor.mix(typedColor, presentationColor, ratio: 0.28)
                } else {
                    color = typedColor
                }
                ghostAccumulator.append(GhostPoint(sourceID: source.id, position: source.position, color: color, ts: now))
            }
            if ghostAccumulator.count > intensity.ghostCap {
                ghostAccumulator.removeFirst(ghostAccumulator.count - intensity.ghostCap)
            }
        }
    }

    private func drawGhosts(context: inout GraphicsContext, size: CGSize, parallax: CGPoint, focusID: String?, activityFade: CGFloat) {
        guard !ghostAccumulator.isEmpty else { return }
        let now = Date()
        for ghost in ghostAccumulator {
            if let focusID, focusID != ghost.sourceID { continue }
            let ageSeconds = max(0.0, now.timeIntervalSince(ghost.ts))
            let alpha = max(0.02, 0.18 * exp(-ageSeconds / 4.5))
            let depth = depthScalar(id: ghost.sourceID, z: ghost.position.z, now: now)
            let depthScale = depthFade(for: depth)
            let basePoint = CGPoint(
                x: CGFloat(ghost.position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
                y: CGFloat(ghost.position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
            )
            let radius = CGFloat(1.0 + alpha * 10.0) * depth
            context.fill(Path(ellipseIn: CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Color(ghost.color).opacity(alpha * Double(activityFade) * Double(depthScale))))
        }
    }

    private func drawPulses(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, focusID: String?, activityFade: CGFloat, targetSpotlight: Bool) {
        for pulse in pulses {
            let focusScale: CGFloat = (focusID == nil || focusID == pulse.sourceID) ? 1.0 : (targetSpotlight ? 0.08 : 0.2)
            let age = now.timeIntervalSince(pulse.birth)
            let progress = min(1.0, age / max(0.01, pulse.lifespan))
            let alpha = (1.0 - progress) * pulse.strength
            let depth = depthScalar(id: pulse.sourceID, z: pulse.position.z, now: now)
            let center = CGPoint(
                x: CGFloat(pulse.position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
                y: CGFloat(pulse.position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
            )
            let radius = CGFloat(18 + progress * 140) * depth
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let accentColor: NSColor = {
                switch pulse.renderKind {
                case .node:
                    return SignalColor.mix(pulse.color, NSColor.systemRed, ratio: 0.55)
                case .error:
                    return SignalColor.mix(pulse.color, NSColor.systemRed, ratio: 0.75)
                default:
                    return pulse.color
                }
            }()
            let strokeAlpha = alpha * Double(activityFade) * Double(focusScale) * Double(depthFade(for: depth))
            let color = Color(accentColor).opacity(strokeAlpha)
            let lineWidth = CGFloat(1.2 + pulse.strength * 2) * depth

            switch pulse.renderKind {
            case .ble:
                let dots = 10
                for i in 0..<dots {
                    let angle = Double(i) / Double(dots) * Double.pi * 2
                    let dx = cos(angle) * Double(radius)
                    let dy = sin(angle) * Double(radius)
                    let dotRadius = max(1.8, 3.6 * depth)
                    let dotRect = CGRect(
                        x: center.x + CGFloat(dx) - dotRadius,
                        y: center.y + CGFloat(dy) - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    let haloRadius = dotRadius * 1.9
                    let haloRect = CGRect(
                        x: center.x + CGFloat(dx) - haloRadius,
                        y: center.y + CGFloat(dy) - haloRadius,
                        width: haloRadius * 2,
                        height: haloRadius * 2
                    )
                    context.fill(Path(ellipseIn: haloRect), with: .color(color.opacity(0.22)))
                    context.fill(Path(ellipseIn: dotRect), with: .color(color.opacity(0.8)))
                    context.stroke(Path(ellipseIn: dotRect), with: .color(Color.white.opacity(strokeAlpha * 0.26)), lineWidth: max(0.8, dotRadius * 0.32))
                }
            case .wifi:
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.85)), lineWidth: lineWidth)
            case .node:
                context.stroke(diamondPath(in: rect), with: .color(color.opacity(0.85)), lineWidth: lineWidth)
            case .error:
                var path = Path()
                let points = 10
                for i in 0..<points {
                    let angle = Double(i) / Double(points) * Double.pi * 2
                    let spike = (i % 2 == 0) ? 1.0 : 0.6
                    let r = Double(radius) * spike
                    let x = center.x + CGFloat(cos(angle) * r)
                    let y = center.y + CGFloat(sin(angle) * r)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
            default:
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)
            }
        }
    }

    private var ghostAccumulator: [GhostPoint] = []
    private var ghostLastFlush: Date = .distantPast

    private func seedPulse(id: String, source: SignalSource, event: NormalizedEvent, now: Date, intensity: SignalIntensity) {
        let renderKind = SignalRenderKind.from(event: event)
        let color = SignalColor.typeFirstColor(
            renderKind: renderKind,
            deviceID: id,
            channel: event.signal.channel
        )
        seedPulse(id: id, color: color, strength: event.signal.strength == nil ? 0.5 : 0.8, source: source, now: now, renderKind: renderKind, intensity: intensity)
    }

    private func seedPulse(id: String, color: NSColor, strength: Double, source: SignalSource, now: Date, renderKind: SignalRenderKind, intensity: SignalIntensity) {
        if let last = lastPulseBySource[id], now.timeIntervalSince(last) < intensity.pulseMinInterval { return }
        lastPulseBySource[id] = now
        pulses.append(FieldPulse(id: UUID(), sourceID: id, position: source.position, color: color, renderKind: renderKind, birth: now, lifespan: 1.3, strength: strength))
        if pulses.count > intensity.pulseCap {
            pulses.removeFirst(pulses.count - intensity.pulseCap)
        }
    }

    private func seedEdgePulse(throttleKey: String, fromID: String, toID: String, strength: Double, color: NSColor, renderKind: SignalRenderKind, now: Date, intensity: SignalIntensity) {
        if let last = lastEdgePulseBySource[throttleKey], now.timeIntervalSince(last) < intensity.edgePulseMinInterval { return }
        lastEdgePulseBySource[throttleKey] = now
        // Keep these short and snappy: "activity is flowing along this link".
        edgePulses.append(
            EdgePulse(
                id: UUID(),
                throttleKey: throttleKey,
                fromID: fromID,
                toID: toID,
                birth: now,
                lifespan: 0.9,
                strength: strength,
                color: color,
                renderKind: renderKind
            )
        )
        if edgePulses.count > intensity.edgePulseCap {
            edgePulses.removeFirst(edgePulses.count - intensity.edgePulseCap)
        }
    }

    func nearestNode(to point: CGPoint) -> ProjectedNode? {
        guard !lastProjected.isEmpty else { return nil }
        var best: ProjectedNode?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for node in lastProjected {
            let dx = node.point.x - point.x
            let dy = node.point.y - point.y
            let dist = dx * dx + dy * dy
            if dist < bestDist {
                bestDist = dist
                best = node
            }
        }
        return bestDist < 2400 ? best : nil
    }

    func nearestEdge(to point: CGPoint) -> ProjectedEdge? {
        guard !lastProjectedEdges.isEmpty else { return nil }
        var best: ProjectedEdge?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for edge in lastProjectedEdges {
            let dist = distanceToSegment(point: point, start: edge.sourcePoint, end: edge.targetPoint)
            if dist < bestDistance {
                bestDistance = dist
                best = edge
            }
        }
        return bestDistance <= 12 ? best : nil
    }

    private func distanceToSegment(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let vx = end.x - start.x
        let vy = end.y - start.y
        let wx = point.x - start.x
        let wy = point.y - start.y
        let c1 = vx * wx + vy * wy
        if c1 <= 0 {
            let dx = point.x - start.x
            let dy = point.y - start.y
            return sqrt(dx * dx + dy * dy)
        }
        let c2 = vx * vx + vy * vy
        if c2 <= c1 {
            let dx = point.x - end.x
            let dy = point.y - end.y
            return sqrt(dx * dx + dy * dy)
        }
        let b = c1 / c2
        let px = start.x + b * vx
        let py = start.y + b * vy
        let dx = point.x - px
        let dy = point.y - py
        return sqrt(dx * dx + dy * dy)
    }
}

final class SignalSource: Hashable {
    let id: String
    let group: String
    var position: SIMD3<Double>
    var velocity: SIMD3<Double> = .zero
    var target: SIMD3<Double>
    let color: NSColor
    var lastSeen: Date?
    var lastStrength: Double?
    var lastKind: String?
    var lastChannel: String?
    var lastNodeID: String?
    private let targetSmoothing: Double = 0.18

    init(id: String) {
        self.id = id
        self.group = String(id.split(separator: ":").first ?? Substring(id))
        let seed = UInt64(id.utf8.reduce(0) { ($0 &* 131) &+ UInt64($1) })
        var rng = SeededRandom(seed: seed)
        let angle = rng.next() * Double.pi * 2
        let radius = 0.25 + 0.55 * sqrt(rng.next())
        let x = cos(angle) * radius
        let y = sin(angle) * radius
        let z = 0.25 + rng.next() * 0.6
        position = SIMD3<Double>(x, y, z)
        target = position
        color = SignalColor.deviceColor(id: id)
    }

    func update(from frame: SignalFrame) {
        let nx = frame.x ?? 0.5
        let ny = frame.y ?? 0.5
        let strength = frame.rssi
        let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
        let idOffset = stableDepthOffset(for: id)
        let baseZ = frame.z ?? 0.6
        let z = clamp(0.25 + strengthNorm * 0.55 + idOffset + (baseZ - 0.5) * 0.3, min: 0.1, max: 1.0)
        applyTarget(SIMD3<Double>((nx - 0.5) * 2.0 * 0.6, (ny - 0.5) * 2.0 * 0.6, z))
        lastSeen = Date()
        lastStrength = strength
        lastKind = frame.source
        lastChannel = "\(frame.channel)"
        lastNodeID = frame.nodeID
    }

    func update(from event: NormalizedEvent) {
        let baseHue = Double(SignalColor.stableHue(for: event.deviceID ?? event.nodeID))
        let kindOffset = event.kind.contains("wifi") ? 0.08 : event.kind.contains("ble") ? -0.06 : 0.0
        let channel = Double(event.signal.channel ?? "") ?? baseHue * 180
        let angle = (channel.truncatingRemainder(dividingBy: 180) / 180.0) * Double.pi * 2 + kindOffset
        let radius = event.kind.contains("ble") ? 0.32 : event.kind.contains("wifi") ? 0.52 : 0.7
        let x = cos(angle) * radius
        let y = sin(angle) * radius
        let strength = event.signal.strength ?? -60
        let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
        let idOffset = stableDepthOffset(for: id)
        let z = clamp(0.25 + strengthNorm * 0.55 + idOffset, min: 0.1, max: 1.0)
        applyTarget(SIMD3<Double>(x, y, z))
        lastSeen = event.eventTs ?? event.recvTs ?? Date()
        lastStrength = event.signal.strength
        lastKind = event.kind
        lastChannel = event.signal.channel
        if !event.nodeID.isEmpty, event.nodeID != "unknown" {
            lastNodeID = event.nodeID
        }
    }

    func step(dt: Double, isActive: Bool) {
        let damping: Double = isActive ? 0.9 : 0.95
        if isActive {
            let swirl = SIMD3<Double>(-position.y, position.x, 0) * 0.04
            let spring = SIMD3<Double>(repeating: 1.08)
            let delta = target - position
            velocity += (delta * spring + swirl) * dt
        } else {
            let delta = target - position
            velocity += delta * dt * 0.2
        }
        velocity *= SIMD3<Double>(repeating: damping)
        position += velocity * dt
        position.z = max(0.1, min(1.0, position.z))
    }

    var depth: CGFloat {
        CGFloat(0.5 + position.z * 0.9)
    }

    func project(in size: CGSize, parallax: CGPoint) -> CGPoint {
        let px = CGFloat(position.x) * size.width * 0.45 + size.width * 0.5
        let py = CGFloat(position.y) * size.height * 0.45 + size.height * 0.5
        return CGPoint(x: px + parallax.x * depth, y: py + parallax.y * depth)
    }

    private func applyTarget(_ next: SIMD3<Double>) {
        target = target + (next - target) * targetSmoothing
    }

    static func == (lhs: SignalSource, rhs: SignalSource) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct SignalParticle: Hashable {
    let id: UUID
    var kind: ParticleKind
    var sourceID: String
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var birth: Date
    var lifespan: TimeInterval
    var baseSize: Double
    var color: NSColor
    var strength: Double
    var glow: Double
    var ringRadius: Double
    var ringWidth: Double
    var trail: [SIMD3<Double>]
    var renderKind: SignalRenderKind

    mutating func update(dt: Double, decay: Double) {
        switch kind {
        case .spark:
            position += velocity * dt
            pushTrail()
        case .ring, .pulse:
            ringRadius += dt * 120 * decay
        case .burst:
            position += velocity * dt * 0.6
            ringRadius += dt * 140 * decay
            pushTrail()
        }
    }

    private mutating func pushTrail() {
        trail.append(position)
        if trail.count > 10 {
            trail.removeFirst(trail.count - 10)
        }
    }

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(birth) > lifespan
    }

    func draw(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, dimmed: Bool, activityFade: CGFloat, dimFactor: CGFloat) {
        let age = now.timeIntervalSince(birth)
        let progress = min(1.0, age / max(0.01, lifespan))
        let alpha = 1.0 - progress
        let depth = depthScalar(id: sourceID, z: position.z, now: now)
        let basePoint = CGPoint(
            x: CGFloat(position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
            y: CGFloat(position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
        )
        let glowStrength = max(0.0, min(1.0, glow))
        let accentColor: NSColor = {
            switch renderKind {
            case .node:
                return SignalColor.mix(color, NSColor.systemRed, ratio: 0.55)
            case .error:
                return SignalColor.mix(color, NSColor.systemRed, ratio: 0.75)
            default:
                return color
            }
        }()
        let depthFadeValue = depthFade(for: depth)
        let dimmedAlphaBase = dimmed ? 0.25 * dimFactor : 0.9
        let alphaScale = CGFloat(alpha) * dimmedAlphaBase * activityFade * depthFadeValue
        let drawColor = Color(accentColor).opacity(Double(alphaScale))

        switch kind {
        case .spark:
            let radius = max(1.4, CGFloat(baseSize) * depth * 0.12)
            let rect = CGRect(x: basePoint.x - radius / 2, y: basePoint.y - radius / 2, width: radius, height: radius)
            if glowStrength > 0.05 {
                let glowRadius = radius * (1.6 + CGFloat(glowStrength) * 2.4)
                let glowRect = CGRect(x: basePoint.x - glowRadius / 2, y: basePoint.y - glowRadius / 2, width: glowRadius, height: glowRadius)
                context.fill(Path(ellipseIn: glowRect), with: .color(drawColor.opacity((dimmed ? 0.06 * dimFactor : 0.18) + CGFloat(glowStrength) * 0.35)))
            }
            if renderKind == .node {
                context.fill(diamondPath(in: rect), with: .color(drawColor))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(drawColor))
            }
            drawTrail(context: &context, size: size, parallax: parallax, alpha: alpha, dimmed: dimmed, activityFade: activityFade)
        case .ring:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            let lineWidth = CGFloat(ringWidth) * depth
            switch renderKind {
            case .ble:
                let dots = 8
                for i in 0..<dots {
                    let angle = Double(i) / Double(dots) * Double.pi * 2
                    let dx = cos(angle) * Double(radius)
                    let dy = sin(angle) * Double(radius)
                    let dotRadius = max(1.6, 3.2 * depth)
                    let dotRect = CGRect(
                        x: basePoint.x + CGFloat(dx) - dotRadius,
                        y: basePoint.y + CGFloat(dy) - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    let haloRadius = dotRadius * 1.8
                    let haloRect = CGRect(
                        x: basePoint.x + CGFloat(dx) - haloRadius,
                        y: basePoint.y + CGFloat(dy) - haloRadius,
                        width: haloRadius * 2,
                        height: haloRadius * 2
                    )
                    context.fill(Path(ellipseIn: haloRect), with: .color(drawColor.opacity(0.2)))
                    context.fill(Path(ellipseIn: dotRect), with: .color(drawColor.opacity(0.8)))
                    context.stroke(Path(ellipseIn: dotRect), with: .color(Color.white.opacity(Double(alphaScale) * 0.24)), lineWidth: max(0.7, dotRadius * 0.26))
                }
            case .wifi:
                context.stroke(Path(ellipseIn: rect), with: .color(drawColor.opacity(0.7 + CGFloat(glowStrength) * 0.2)), lineWidth: lineWidth)
            default:
                context.stroke(Path(ellipseIn: rect), with: .color(drawColor.opacity(0.6 + CGFloat(glowStrength) * 0.2)), lineWidth: lineWidth)
            }
        case .pulse:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            let strokeColor = drawColor.opacity(0.8 + CGFloat(glowStrength) * 0.15)
            if renderKind == .node {
                context.stroke(diamondPath(in: rect), with: .color(strokeColor), lineWidth: CGFloat(ringWidth) * depth)
            } else {
                context.stroke(Path(ellipseIn: rect), with: .color(strokeColor), lineWidth: CGFloat(ringWidth) * depth)
            }
        case .burst:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            if renderKind == .error {
                var path = Path()
                let spikes = 8
                for i in 0..<spikes {
                    let angle = Double(i) / Double(spikes) * Double.pi * 2
                    let spike = (i % 2 == 0) ? 1.0 : 0.6
                    let r = Double(radius) * spike
                    let x = basePoint.x + CGFloat(cos(angle) * r)
                    let y = basePoint.y + CGFloat(sin(angle) * r)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(drawColor.opacity(0.85 + CGFloat(glowStrength) * 0.2)), lineWidth: CGFloat(ringWidth) * depth)
            } else {
                context.stroke(Path(ellipseIn: rect), with: .color(drawColor.opacity(0.8 + CGFloat(glowStrength) * 0.2)), lineWidth: CGFloat(ringWidth) * depth)
            }
            drawTrail(context: &context, size: size, parallax: parallax, alpha: alpha, dimmed: dimmed, activityFade: activityFade)
        }
    }

    private func drawTrail(context: inout GraphicsContext, size: CGSize, parallax: CGPoint, alpha: Double, dimmed: Bool, activityFade: CGFloat) {
        guard trail.count > 1 else { return }
        let depth = depthScalar(id: sourceID, z: position.z, now: Date())
        var path = Path()
        for (index, point) in trail.enumerated() {
            let px = CGFloat(point.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth
            let py = CGFloat(point.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
            let p = CGPoint(x: px, y: py)
            if index == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        let baseAlpha = dimmed ? 0.18 : 0.45
        let lineWidth = max(0.6, 1.2 * depth * CGFloat(alpha))
        let depthScale = depthFade(for: depth)
        context.stroke(path, with: .color(Color(color).opacity(alpha * baseAlpha * Double(activityFade) * Double(depthScale))), lineWidth: lineWidth)
    }
}

enum ParticleKind {
    case spark
    case ring
    case pulse
    case burst
}

enum SignalRenderKind: String {
    case ble
    case wifi
    case node
    case tool
    case error
    case generic

    static func from(event: NormalizedEvent) -> SignalRenderKind {
        let kind = event.kind.lowercased()
        if kind.contains("ble") { return .ble }
        if kind.contains("wifi") || kind.contains("net") || kind.contains("host") { return .wifi }
        if kind.contains("node") { return .node }
        if kind.contains("tool") || kind.contains("action") || kind.contains("command") || kind.contains("runbook") || kind.contains("cmd") || event.signal.tags.contains("tool") {
            return .tool
        }
        if kind.contains("error") || event.signal.tags.contains("error") { return .error }
        return .generic
    }

    static func from(source: String) -> SignalRenderKind {
        let source = source.lowercased()
        if source.contains("ble") { return .ble }
        if source.contains("wifi") || source.contains("net") || source.contains("host") { return .wifi }
        if source.contains("node") { return .node }
        if source.contains("tool") || source.contains("action") || source.contains("command") { return .tool }
        if source.contains("error") { return .error }
        return .generic
    }

    var label: String {
        switch self {
        case .ble: return "BLE"
        case .wifi: return "Wi-Fi"
        case .node: return "Node"
        case .tool: return "Action"
        case .error: return "Error"
        case .generic: return "Signal"
        }
    }
}

enum SignalIntensity: String, CaseIterable, Identifiable {
    case calm
    case storm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm: return "Calm"
        case .storm: return "Storm"
        }
    }

    var multiplier: Double {
        switch self {
        case .calm: return 0.48
        case .storm: return 0.7
        }
    }

    // Performance/clarity budgets. These intentionally make Calm *much* calmer.
    var particleCap: Int {
        switch self {
        case .calm: return 220
        case .storm: return 320
        }
    }

    var eventTailLimit: Int {
        switch self {
        case .calm: return 420
        case .storm: return 600
        }
    }

    var frameBinLimit: Int {
        switch self {
        case .calm: return 42
        case .storm: return 56
        }
    }

    var pulseMinInterval: TimeInterval {
        switch self {
        case .calm: return 0.48
        case .storm: return 0.36
        }
    }

    var pulseCap: Int {
        switch self {
        case .calm: return 18
        case .storm: return 28
        }
    }

    var ghostFlushInterval: TimeInterval {
        switch self {
        case .calm: return 0.26
        case .storm: return 0.22
        }
    }

    var ghostCap: Int {
        switch self {
        case .calm: return 80
        case .storm: return 100
        }
    }

    var focusConnectionCap: Int {
        switch self {
        case .calm: return 10
        case .storm: return 14
        }
    }

    var connectionNodeHardCap: Int {
        switch self {
        case .calm: return 64
        case .storm: return 82
        }
    }

    var connectionStrokeCap: Int {
        switch self {
        case .calm: return 120
        case .storm: return 170
        }
    }

    var edgePulseMinInterval: TimeInterval {
        switch self {
        case .calm: return 0.45
        case .storm: return 0.34
        }
    }

    var edgePulseCap: Int {
        switch self {
        case .calm: return 24
        case .storm: return 34
        }
    }
}

enum SignalKindLegend: CaseIterable, Identifiable {
    case ble
    case wifi
    case node
    case error

    var id: String { label }

    var label: String {
        switch self {
        case .ble: return "BLE seen"
        case .wifi: return "Wi-Fi status"
        case .node: return "Node heartbeat"
        case .error: return "Errors"
        }
    }

    var color: NSColor {
        switch self {
        case .ble: return SignalColor.kindAccent(kind: "ble.seen")
        case .wifi: return SignalColor.kindAccent(kind: "wifi.status")
        case .node: return SignalColor.kindAccent(kind: "node.heartbeat")
        case .error: return SignalColor.kindAccent(kind: "error")
        }
    }
}

enum SignalEmitter {
    static func isBLEBroadcasting(event: NormalizedEvent) -> Bool {
        // Heuristic: a "real" BLE seen/broadcast signal should carry strength (RSSI/dbm/etc).
        if event.signal.strength != nil { return true }
        // Some payloads may use different keys; fall back to checking the raw event data.
        if event.data["rssi"]?.doubleValue != nil { return true }
        if event.data["RSSI"]?.doubleValue != nil { return true }
        if let level = event.data["level"]?.doubleValue, level != 0 { return true }
        return false
    }

    static func emit(from source: SignalSource, event: NormalizedEvent, intensity: SignalIntensity, now: Date) -> [SignalParticle] {
        let kind = event.kind.lowercased()
        let strength = event.signal.strength ?? -60
        let energy = max(0.2, min(1.8, (abs(strength) / 90.0)))
        let style = SignalVisualStyle.from(event: event, now: now)
        let deviceID = event.deviceID ?? event.nodeID
        let renderKind = SignalRenderKind.from(event: event)
        let baseColor = SignalColor.typeFirstColor(
            renderKind: renderKind,
            deviceID: deviceID,
            channel: event.signal.channel,
            deviceBlend: 0.22,
            saturation: style.saturation,
            brightness: style.brightness
        )
        // Particle density is a primary driver of perf *and* visual readability.
        // Keep it bounded; rely on glow/size for "strength" instead of sheer count.
        let count = min(9, Int(ceil(4.8 * intensity.multiplier * energy)))
        var particles: [SignalParticle] = []

        let isWifi = kind.contains("wifi") || kind.contains("net") || kind.contains("host")
        if kind.contains("ble") {
            if !isBLEBroadcasting(event: event) {
                // Still update the source position + core dot, but skip effect particles.
                return []
            }
            particles.append(makeRing(source: source, color: baseColor, now: now, pulse: false, glow: style.glow, renderKind: renderKind))
            for _ in 0..<max(2, count / 2) {
                particles.append(makeSpark(source: source, color: baseColor, now: now, energy: energy, glow: style.glow, renderKind: renderKind))
            }
        } else if isWifi {
            particles.append(makeRing(source: source, color: baseColor, now: now, pulse: false, glow: style.glow, renderKind: renderKind))
            particles.append(makeSpark(source: source, color: baseColor, now: now, energy: max(0.3, energy * 0.6), glow: style.glow, renderKind: renderKind))
        } else if kind.contains("node") {
            particles.append(makeRing(source: source, color: baseColor, now: now, pulse: true, glow: style.glow, renderKind: renderKind, lifespan: 2.6))
            particles.append(makeSpark(source: source, color: baseColor, now: now, energy: max(0.25, energy * 0.5), glow: style.glow, renderKind: renderKind))
        } else if kind.contains("tool") {
            particles.append(makeBurst(source: source, color: baseColor, now: now, energy: energy, glow: min(1.0, style.glow + 0.25), renderKind: renderKind))
        } else if kind.contains("error") || event.signal.tags.contains("error") {
            for _ in 0..<(max(2, count / 2)) {
                particles.append(makeBurst(source: source, color: baseColor, now: now, energy: energy, glow: min(1.0, style.glow + 0.2), renderKind: renderKind))
            }
        } else {
            particles.append(makeSpark(source: source, color: baseColor, now: now, energy: energy, glow: style.glow, renderKind: renderKind))
        }

        return particles
    }

    private static func makeSpark(source: SignalSource, color: NSColor, now: Date, energy: Double, glow: Double, renderKind: SignalRenderKind) -> SignalParticle {
        let jitter = SignalEmitter.randomVector(scale: 0.02)
        let velocity = SignalEmitter.randomVector(scale: 0.16 * energy)
        return SignalParticle(
            id: UUID(),
            kind: .spark,
            sourceID: source.id,
            position: source.position + jitter,
            velocity: velocity,
            birth: now,
            lifespan: 1.2 + energy * 0.6,
            baseSize: 12 * energy,
            color: color,
            strength: energy,
            glow: glow,
            ringRadius: 0,
            ringWidth: 1.6,
            trail: [],
            renderKind: renderKind
        )
    }

    private static func makeRing(source: SignalSource, color: NSColor, now: Date, pulse: Bool, glow: Double, renderKind: SignalRenderKind, lifespan: TimeInterval? = nil) -> SignalParticle {
        let life = lifespan ?? (pulse ? 1.8 : 2.6)
        return SignalParticle(
            id: UUID(),
            kind: pulse ? .pulse : .ring,
            sourceID: source.id,
            position: source.position,
            velocity: SIMD3<Double>(0, 0, 0),
            birth: now,
            lifespan: life,
            baseSize: 10,
            color: color,
            strength: 1.0,
            glow: glow,
            ringRadius: 10,
            ringWidth: pulse ? 2.2 : 1.6,
            trail: [],
            renderKind: renderKind
        )
    }

    private static func makeBurst(source: SignalSource, color: NSColor, now: Date, energy: Double, glow: Double, renderKind: SignalRenderKind) -> SignalParticle {
        let velocity = SignalEmitter.randomVector(scale: 0.12 * energy)
        return SignalParticle(
            id: UUID(),
            kind: .burst,
            sourceID: source.id,
            position: source.position,
            velocity: velocity,
            birth: now,
            lifespan: 1.4 + energy * 0.5,
            baseSize: 14 * energy,
            color: color,
            strength: energy,
            glow: glow,
            ringRadius: 6,
            ringWidth: 2.6,
            trail: [],
            renderKind: renderKind
        )
    }

    private static func randomVector(scale: Double) -> SIMD3<Double> {
        let x = Double.random(in: -scale...scale)
        let y = Double.random(in: -scale...scale)
        let z = Double.random(in: -scale...scale)
        return SIMD3<Double>(x, y, z)
    }
}

struct SignalVisualStyle: Hashable {
    let hue: Double
    let saturation: Double
    let brightness: Double
    let glow: Double
    let confidence: Double

    static func from(event: NormalizedEvent, now: Date) -> SignalVisualStyle {
        let baseColor = SignalColor.renderKindAccent(
            renderKind: SignalRenderKind.from(event: event),
            channel: event.signal.channel
        )
        let base = baseColor.usingColorSpace(.deviceRGB) ?? baseColor
        var hueValue: CGFloat = 0
        var satValue: CGFloat = 0
        var brightValue: CGFloat = 0
        var alphaValue: CGFloat = 1
        base.getHue(&hueValue, saturation: &satValue, brightness: &brightValue, alpha: &alphaValue)
        let hue = Double(hueValue)

        let timestamp = event.eventTs ?? event.recvTs ?? now
        let age = max(0.0, now.timeIntervalSince(timestamp))
        let recency = exp(-age / 6.0)

        let strength = event.signal.strength ?? -65
        let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
        let brightness = clamp(0.32 + recency * 0.6 + strengthNorm * 0.45)
        let confidence = clamp(0.2 + strengthNorm * 0.8)
        let saturation = clamp(0.35 + confidence * 0.85)

        var glow = 0.25 + confidence * 0.65 + recency * 0.3
        if event.kind.lowercased().contains("node") { glow += 0.1 }
        if event.kind.lowercased().contains("rf") || event.signal.tags.contains("rf") { glow += 0.18 }
        if event.signal.tags.contains("tool") { glow += 0.12 }
        if event.kind.lowercased().contains("error") { glow += 0.2 }
        glow = clamp(glow)

        return SignalVisualStyle(hue: hue, saturation: saturation, brightness: brightness, glow: glow, confidence: confidence)
    }

    private static func clamp(_ value: Double, min: Double = 0.0, max: Double = 1.0) -> Double {
        return Swift.max(min, Swift.min(max, value))
    }
}

struct SignalFrameStyle: Hashable {
    let color: NSColor
    let glow: Double
    let confidence: Double

    static func from(frame: SignalFrame) -> SignalFrameStyle {
        let hue = frame.color.h / 360.0
        let saturation = clamp(0.35 + frame.color.s * 0.8)
        let brightness = clamp(0.35 + frame.color.l * 0.75)
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
        let glow = clamp(frame.glow ?? (0.2 + frame.confidence * 0.6))
        return SignalFrameStyle(color: color, glow: glow, confidence: clamp(frame.confidence))
    }

    private static func clamp(_ value: Double, min: Double = 0.0, max: Double = 1.0) -> Double {
        return Swift.max(min, Swift.min(max, value))
    }
}

enum SignalColor {
    static func deviceColor(id: String, saturation: Double = 0.65, brightness: Double = 0.9) -> NSColor {
        let hue = stableHue(for: id)
        let s = max(0.2, min(1.0, saturation))
        let b = max(0.2, min(1.0, brightness))
        return NSColor(calibratedHue: hue, saturation: s, brightness: b, alpha: 1.0)
    }

    static func kindAccent(kind: String, channel: String? = nil) -> NSColor {
        let kind = kind.lowercased()
        let channelNumber = Int(channel ?? "")
        if kind.contains("ble") {
            // Electric cyan
            return NSColor(calibratedHue: 0.54, saturation: 0.9, brightness: 1.0, alpha: 1.0)
        }
        if kind.contains("wifi") || kind.contains("net") || kind.contains("host") {
            // 2.4G = neon green, 5G = violet/blue
            if let channelNumber, channelNumber > 0, channelNumber <= 14 {
                return NSColor(calibratedHue: 0.32, saturation: 0.9, brightness: 0.98, alpha: 1.0)
            }
            return NSColor(calibratedHue: 0.64, saturation: 0.85, brightness: 0.98, alpha: 1.0)
        }
        if kind.contains("rf") || kind.contains("sdr") {
            // Magenta
            return NSColor(calibratedHue: 0.9, saturation: 0.85, brightness: 0.98, alpha: 1.0)
        }
        if kind.contains("node") {
            // My nodes: red/orange
            return NSColor(calibratedHue: 0.03, saturation: 0.9, brightness: 0.98, alpha: 1.0)
        }
        if kind.contains("tool") || kind.contains("action") || kind.contains("command") || kind.contains("runbook") || kind.contains("cmd") {
            // Purple
            return NSColor(calibratedHue: 0.78, saturation: 0.85, brightness: 0.95, alpha: 1.0)
        }
        if kind.contains("error") {
            // Hot red
            return NSColor(calibratedHue: 0.0, saturation: 0.95, brightness: 1.0, alpha: 1.0)
        }
        return NSColor(calibratedHue: 0.1, saturation: 0.75, brightness: 0.95, alpha: 1.0)
    }

    static func renderKindAccent(renderKind: SignalRenderKind, channel: String? = nil) -> NSColor {
        switch renderKind {
        case .ble:
            return kindAccent(kind: "ble.seen", channel: channel)
        case .wifi:
            return kindAccent(kind: "wifi.status", channel: channel)
        case .node:
            return kindAccent(kind: "node.heartbeat", channel: channel)
        case .tool:
            return kindAccent(kind: "tool", channel: channel)
        case .error:
            return kindAccent(kind: "error", channel: channel)
        case .generic:
            return kindAccent(kind: "signal", channel: channel)
        }
    }

    static func typeFirstColor(
        renderKind: SignalRenderKind,
        deviceID: String,
        channel: String? = nil,
        deviceBlend: Double = 0.22,
        saturation: Double? = nil,
        brightness: Double? = nil
    ) -> NSColor {
        let base = renderKindAccent(renderKind: renderKind, channel: channel)
        let tint = deviceColor(id: deviceID, saturation: 0.62, brightness: 0.92)
        let blended = mix(base, tint, ratio: deviceBlend)
        return applyTone(blended, saturation: saturation, brightness: brightness)
    }

    private static func applyTone(_ color: NSColor, saturation: Double?, brightness: Double?) -> NSColor {
        guard saturation != nil || brightness != nil else { return color }
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        var hueValue: CGFloat = 0
        var satValue: CGFloat = 0
        var brightValue: CGFloat = 0
        var alphaValue: CGFloat = 1
        converted.getHue(&hueValue, saturation: &satValue, brightness: &brightValue, alpha: &alphaValue)
        let sat = CGFloat(max(0.2, min(1.0, saturation ?? Double(satValue))))
        let bright = CGFloat(max(0.2, min(1.0, brightness ?? Double(brightValue))))
        return NSColor(calibratedHue: hueValue, saturation: sat, brightness: bright, alpha: alphaValue)
    }

    static func mix(_ base: NSColor, _ accent: NSColor, ratio: Double) -> NSColor {
        let ratio = max(0.0, min(1.0, ratio))
        let base = base.usingColorSpace(.deviceRGB) ?? base
        let accent = accent.usingColorSpace(.deviceRGB) ?? accent
        let r = base.redComponent * (1 - ratio) + accent.redComponent * ratio
        let g = base.greenComponent * (1 - ratio) + accent.greenComponent * ratio
        let b = base.blueComponent * (1 - ratio) + accent.blueComponent * ratio
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    static func stableHue(for string: String) -> CGFloat {
        var hash: UInt32 = 2166136261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return CGFloat(hash % 360) / 360.0
    }
}

private func clamp(_ value: Double, min: Double = 0.0, max: Double = 1.0) -> Double {
    Swift.max(min, Swift.min(max, value))
}

private func stableDepthOffset(for id: String) -> Double {
    let seed = Double(SignalColor.stableHue(for: id))
    return (seed - 0.5) * 0.24
}

private func diamondPath(in rect: CGRect) -> Path {
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    path.move(to: CGPoint(x: center.x, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: center.y))
    path.addLine(to: CGPoint(x: center.x, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: center.y))
    path.closeSubpath()
    return path
}

private func depthScalar(id: String, z: Double, now: Date) -> CGFloat {
    let base = 0.52 + z * 0.85 + stableDepthOffset(for: id)
    let seed = Double(SignalColor.stableHue(for: id)) * Double.pi * 2
    let jitter = sin(now.timeIntervalSinceReferenceDate * 0.7 + seed) * 0.05
    let value = max(0.35, min(1.35, base + jitter))
    return CGFloat(value)
}

private func depthFade(for depth: CGFloat) -> CGFloat {
    let value = 0.45 + depth * 0.45
    return max(0.3, min(1.1, value))
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x12345678 : seed
    }

    mutating func next() -> Double {
        state = 2862933555777941757 &* state &+ 3037000493
        return Double(state % 1_000_000) / 1_000_000.0
    }
}

struct Parallax {
    static func offset(mousePoint: CGPoint, size: CGSize, now: Date, lastMove: Date) -> CGPoint {
        let idleTime = now.timeIntervalSince(lastMove)
        if idleTime > 1.5 {
            let driftX = sin(now.timeIntervalSince1970 * 0.2) * 18
            let driftY = cos(now.timeIntervalSince1970 * 0.18) * 12
            return CGPoint(x: driftX, y: driftY)
        }
        guard size.width > 0, size.height > 0 else { return .zero }
        let dx = (mousePoint.x / size.width - 0.5) * 40
        let dy = (mousePoint.y / size.height - 0.5) * 24
        return CGPoint(x: dx, y: dy)
    }
}

struct MouseTracker: NSViewRepresentable {
    var onMove: (CGPoint) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
    }
}

final class TrackingView: NSView {
    var onMove: ((CGPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMove?(location)
    }
}
