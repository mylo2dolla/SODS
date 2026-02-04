import SwiftUI
import AppKit

extension Notification.Name {
    static let sodsReplaySeek = Notification.Name("sods.replay.seek")
}

struct VisualizerView: View {
    @ObservedObject var store: SODSStore
    let onOpenTools: () -> Void
    @State private var baseURLText: String = ""
    @State private var paused: Bool = false
    @State private var decayRate: Double = 1.0
    @State private var timeScale: Double = 1.0
    @State private var maxParticles: Double = 1400
    @State private var intensityMode: SignalIntensity = .calm
    @State private var replayEnabled: Bool = false
    @State private var replayOffset: Double = 0
    @State private var replayAutoPlay: Bool = false
    @State private var replaySpeed: Double = 1.0
    @State private var ghostTrails: Bool = true
    @State private var selectedNodeIDs: Set<String> = []
    @State private var selectedKinds: Set<String> = []
    @State private var selectedDeviceIDs: Set<String> = []

    var body: some View {
        HStack(spacing: 12) {
            sidebar
                .frame(minWidth: 320, maxWidth: 360)
            SignalFieldView(
                events: filteredEvents,
                frames: store.frames,
                paused: paused,
                decayRate: decayRate,
                timeScale: timeScale,
                maxParticles: Int(maxParticles),
                intensity: intensityMode,
                replayEnabled: replayEnabled,
                replayOffset: replayOffset,
                ghostTrails: ghostTrails
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(Theme.background)
        .onAppear {
            baseURLText = store.baseURL
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard replayEnabled, replayAutoPlay else { return }
            replayOffset += replaySpeed
            if replayOffset > 60 { replayOffset = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sodsReplaySeek)) { notification in
            if let value = notification.object as? Double {
                replayOffset = max(0, min(60, value))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            legend
            nodesSection
            kindsSection
            devicesSection
            Spacer()
        }
        .modifier(Theme.cardStyle())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SODS Spectrum")
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
        }
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
                    Button("Apply") {
                        store.updateBaseURL(baseURLText)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
                HStack(spacing: 8) {
                    Button(paused ? "Play" : "Pause") {
                        paused.toggle()
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
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
                Toggle("Replay last 60s", isOn: $replayEnabled)
                    .font(.system(size: 11))
                if replayEnabled {
                    Toggle("Auto Play", isOn: $replayAutoPlay)
                        .font(.system(size: 11))
                    sliderRow(title: "Offset", value: $replayOffset, range: 0...60, format: "%.0fs")
                    sliderRow(title: "Speed", value: $replaySpeed, range: 0.25...4.0, format: "%.2fx")
                }
                Toggle("Ghost trails", isOn: $ghostTrails)
                    .font(.system(size: 11))
            }
            .padding(6)
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

    private var legend: some View {
        GroupBox("Legend") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SignalKindLegend.allCases) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(entry.color))
                            .frame(width: 8, height: 8)
                        Text(entry.label)
                            .font(.system(size: 11))
                        Spacer()
                    }
                }
            }
            .padding(6)
        }
    }

    private var nodesSection: some View {
        GroupBox("Nodes") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.nodes) { node in
                    NodeRow(
                        node: node,
                        color: SignalColor.deviceColor(id: node.id),
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
                    FilterRow(
                        label: deviceID,
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
        let kinds = Set(store.events.map { $0.kind })
        return kinds.sorted()
    }

    private var availableDevices: [String] {
        let devices = store.events.compactMap { $0.deviceID }
        return Array(Set(devices)).sorted()
    }

    private var filteredEvents: [NormalizedEvent] {
        let base = store.events.filter { event in
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

    // persistence handled inside SignalFieldView

    private func toggleFilter(id: String, in set: inout Set<String>) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }
}

struct NodeRow: View {
    let node: SignalNode
    let color: NSColor
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
                    .fill(Color(color))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.id)
                        .font(.system(size: 11, weight: .semibold))
                    Text(node.hostname ?? node.ip ?? "Unknown host")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(node.isStale ? "Stale" : "Live")
                    .font(.system(size: 10))
                    .foregroundColor(node.isStale ? .orange : .green)
            }
            HStack(spacing: 6) {
                Button(selected ? "Hide" : "Show") { onToggle() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Button("Whoami") { onOpenWhoami() }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(node.ip == nil)
                Button("Health") { onOpenHealth() }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(node.ip == nil)
                Button("Metrics") { onOpenMetrics() }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(node.ip == nil)
                Button("Tools") { onOpenTools() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
            }
        }
        .padding(6)
        .background(selected ? Theme.panelAlt : Theme.panel)
        .cornerRadius(6)
    }
}

struct FilterRow: View {
    let label: String
    let color: NSColor
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(color))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
            Spacer()
            Button(selected ? "Hide" : "Show") {
                onToggle()
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
    }
}

struct SignalFieldView: View {
    let events: [NormalizedEvent]
    let frames: [SignalFrame]
    let paused: Bool
    let decayRate: Double
    let timeScale: Double
    let maxParticles: Int
    let intensity: SignalIntensity
    let replayEnabled: Bool
    let replayOffset: Double
    let ghostTrails: Bool

    @StateObject private var engine = SignalFieldEngine()
    @State private var mousePoint: CGPoint = .zero
    @State private var lastMouseMove: Date = .distantPast
    @State private var selectedNode: SignalFieldEngine.ProjectedNode?
    @State private var focusedNodeID: String?
    @State private var pinnedNodeIDs: Set<String> = []
    @State private var quickOverlayVisible: Bool = false
    @State private var quickOverlayHideAt: Date = .distantPast

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                Canvas { context, size in
                    let parallax = Parallax.offset(mousePoint: mousePoint, size: size, now: timeline.date, lastMove: lastMouseMove)
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
                        focusID: focusedNodeID,
                        ghostTrails: ghostTrails
                    )
                }
            }
            .overlay(MouseTracker { location in
                mousePoint = location
                lastMouseMove = Date()
            })
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                if let hit = engine.nearestNode(to: value.location) {
                    selectedNode = hit
                    quickOverlayVisible = false
                } else {
                    selectedNode = nil
                    quickOverlayVisible = true
                    quickOverlayHideAt = Date().addingTimeInterval(2.5)
                }
            })

            if quickOverlayVisible {
                QuickOverlayView(
                    activeCount: max(frames.count, events.count),
                    hottestSource: hottestLabel,
                    status: frames.isEmpty ? "Idle" : "Live",
                    focused: focusedNodeID
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
                NodeInspectorView(
                    node: node,
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
                    onClose: {
                        selectedNode = nil
                    }
                )
                .transition(.opacity)
            }

            if frames.isEmpty && events.isEmpty {
                IdleOverlayView()
            }

            if !pinnedNodeIDs.isEmpty {
                PinnedNodesView(
                    pinned: pinnedNodeIDs.sorted(),
                    onClear: { pinnedNodeIDs.removeAll(); persistState() },
                    onFocus: { id in focusedNodeID = id; persistState() }
                )
            }

            LegendOverlayView()
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
        guard let hottest = frames.max(by: { ($0.glow ?? 0) < ($1.glow ?? 0) }) else {
            return "idle"
        }
        return hottest.deviceID
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
}

struct LegendOverlayView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.system(size: 11, weight: .semibold))
            legendRow(color: SignalColor.kindAccent(kind: "ble.seen"), label: "BLE")
            legendRow(color: SignalColor.kindAccent(kind: "wifi.status"), label: "Wi-Fi")
            legendRow(color: SignalColor.kindAccent(kind: "node.heartbeat"), label: "Node")
        }
        .padding(10)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(10)
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
    let onClear: () -> Void
    let onFocus: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pinned")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Clear") { onClear() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            ForEach(pinned, id: \.self) { id in
                HStack(spacing: 6) {
                    Text(id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Focus") { onFocus(id) }
                        .buttonStyle(SecondaryActionButtonStyle())
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

struct NodeInspectorView: View {
    let node: SignalFieldEngine.ProjectedNode
    let focused: Bool
    let pinned: Bool
    let onFocus: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Node Inspector")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(node.color))
                    .frame(width: 10, height: 10)
                Text(node.id)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text("Depth: \(String(format: "%.2f", node.depth))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button(focused ? "Clear Focus" : "Focus") { onFocus() }
                    .buttonStyle(PrimaryActionButtonStyle())
                Button(pinned ? "Unpin" : "Pin") { onPin() }
                    .buttonStyle(SecondaryActionButtonStyle())
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// Spectrum Visualizer Core: consumes frames/events and produces a living field state.
final class SignalFieldEngine: ObservableObject {
    private var sources: [String: SignalSource] = [:]
    private var particles: [SignalParticle] = []
    private var processedIDs: Set<String> = []
    private var lastUpdate: Date?
    private var lastProjected: [ProjectedNode] = []
    private var pulses: [FieldPulse] = []
    private var lastPulseBySource: [String: Date] = [:]

    struct ProjectedNode: Hashable {
        let id: String
        let point: CGPoint
        let color: NSColor
        let depth: CGFloat
    }

    struct FieldPulse: Hashable {
        let id: UUID
        let position: SIMD3<Double>
        let color: NSColor
        let birth: Date
        let lifespan: TimeInterval
        let strength: Double
    }

    struct GhostPoint: Hashable {
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
        ghostTrails: Bool
    ) {
        drawBackground(context: &context, size: size, now: now)

        if !paused {
            if !frames.isEmpty {
                ingest(frames: frames, now: now)
            } else {
                ingest(events: events, intensity: intensity, now: now)
            }
            step(now: now, timeScale: timeScale, decayRate: decayRate)
        } else {
            lastUpdate = now
        }

        drawBins(context: &context, size: size, frames: frames, now: now, focusID: focusID)
        lastProjected = drawSources(context: &context, size: size, parallax: parallax, selectedID: selectedID, focusID: focusID)
        if ghostTrails {
            updateGhosts(now: now)
            drawGhosts(context: &context, size: size, parallax: parallax, focusID: focusID)
        }
        drawConnections(context: &context, focusID: focusID)
        drawPulses(context: &context, size: size, now: now, parallax: parallax, focusID: focusID)
        drawParticles(context: &context, size: size, now: now, parallax: parallax, focusID: focusID)

        if particles.count > maxParticles {
            particles.removeFirst(particles.count - maxParticles)
        }
    }

    private func ingest(events: [NormalizedEvent], intensity: SignalIntensity, now: Date) {
        for event in events {
            guard processedIDs.insert(event.id).inserted else { continue }
            let key = event.deviceID ?? event.nodeID
            let source = sources[key] ?? SignalSource(id: key)
            source.update(from: event)
            sources[key] = source
            particles.append(contentsOf: SignalEmitter.emit(from: source, event: event, intensity: intensity, now: now))
            seedPulse(id: key, source: source, event: event, now: now)
        }
        if processedIDs.count > 4000 {
            processedIDs.removeAll(keepingCapacity: true)
        }
    }

    private func ingest(frames: [SignalFrame], now: Date) {
        for frame in frames {
            let key = frame.deviceID
            let source = sources[key] ?? SignalSource(id: key)
            source.update(from: frame)
            sources[key] = source
            let style = SignalFrameStyle.from(frame: frame)
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
                    color: style.color,
                    strength: max(0.2, style.confidence * 1.4),
                    glow: style.glow,
                    ringRadius: 0,
                    ringWidth: 1.6,
                    trail: []
                )
            )
            seedPulse(id: key, color: style.color, strength: style.glow, source: source, now: now)
        }
    }

    private func step(now: Date, timeScale: Double, decayRate: Double) {
        let dt: Double
        if let last = lastUpdate {
            dt = min(0.05, now.timeIntervalSince(last)) * timeScale
        } else {
            dt = 0.016 * timeScale
        }
        lastUpdate = now
        let decay = max(0.2, min(2.2, decayRate))
        applyAttraction()
        applyRepulsion()
        for source in sources.values {
            source.step(dt: dt)
        }
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

    private func applyAttraction() {
        let nodes = Array(sources.values)
        guard nodes.count > 1 else { return }
        for i in 0..<(nodes.count - 1) {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                if a.group != b.group { continue }
                let delta = b.position - a.position
                let dist2 = max(0.0001, delta.x * delta.x + delta.y * delta.y)
                if dist2 > 0.08 && dist2 < 0.6 {
                    let strength = (dist2 - 0.08) * 0.06
                    let dir = delta / sqrt(dist2)
                    a.velocity += dir * strength
                    b.velocity -= dir * strength
                }
            }
        }
    }

    private func applyRepulsion() {
        let nodes = Array(sources.values)
        guard nodes.count > 1 else { return }
        for i in 0..<(nodes.count - 1) {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                let delta = a.position - b.position
                let dist2 = max(0.0001, delta.x * delta.x + delta.y * delta.y)
                if dist2 < 0.18 {
                    let strength = (0.18 - dist2) * 0.6
                    let dir = delta / sqrt(dist2)
                    a.velocity += dir * strength
                    b.velocity -= dir * strength
                }
            }
        }
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize, now: Date) {
        let rect = CGRect(origin: .zero, size: size)
        let gradient = Gradient(colors: [
            Color(red: 0.05, green: 0.05, blue: 0.08),
            Color(red: 0.06, green: 0.06, blue: 0.11),
            Color(red: 0.03, green: 0.03, blue: 0.06)
        ])
        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let hazeGradient = Gradient(colors: [
            Color(red: 0.18, green: 0.06, blue: 0.08, opacity: 0.22),
            Color(red: 0.05, green: 0.02, blue: 0.04, opacity: 0.0)
        ])
        context.fill(Path(ellipseIn: CGRect(x: center.x - size.width * 0.45, y: center.y - size.height * 0.45, width: size.width * 0.9, height: size.height * 0.9)),
                     with: .radialGradient(hazeGradient, center: center, startRadius: 0, endRadius: min(size.width, size.height) * 0.55))
        for ring in 1...4 {
            let radius = min(size.width, size.height) * 0.12 * CGFloat(ring)
            let ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: ringRect), with: .color(Color.white.opacity(0.04)), lineWidth: 1)
        }

        let starCount = 60
        for i in 0..<starCount {
            let seed = Double(i) * 0.31
            let x = (sin(seed * 12.1) * 0.5 + 0.5) * size.width
            let y = (cos(seed * 9.7) * 0.5 + 0.5) * size.height
            let alpha = 0.08 + 0.06 * (sin(now.timeIntervalSince1970 * 0.2 + seed) * 0.5 + 0.5)
            let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
            context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(alpha)))
        }
    }

    private func drawBins(context: inout GraphicsContext, size: CGSize, frames: [SignalFrame], now: Date, focusID: String?) {
        guard !frames.isEmpty else { return }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let minDim = min(size.width, size.height)
        for frame in frames.prefix(90) {
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
            let color = Color(
                NSColor(
                    calibratedHue: CGFloat(frame.color.h / 360.0),
                    saturation: CGFloat(frame.color.s),
                    brightness: CGFloat(frame.color.l),
                    alpha: 1.0
                )
            )
            var path = Path()
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.stroke(path, with: .color(color.opacity(dimmed ? 0.08 : 0.18)), lineWidth: arcWidth)
        }
    }

    private func drawSources(context: inout GraphicsContext, size: CGSize, parallax: CGPoint, selectedID: String?, focusID: String?) -> [ProjectedNode] {
        var projected: [ProjectedNode] = []
        for source in sources.values {
            let point = source.project(in: size, parallax: parallax)
            let depth = source.depth
            let glow = CGSize(width: 26 * depth, height: 26 * depth)
            let core = CGSize(width: 10 * depth, height: 10 * depth)
            let dimmed = focusID != nil && focusID != source.id
            let color = Color(source.color).opacity(dimmed ? 0.25 : 1.0)

            let glowRect = CGRect(x: point.x - glow.width / 2, y: point.y - glow.height / 2, width: glow.width, height: glow.height)
            context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(dimmed ? 0.08 : 0.2)))

            let coreRect = CGRect(x: point.x - core.width / 2, y: point.y - core.height / 2, width: core.width, height: core.height)
            context.fill(Path(ellipseIn: coreRect), with: .color(color.opacity(dimmed ? 0.4 : 0.9)))
            if let selectedID, selectedID == source.id {
                context.stroke(Path(ellipseIn: glowRect), with: .color(color.opacity(0.9)), lineWidth: 2.0)
            }
            projected.append(ProjectedNode(id: source.id, point: point, color: source.color, depth: depth))
        }
        return projected
    }

    private func drawParticles(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, focusID: String?) {
        for particle in particles {
            let dimmed = focusID != nil && focusID != particle.sourceID
            particle.draw(context: &context, size: size, now: now, parallax: parallax, dimmed: dimmed)
        }
    }

    private func drawConnections(context: inout GraphicsContext, focusID: String?) {
        guard lastProjected.count > 1 else { return }
        for i in 0..<(lastProjected.count - 1) {
            for j in (i + 1)..<lastProjected.count {
                let a = lastProjected[i]
                let b = lastProjected[j]
                if groupFor(id: a.id) != groupFor(id: b.id) { continue }
                if focusID != nil && focusID != a.id && focusID != b.id { continue }
                let dx = a.point.x - b.point.x
                let dy = a.point.y - b.point.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist > 220 { continue }
                var path = Path()
                path.move(to: a.point)
                path.addLine(to: b.point)
                let alpha = 0.08 + (1.0 - min(1.0, dist / 220)) * 0.18
                context.stroke(path, with: .color(Color(a.color).opacity(alpha)), lineWidth: 1.0)
            }
        }
    }

    private func groupFor(id: String) -> String {
        String(id.split(separator: ":").first ?? Substring(id))
    }

    private func updateGhosts(now: Date) {
        if now.timeIntervalSince(ghostLastFlush) > 0.12 {
            ghostLastFlush = now
            for source in sources.values {
                ghostAccumulator.append(GhostPoint(position: source.position, color: source.color, ts: now))
            }
            if ghostAccumulator.count > 180 {
                ghostAccumulator.removeFirst(ghostAccumulator.count - 180)
            }
        }
    }

    private func drawGhosts(context: inout GraphicsContext, size: CGSize, parallax: CGPoint, focusID: String?) {
        guard !ghostAccumulator.isEmpty else { return }
        let now = Date()
        for ghost in ghostAccumulator {
            let ageSeconds = max(0.0, now.timeIntervalSince(ghost.ts))
            let alpha = max(0.02, 0.18 * exp(-ageSeconds / 4.5))
            let depth = CGFloat(0.6 + ghost.position.z * 0.7)
            let basePoint = CGPoint(
                x: CGFloat(ghost.position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
                y: CGFloat(ghost.position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
            )
            let radius = CGFloat(1.0 + alpha * 10.0) * depth
            context.fill(Path(ellipseIn: CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Color(ghost.color).opacity(alpha)))
        }
    }

    private func drawPulses(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, focusID: String?) {
        for pulse in pulses {
            let age = now.timeIntervalSince(pulse.birth)
            let progress = min(1.0, age / max(0.01, pulse.lifespan))
            let alpha = (1.0 - progress) * pulse.strength
            let depth = CGFloat(0.6 + pulse.position.z * 0.7)
            let center = CGPoint(
                x: CGFloat(pulse.position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
                y: CGFloat(pulse.position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
            )
            let radius = CGFloat(18 + progress * 140) * depth
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let color = Color(pulse.color).opacity(alpha * (focusID == nil ? 0.6 : 0.25))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: CGFloat(1.4 + pulse.strength * 2))
        }
    }

    private var ghostAccumulator: [GhostPoint] = []
    private var ghostLastFlush: Date = .distantPast

    private func seedPulse(id: String, source: SignalSource, event: NormalizedEvent, now: Date) {
        let color = SignalColor.deviceColor(id: id)
        seedPulse(id: id, color: color, strength: event.signal.strength == nil ? 0.5 : 0.8, source: source, now: now)
    }

    private func seedPulse(id: String, color: NSColor, strength: Double, source: SignalSource, now: Date) {
        if let last = lastPulseBySource[id], now.timeIntervalSince(last) < 0.2 { return }
        lastPulseBySource[id] = now
        pulses.append(FieldPulse(id: UUID(), position: source.position, color: color, birth: now, lifespan: 1.3, strength: strength))
        if pulses.count > 80 {
            pulses.removeFirst(pulses.count - 80)
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
}

final class SignalSource: Hashable {
    let id: String
    let group: String
    var position: SIMD3<Double>
    var velocity: SIMD3<Double> = .zero
    var target: SIMD3<Double>
    let color: NSColor

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
        let nz = frame.z ?? 0.6
        target = SIMD3<Double>((nx - 0.5) * 2.0 * 0.6, (ny - 0.5) * 2.0 * 0.6, nz)
    }

    func update(from event: NormalizedEvent) {
        let baseHue = Double(SignalColor.stableHue(for: event.deviceID ?? event.nodeID))
        let kindOffset = event.kind.contains("wifi") ? 0.08 : event.kind.contains("ble") ? -0.06 : 0.0
        let channel = Double(event.signal.channel ?? "") ?? baseHue * 180
        let angle = (channel.truncatingRemainder(dividingBy: 180) / 180.0) * Double.pi * 2 + kindOffset
        let radius = event.kind.contains("ble") ? 0.32 : event.kind.contains("wifi") ? 0.52 : 0.7
        let x = cos(angle) * radius
        let y = sin(angle) * radius
        let z = max(0.2, min(1.0, 0.45 + (event.signal.strength ?? -60) / -120))
        target = SIMD3<Double>(x, y, z)
    }

    func step(dt: Double) {
        let swirl = SIMD3<Double>(-position.y, position.x, 0) * 0.12
        let spring = SIMD3<Double>(repeating: 1.6)
        let damping: Double = 0.82
        let delta = target - position
        velocity += (delta * spring + swirl) * dt
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

    func draw(context: inout GraphicsContext, size: CGSize, now: Date, parallax: CGPoint, dimmed: Bool) {
        let age = now.timeIntervalSince(birth)
        let progress = min(1.0, age / max(0.01, lifespan))
        let alpha = 1.0 - progress
        let depth = CGFloat(0.6 + position.z * 0.7)
        let basePoint = CGPoint(
            x: CGFloat(position.x) * size.width * 0.45 + size.width * 0.5 + parallax.x * depth,
            y: CGFloat(position.y) * size.height * 0.45 + size.height * 0.5 + parallax.y * depth
        )
        let glowStrength = max(0.0, min(1.0, glow))
        let color = Color(color).opacity(alpha * (dimmed ? 0.25 : 0.9))

        switch kind {
        case .spark:
            let radius = CGFloat(baseSize) * depth * 0.08
            let rect = CGRect(x: basePoint.x - radius / 2, y: basePoint.y - radius / 2, width: radius, height: radius)
            if glowStrength > 0.05 {
                let glowRadius = radius * (1.6 + CGFloat(glowStrength) * 2.4)
                let glowRect = CGRect(x: basePoint.x - glowRadius / 2, y: basePoint.y - glowRadius / 2, width: glowRadius, height: glowRadius)
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity((dimmed ? 0.06 : 0.18) + CGFloat(glowStrength) * 0.35)))
            }
            context.fill(Path(ellipseIn: rect), with: .color(color))
            drawTrail(context: &context, size: size, parallax: parallax, alpha: alpha, dimmed: dimmed)
        case .ring:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.6 + CGFloat(glowStrength) * 0.2)), lineWidth: CGFloat(ringWidth) * depth)
        case .pulse:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.8 + CGFloat(glowStrength) * 0.15)), lineWidth: CGFloat(ringWidth) * depth)
        case .burst:
            let radius = CGFloat(ringRadius) * depth
            let rect = CGRect(x: basePoint.x - radius, y: basePoint.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.8 + CGFloat(glowStrength) * 0.2)), lineWidth: CGFloat(ringWidth) * depth)
            drawTrail(context: &context, size: size, parallax: parallax, alpha: alpha, dimmed: dimmed)
        }
    }

    private func drawTrail(context: inout GraphicsContext, size: CGSize, parallax: CGPoint, alpha: Double, dimmed: Bool) {
        guard trail.count > 1 else { return }
        let depth = CGFloat(0.6 + position.z * 0.7)
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
        context.stroke(path, with: .color(Color(color).opacity(alpha * baseAlpha)), lineWidth: 1.2 * depth)
    }
}

enum ParticleKind {
    case spark
    case ring
    case pulse
    case burst
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
        case .calm: return 0.7
        case .storm: return 1.4
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
    static func emit(from source: SignalSource, event: NormalizedEvent, intensity: SignalIntensity, now: Date) -> [SignalParticle] {
        let kind = event.kind.lowercased()
        let strength = event.signal.strength ?? -60
        let energy = max(0.2, min(1.8, (abs(strength) / 90.0)))
        let style = SignalVisualStyle.from(event: event, now: now)
        let deviceID = event.deviceID ?? event.nodeID
        let baseColor = SignalColor.deviceColor(id: deviceID, saturation: style.saturation, brightness: style.brightness)
        let count = Int(ceil(6 * intensity.multiplier * energy))
        var particles: [SignalParticle] = []

        if kind.contains("ble") {
            for _ in 0..<count {
                particles.append(makeSpark(source: source, color: baseColor, now: now, energy: energy, glow: style.glow))
            }
        } else if kind.contains("wifi") {
            particles.append(makeRing(source: source, color: baseColor, now: now, pulse: false, glow: style.glow))
        } else if kind.contains("node") {
            particles.append(makeRing(source: source, color: baseColor, now: now, pulse: true, glow: style.glow))
        } else if kind.contains("tool") {
            particles.append(makeBurst(source: source, color: baseColor, now: now, energy: energy, glow: min(1.0, style.glow + 0.25)))
        } else if kind.contains("error") || event.signal.tags.contains("error") {
            for _ in 0..<(max(2, count / 2)) {
                particles.append(makeBurst(source: source, color: baseColor, now: now, energy: energy, glow: min(1.0, style.glow + 0.2)))
            }
        } else {
            particles.append(makeSpark(source: source, color: baseColor, now: now, energy: energy, glow: style.glow))
        }

        return particles
    }

    private static func makeSpark(source: SignalSource, color: NSColor, now: Date, energy: Double, glow: Double) -> SignalParticle {
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
            trail: []
        )
    }

    private static func makeRing(source: SignalSource, color: NSColor, now: Date, pulse: Bool, glow: Double) -> SignalParticle {
        SignalParticle(
            id: UUID(),
            kind: pulse ? .pulse : .ring,
            sourceID: source.id,
            position: source.position,
            velocity: SIMD3<Double>(0, 0, 0),
            birth: now,
            lifespan: pulse ? 1.8 : 2.6,
            baseSize: 10,
            color: color,
            strength: 1.0,
            glow: glow,
            ringRadius: 10,
            ringWidth: pulse ? 2.2 : 1.6,
            trail: []
        )
    }

    private static func makeBurst(source: SignalSource, color: NSColor, now: Date, energy: Double, glow: Double) -> SignalParticle {
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
            trail: []
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
        let deviceID = event.deviceID ?? event.nodeID
        let hue = SignalColor.stableHue(for: deviceID)

        let timestamp = event.eventTs ?? event.recvTs ?? now
        let age = max(0.0, now.timeIntervalSince(timestamp))
        let recency = exp(-age / 6.0)
        let brightness = clamp(0.22 + recency * 0.72)

        let strength = event.signal.strength ?? -65
        let strengthNorm = clamp(((-strength) - 30.0) / 70.0)
        let confidence = clamp(0.2 + strengthNorm * 0.8)
        let saturation = clamp(0.25 + confidence * 0.7)

        var glow = 0.2 + confidence * 0.6 + recency * 0.25
        if event.kind.lowercased().contains("node") { glow += 0.1 }
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
        let saturation = clamp(frame.color.s)
        let brightness = clamp(frame.color.l)
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

    static func kindAccent(kind: String) -> NSColor {
        let kind = kind.lowercased()
        if kind.contains("ble") {
            return NSColor(calibratedHue: 0.52, saturation: 0.7, brightness: 0.95, alpha: 1.0)
        }
        if kind.contains("wifi") {
            return NSColor(calibratedHue: 0.33, saturation: 0.7, brightness: 0.9, alpha: 1.0)
        }
        if kind.contains("node") {
            return NSColor(calibratedHue: 0.62, saturation: 0.6, brightness: 0.92, alpha: 1.0)
        }
        if kind.contains("error") {
            return NSColor(calibratedHue: 0.02, saturation: 0.85, brightness: 0.95, alpha: 1.0)
        }
        return NSColor(calibratedHue: 0.08, saturation: 0.6, brightness: 0.9, alpha: 1.0)
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
