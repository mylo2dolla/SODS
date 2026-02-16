import Foundation
import SwiftUI

public enum SpectrumLayoutMode: String, CaseIterable, Sendable {
    case legacyScatter
    case directionalAggregated
    case hybridCorrelation
}

public typealias SpectrumPulseTopology = SpectrumLayoutMode

public struct SpectrumDisplayOptions: Hashable, Sendable {
    public var showCorrelationLinks: Bool
    public var showInferredLinks: Bool
    public var showStrengthRingOverlay: Bool
    public var focusNodeID: String?

    public init(
        showCorrelationLinks: Bool = true,
        showInferredLinks: Bool = true,
        showStrengthRingOverlay: Bool = true,
        focusNodeID: String? = nil
    ) {
        self.showCorrelationLinks = showCorrelationLinks
        self.showInferredLinks = showInferredLinks
        self.showStrengthRingOverlay = showStrengthRingOverlay
        self.focusNodeID = focusNodeID
    }
}

public struct SpectrumNodeDetail: Identifiable, Hashable, Sendable {
    public let id: String
    public let renderKind: SignalRenderKind
    public let lastSeen: Date
    public let source: String?
    public let channel: String?
    public let rssi: Double?
    public let confidence: Double?
    public let summary: String?
    public let eventData: [String: JSONValue]
    public let frameData: [String: JSONValue]
    public let inboundRatePerSec: Double
    public let outboundRatePerSec: Double
    public let avgStrength: Double?
    public let avgRSSI: Double?
    public let correlatedPeers: [String]

    public init(
        id: String,
        renderKind: SignalRenderKind,
        lastSeen: Date,
        source: String?,
        channel: String?,
        rssi: Double?,
        confidence: Double?,
        summary: String?,
        eventData: [String: JSONValue] = [:],
        frameData: [String: JSONValue] = [:],
        inboundRatePerSec: Double = 0,
        outboundRatePerSec: Double = 0,
        avgStrength: Double? = nil,
        avgRSSI: Double? = nil,
        correlatedPeers: [String] = []
    ) {
        self.id = id
        self.renderKind = renderKind
        self.lastSeen = lastSeen
        self.source = source
        self.channel = channel
        self.rssi = rssi
        self.confidence = confidence
        self.summary = summary
        self.eventData = eventData
        self.frameData = frameData
        self.inboundRatePerSec = inboundRatePerSec
        self.outboundRatePerSec = outboundRatePerSec
        self.avgStrength = avgStrength
        self.avgRSSI = avgRSSI
        self.correlatedPeers = correlatedPeers
    }
}

public struct SpectrumFieldView: View {
    public let events: [NormalizedEvent]
    public let frames: [SignalFrame]
    public let layoutMode: SpectrumLayoutMode
    public let displayOptions: SpectrumDisplayOptions
    public let onNodeTap: ((SpectrumNodeDetail) -> Void)?

    @StateObject private var engine = SpectrumFieldEngine()

    public init(
        events: [NormalizedEvent],
        frames: [SignalFrame],
        layoutMode: SpectrumLayoutMode = .legacyScatter,
        displayOptions: SpectrumDisplayOptions = SpectrumDisplayOptions(),
        onNodeTap: ((SpectrumNodeDetail) -> Void)? = nil
    ) {
        self.events = events
        self.frames = frames
        self.layoutMode = layoutMode
        self.displayOptions = displayOptions
        self.onNodeTap = onNodeTap
    }

    public init(
        events: [NormalizedEvent],
        frames: [SignalFrame],
        pulseTopology: SpectrumPulseTopology,
        displayOptions: SpectrumDisplayOptions = SpectrumDisplayOptions(),
        onNodeTap: ((SpectrumNodeDetail) -> Void)? = nil
    ) {
        self.init(
            events: events,
            frames: frames,
            layoutMode: pulseTopology,
            displayOptions: displayOptions,
            onNodeTap: onNodeTap
        )
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let snapshot = engine.snapshot(now: timeline.date, events: events, frames: frames, layoutMode: layoutMode)
            let focusContext = makeFocusContext(snapshot: snapshot)

            Canvas { context, size in
                drawBackground(context: &context, size: size)
                drawLinks(snapshot: snapshot, focusContext: focusContext, context: &context, size: size)
                drawPulses(snapshot: snapshot, focusContext: focusContext, context: &context, size: size)
                drawNodes(snapshot: snapshot, focusContext: focusContext, context: &context, size: size)
            }
        }
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(onNodeTap != nil)
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { value in
                            guard let onNodeTap else { return }
                            if let detail = engine.nearestNodeDetail(at: value.location, size: proxy.size) {
                                onNodeTap(detail)
                            }
                        }
                    )
            }
        }
    }

    private func makeFocusContext(snapshot: SpectrumSnapshot) -> FocusContext {
        guard
            let focusNodeID = displayOptions.focusNodeID,
            snapshot.nodes.contains(where: { $0.id == focusNodeID })
        else {
            return FocusContext(focusNodeID: nil, highlightedNodeIDs: [], secondaryNodeIDs: [])
        }

        var directNeighbors: Set<String> = [focusNodeID]
        var secondaryNeighbors: Set<String> = []

        for link in snapshot.links {
            if !displayOptions.showInferredLinks && !link.isExplicitTarget {
                continue
            }

            if link.fromID == focusNodeID {
                directNeighbors.insert(link.toID)
            } else if link.toID == focusNodeID {
                directNeighbors.insert(link.fromID)
            }
        }

        for link in snapshot.links {
            if !displayOptions.showInferredLinks && !link.isExplicitTarget {
                continue
            }
            if directNeighbors.contains(link.fromID) || directNeighbors.contains(link.toID) {
                secondaryNeighbors.insert(link.fromID)
                secondaryNeighbors.insert(link.toID)
            }
        }

        secondaryNeighbors.subtract(directNeighbors)
        return FocusContext(focusNodeID: focusNodeID, highlightedNodeIDs: directNeighbors, secondaryNodeIDs: secondaryNeighbors)
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let gradient = Gradient(colors: [
            Color(red: 0.05, green: 0.07, blue: 0.11),
            Color(red: 0.03, green: 0.04, blue: 0.08)
        ])
        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - size.width * 0.35, y: center.y - size.height * 0.35, width: size.width * 0.7, height: size.height * 0.7)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.05), Color.clear]),
                center: center,
                startRadius: 0,
                endRadius: min(size.width, size.height) * 0.45
            )
        )
    }

    private func drawLinks(snapshot: SpectrumSnapshot, focusContext: FocusContext, context: inout GraphicsContext, size: CGSize) {
        guard displayOptions.showCorrelationLinks else { return }

        for link in snapshot.links {
            if !displayOptions.showInferredLinks && !link.isExplicitTarget {
                continue
            }

            let focusOpacity = focusContext.linkOpacityMultiplier(fromID: link.fromID, toID: link.toID)
            if focusOpacity <= 0.01 {
                continue
            }

            let from = CGPoint(x: link.from.x * size.width, y: link.from.y * size.height)
            let to = CGPoint(x: link.to.x * size.width, y: link.to.y * size.height)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)

            let opacity = (0.14 + (0.74 * link.edgeConfidence)) * focusOpacity
            let width = 1.0 + (3.4 * link.edgeActivity)
            let dash: [CGFloat] = link.isExplicitTarget ? [] : [7, 4]
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
            context.stroke(path, with: .color(link.color.opacity(opacity)), style: style)
        }
    }

    private func drawPulses(snapshot: SpectrumSnapshot, focusContext: FocusContext, context: inout GraphicsContext, size: CGSize) {
        guard displayOptions.showCorrelationLinks else { return }

        for pulse in snapshot.pulses {
            if !displayOptions.showInferredLinks && !pulse.isExplicitTarget {
                continue
            }

            let focusOpacity = focusContext.linkOpacityMultiplier(fromID: pulse.fromID, toID: pulse.toID)
            if focusOpacity <= 0.01 {
                continue
            }

            let position = CGPoint(x: pulse.position.x * size.width, y: pulse.position.y * size.height)
            let resolvedOpacity = pulse.opacity * focusOpacity
            let halo = CGRect(
                x: position.x - pulse.radius * 2.4,
                y: position.y - pulse.radius * 2.4,
                width: pulse.radius * 4.8,
                height: pulse.radius * 4.8
            )
            context.fill(Path(ellipseIn: halo), with: .color(pulse.color.opacity(0.2 * resolvedOpacity)))

            let rect = CGRect(
                x: position.x - pulse.radius,
                y: position.y - pulse.radius,
                width: pulse.radius * 2,
                height: pulse.radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(pulse.color.opacity(0.98 * resolvedOpacity)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.42 * resolvedOpacity)), lineWidth: 0.9)

            if pulse.direction.dx != 0 || pulse.direction.dy != 0 {
                let tailDistance = pulse.radius * 2.2
                let tailCenter = CGPoint(
                    x: position.x - (pulse.direction.dx * tailDistance),
                    y: position.y - (pulse.direction.dy * tailDistance)
                )
                let tailRadius = max(2.0, pulse.radius * 0.52)
                let tailRect = CGRect(
                    x: tailCenter.x - tailRadius,
                    y: tailCenter.y - tailRadius,
                    width: tailRadius * 2,
                    height: tailRadius * 2
                )
                context.fill(Path(ellipseIn: tailRect), with: .color(pulse.color.opacity(0.34 * resolvedOpacity)))
            }
        }
    }

    private func drawNodes(snapshot: SpectrumSnapshot, focusContext: FocusContext, context: inout GraphicsContext, size: CGSize) {
        for node in snapshot.nodes {
            let position = CGPoint(x: node.position.x * size.width, y: node.position.y * size.height)
            let opacityMultiplier = focusContext.nodeOpacityMultiplier(for: node.id)
            let strength = max(0.0, min(1.0, node.detail.avgStrength ?? node.detail.confidence ?? 0.35))

            if displayOptions.showStrengthRingOverlay {
                let ringRadius = node.radius * (1.8 + ((1.0 - strength) * 0.55))
                let ringRect = CGRect(
                    x: position.x - ringRadius,
                    y: position.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(node.color.opacity((0.2 + (0.5 * strength)) * opacityMultiplier)),
                    lineWidth: 1.0 + (2.4 * strength)
                )
            }

            let haloRect = CGRect(
                x: position.x - node.radius * 2.6,
                y: position.y - node.radius * 2.6,
                width: node.radius * 5.2,
                height: node.radius * 5.2
            )
            context.fill(Path(ellipseIn: haloRect), with: .color(node.color.opacity((0.17 + (0.24 * strength)) * opacityMultiplier)))

            let dotRect = CGRect(
                x: position.x - node.radius,
                y: position.y - node.radius,
                width: node.radius * 2,
                height: node.radius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(node.color.opacity((0.74 + (0.23 * strength)) * opacityMultiplier)))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color.white.opacity(0.46 * opacityMultiplier)), lineWidth: 1.0)
        }
    }
}

@MainActor
private final class SpectrumFieldEngine: ObservableObject {
    private struct NodeState {
        let id: String
        var position: CGPoint
        var target: CGPoint
        var velocity: CGVector
        var color: Color
        var radius: CGFloat
        var lastSeen: Date
        var renderKind: SignalRenderKind
        var lastSource: String?
        var lastChannel: String?
        var lastRSSI: Double?
        var lastConfidence: Double?
        var lastSummary: String?
        var lastEventData: [String: JSONValue]
        var lastFrameData: [String: JSONValue]
        var avgRSSI: Double?
        var avgStrength: Double?
        var inboundRatePerSec: Double
        var outboundRatePerSec: Double
        var peerScores: [String: Double]
    }

    private struct ScatterPulseState {
        let id: UUID
        var position: CGPoint
        var velocity: CGVector
        var color: Color
        var radius: CGFloat
        var birth: Date
        var life: TimeInterval
    }

    private struct EdgeKey: Hashable {
        let fromID: String
        let toID: String
        let renderKind: SignalRenderKind
    }

    private struct EdgeState {
        let key: EdgeKey
        var color: Color
        var activityEMA: Double
        var confidenceEMA: Double
        var strengthEMA: Double
        var lastSeen: Date
        var lastEmit: Date?
        var isExplicitTarget: Bool
    }

    private struct EdgePulseState {
        let id: UUID
        let edgeKey: EdgeKey
        var progress: Double
        var speed: Double
        var color: Color
        var radius: CGFloat
        var birth: Date
        var life: TimeInterval
        var strength: Double
        var isExplicitTarget: Bool
        var edgeActivity: Double
        var edgeConfidence: Double
    }

    private var nodes: [String: NodeState] = [:]
    private var scatterPulses: [ScatterPulseState] = []
    private var edgeStates: [EdgeKey: EdgeState] = [:]
    private var edgePulses: [EdgePulseState] = []
    private var currentLayoutMode: SpectrumLayoutMode = .legacyScatter
    private var lastUpdate: Date?
    private var smoothedDt: Double?
    private var latestSnapshot: SpectrumSnapshot?
    private var processedDirectionalEventIDs: Set<String> = []
    private var processedDirectionalFrameKeys: Set<String> = []

    func snapshot(now: Date, events: [NormalizedEvent], frames: [SignalFrame], layoutMode: SpectrumLayoutMode) -> SpectrumSnapshot {
        if layoutMode != currentLayoutMode {
            resetState(for: layoutMode)
        }

        switch layoutMode {
        case .legacyScatter:
            ingestLegacy(events: events, frames: frames, now: now)
        case .directionalAggregated, .hybridCorrelation:
            ingestDirectional(events: events, frames: frames, now: now)
        }

        step(now: now, layoutMode: layoutMode)
        let snapshot = makeSnapshot(layoutMode: layoutMode)
        latestSnapshot = snapshot
        return snapshot
    }

    func nearestNodeDetail(at point: CGPoint, size: CGSize) -> SpectrumNodeDetail? {
        guard let snapshot = latestSnapshot else { return nil }
        var winner: (distance: CGFloat, detail: SpectrumNodeDetail)?

        for node in snapshot.nodes {
            let center = CGPoint(x: node.position.x * size.width, y: node.position.y * size.height)
            let distance = point.distance(to: center)
            let hitRadius = max(18, node.radius * 2.5)
            guard distance <= hitRadius else { continue }

            if let current = winner {
                if distance < current.distance {
                    winner = (distance, node.detail)
                }
            } else {
                winner = (distance, node.detail)
            }
        }

        return winner?.detail
    }

    private func resetState(for layoutMode: SpectrumLayoutMode) {
        currentLayoutMode = layoutMode
        nodes.removeAll(keepingCapacity: true)
        scatterPulses.removeAll(keepingCapacity: true)
        edgeStates.removeAll(keepingCapacity: true)
        edgePulses.removeAll(keepingCapacity: true)
        processedDirectionalEventIDs.removeAll(keepingCapacity: true)
        processedDirectionalFrameKeys.removeAll(keepingCapacity: true)
        latestSnapshot = nil
        lastUpdate = nil
        smoothedDt = nil
    }

    private func ingestLegacy(events: [NormalizedEvent], frames: [SignalFrame], now: Date) {
        for frame in frames.suffix(500) {
            let id = frame.deviceID
            let position = CGPoint(x: CGFloat(frame.x ?? 0.5), y: CGFloat(frame.y ?? 0.5))
            let renderKind = SignalRenderKind.from(source: frame.source)
            let strengthInfo = normalizedStrength(
                rssi: frame.rssi,
                confidence: frame.confidence,
                inferredHint: frame.strengthInferred ?? false
            )
            let baseColor = SignalColor.typeFirstColor(renderKind: renderKind, deviceID: id, channel: "\(frame.channel)")
            let swiftUIColor = PlatformColorSupport.swiftUIColor(
                SignalColor.strengthLuminanceBoost(baseColor, strength: strengthInfo.value)
            )
            let radius = max(6.0, CGFloat(7.0 + (strengthInfo.value * 4.5)))
            let framePayload = frameData(from: frame)

            upsertNode(
                id: id,
                position: position,
                color: swiftUIColor,
                radius: radius,
                renderKind: renderKind,
                source: frame.source,
                channel: "\(frame.channel)",
                rssi: frame.strengthInferred == true ? nil : frame.rssi,
                confidence: frame.confidence,
                summary: nil,
                strengthSample: strengthInfo.value,
                rssiSample: frame.strengthInferred == true ? nil : frame.rssi,
                frameData: framePayload,
                now: now
            )

            scatterPulses.append(
                ScatterPulseState(
                    id: UUID(),
                    position: position,
                    velocity: randomVelocity(scale: 0.03),
                    color: swiftUIColor,
                    radius: max(4.5, radius * 0.58),
                    birth: now,
                    life: 1.2
                )
            )
        }

        for event in events.suffix(500) {
            let renderKind = SignalRenderKind.from(event: event)
            let id = normalizeTargetID(event.deviceID ?? normalizeNodeID(event.nodeID), key: nil, renderKind: renderKind)
            let confidence = eventConfidence(event)
            let strengthInfo = normalizedStrength(
                rssi: event.signal.strength,
                confidence: confidence,
                inferredHint: event.data["strength_inferred"]?.boolValue ?? false
            )
            let baseColor = SignalColor.typeFirstColor(renderKind: renderKind, deviceID: id, channel: event.signal.channel)
            let swiftUIColor = PlatformColorSupport.swiftUIColor(
                SignalColor.strengthLuminanceBoost(baseColor, strength: strengthInfo.value)
            )

            upsertNode(
                id: id,
                position: nil,
                color: swiftUIColor,
                radius: max(6.2, CGFloat(7.0 + (strengthInfo.value * 4.2))),
                renderKind: renderKind,
                source: nil,
                channel: event.signal.channel,
                rssi: strengthInfo.inferred ? nil : event.signal.strength,
                confidence: confidence,
                summary: event.summary,
                strengthSample: strengthInfo.value,
                rssiSample: strengthInfo.inferred ? nil : event.signal.strength,
                eventData: event.data,
                now: now
            )
        }

        if scatterPulses.count > 900 {
            scatterPulses.removeFirst(scatterPulses.count - 900)
        }

        if nodes.count > 350 {
            let sorted = nodes.values.sorted { $0.lastSeen > $1.lastSeen }
            nodes = Dictionary(uniqueKeysWithValues: sorted.prefix(350).map { ($0.id, $0) })
        }
    }

    private func ingestDirectional(events: [NormalizedEvent], frames: [SignalFrame], now: Date) {
        for frame in frames.suffix(900) {
            let frameKey = "f:\(frame.t):\(frame.source):\(frame.nodeID):\(frame.deviceID):\(frame.channel)"
            guard processedDirectionalFrameKeys.insert(frameKey).inserted else { continue }
            ingestDirectionalFrame(frame, now: now)
        }

        for event in events.suffix(1200) {
            guard processedDirectionalEventIDs.insert(event.id).inserted else { continue }
            ingestDirectionalEvent(event, now: now)
        }

        if processedDirectionalFrameKeys.count > 8_000 {
            processedDirectionalFrameKeys.removeAll(keepingCapacity: true)
        }
        if processedDirectionalEventIDs.count > 8_000 {
            processedDirectionalEventIDs.removeAll(keepingCapacity: true)
        }

        if edgeStates.count > 1_400 {
            let sorted = edgeStates.values.sorted { $0.lastSeen > $1.lastSeen }
            edgeStates = Dictionary(uniqueKeysWithValues: sorted.prefix(1_400).map { ($0.key, $0) })
        }

        if nodes.count > 650 {
            let sorted = nodes.values.sorted { $0.lastSeen > $1.lastSeen }
            nodes = Dictionary(uniqueKeysWithValues: sorted.prefix(650).map { ($0.id, $0) })
        }
    }

    private func ingestDirectionalFrame(_ frame: SignalFrame, now: Date) {
        let renderKind = SignalRenderKind.from(source: frame.source)
        let sourceID = normalizeNodeID(frame.nodeID)
        let targetID = normalizeTargetID(frame.deviceID, key: "device_id", renderKind: renderKind)
        let confidence = clamp01(frame.confidence)
        let strengthInfo = normalizedStrength(
            rssi: frame.rssi,
            confidence: confidence,
            inferredHint: frame.strengthInferred ?? false
        )
        let baseColor = SignalColor.typeFirstColor(renderKind: renderKind, deviceID: targetID, channel: "\(frame.channel)")
        let color = PlatformColorSupport.swiftUIColor(
            SignalColor.strengthLuminanceBoost(baseColor, strength: strengthInfo.value)
        )
        let framePayload = frameData(from: frame)

        upsertNode(
            id: sourceID,
            position: nil,
            color: PlatformColorSupport.swiftUIColor(
                SignalColor.typeFirstColor(
                    renderKind: .node,
                    deviceID: sourceID,
                    strength: max(strengthInfo.value, 0.45)
                )
            ),
            radius: 7.0,
            renderKind: .node,
            source: frame.source,
            channel: "\(frame.channel)",
            rssi: nil,
            confidence: confidence,
            summary: nil,
            strengthSample: max(strengthInfo.value * 0.8, 0.3),
            rssiSample: nil,
            frameData: framePayload,
            now: now
        )

        upsertNode(
            id: targetID,
            position: CGPoint(x: CGFloat(frame.x ?? 0.5), y: CGFloat(frame.y ?? 0.5)),
            color: color,
            radius: max(6.2, CGFloat(7.0 + (strengthInfo.value * 4.6))),
            renderKind: renderKind,
            source: frame.source,
            channel: "\(frame.channel)",
            rssi: strengthInfo.inferred ? nil : frame.rssi,
            confidence: confidence,
            summary: nil,
            strengthSample: strengthInfo.value,
            rssiSample: strengthInfo.inferred ? nil : frame.rssi,
            frameData: framePayload,
            now: now
        )

        recordEdge(
            fromID: sourceID,
            toID: targetID,
            renderKind: renderKind,
            color: color,
            confidence: confidence,
            strength: strengthInfo.value,
            rssi: strengthInfo.inferred ? nil : frame.rssi,
            isExplicitTarget: true,
            now: now
        )
    }

    private func ingestDirectionalEvent(_ event: NormalizedEvent, now: Date) {
        let renderKind = SignalRenderKind.from(event: event)
        let explicitTarget = explicitTargetID(from: event)
        let sourceID = normalizeNodeID(event.nodeID)
        let fallbackTarget = normalizeTargetID(event.deviceID ?? sourceID, key: nil, renderKind: renderKind)
        let targetID = explicitTarget ?? fallbackTarget

        let useReverseDirection = explicitTarget != nil && (renderKind == .tool || renderKind == .error)
        let fromID = useReverseDirection ? targetID : sourceID
        let toID = useReverseDirection ? sourceID : targetID

        let confidence = eventConfidence(event)
        let strengthInfo = normalizedStrength(
            rssi: event.signal.strength,
            confidence: confidence,
            inferredHint: event.data["strength_inferred"]?.boolValue ?? false
        )
        let baseColor = SignalColor.typeFirstColor(renderKind: renderKind, deviceID: toID, channel: event.signal.channel)
        let color = PlatformColorSupport.swiftUIColor(
            SignalColor.strengthLuminanceBoost(baseColor, strength: strengthInfo.value)
        )

        upsertNode(
            id: sourceID,
            position: nil,
            color: PlatformColorSupport.swiftUIColor(
                SignalColor.typeFirstColor(
                    renderKind: .node,
                    deviceID: sourceID,
                    strength: max(strengthInfo.value * 0.75, 0.32)
                )
            ),
            radius: 7.0,
            renderKind: .node,
            source: nil,
            channel: event.signal.channel,
            rssi: nil,
            confidence: confidence,
            summary: event.summary,
            strengthSample: max(strengthInfo.value * 0.8, 0.28),
            rssiSample: nil,
            eventData: event.data,
            now: now
        )

        upsertNode(
            id: targetID,
            position: nil,
            color: color,
            radius: max(6.3, CGFloat(7.1 + (strengthInfo.value * 4.4))),
            renderKind: renderKind,
            source: nil,
            channel: event.signal.channel,
            rssi: strengthInfo.inferred ? nil : event.signal.strength,
            confidence: confidence,
            summary: event.summary,
            strengthSample: strengthInfo.value,
            rssiSample: strengthInfo.inferred ? nil : event.signal.strength,
            eventData: event.data,
            now: now
        )

        recordEdge(
            fromID: fromID,
            toID: toID,
            renderKind: renderKind,
            color: color,
            confidence: confidence,
            strength: strengthInfo.value,
            rssi: strengthInfo.inferred ? nil : event.signal.strength,
            isExplicitTarget: explicitTarget != nil,
            now: now
        )
    }

    private func step(now: Date, layoutMode: SpectrumLayoutMode) {
        let rawDt: Double
        if let lastUpdate {
            rawDt = max(1.0 / 120.0, min(0.06, now.timeIntervalSince(lastUpdate)))
        } else {
            rawDt = 1.0 / 60.0
        }
        self.lastUpdate = now

        if let previous = smoothedDt {
            smoothedDt = previous + (rawDt - previous) * 0.14
        } else {
            smoothedDt = rawDt
        }
        let dt = smoothedDt ?? rawDt

        if layoutMode == .hybridCorrelation {
            updateHybridTargets(now: now, dt: dt)
        }

        let rateDecay = exp(-dt * 0.92)
        let peerDecay = exp(-dt * 1.02)

        for key in nodes.keys {
            guard var node = nodes[key] else { continue }

            node.inboundRatePerSec *= rateDecay
            node.outboundRatePerSec *= rateDecay

            if !node.peerScores.isEmpty {
                var pruned: [String: Double] = [:]
                pruned.reserveCapacity(node.peerScores.count)
                for (peerID, score) in node.peerScores {
                    let decayed = score * peerDecay
                    if decayed >= 0.03 {
                        pruned[peerID] = decayed
                    }
                }
                node.peerScores = pruned
            }

            let dx = node.target.x - node.position.x
            let dy = node.target.y - node.position.y
            let distance = sqrt((dx * dx) + (dy * dy))
            let spring: CGFloat = layoutMode == .hybridCorrelation ? 7.6 : 9.2
            let adaptiveDamping: CGFloat
            if layoutMode == .hybridCorrelation {
                adaptiveDamping = max(0.74, min(0.92, 0.92 - (distance * 0.18)))
            } else {
                adaptiveDamping = 0.83
            }

            node.velocity.dx += dx * spring * CGFloat(dt)
            node.velocity.dy += dy * spring * CGFloat(dt)
            node.velocity.dx *= adaptiveDamping
            node.velocity.dy *= adaptiveDamping

            node.position.x += node.velocity.dx * CGFloat(dt)
            node.position.y += node.velocity.dy * CGFloat(dt)
            node.position = clampPoint(node.position, padding: 0.025)
            nodes[key] = node
        }

        switch layoutMode {
        case .legacyScatter:
            scatterPulses = scatterPulses.compactMap { pulse in
                var pulse = pulse
                pulse.position.x += pulse.velocity.dx * CGFloat(dt * 60)
                pulse.position.y += pulse.velocity.dy * CGFloat(dt * 60)
                pulse.radius *= 0.992
                let age = now.timeIntervalSince(pulse.birth)
                if age > pulse.life {
                    return nil
                }
                return pulse
            }
        case .directionalAggregated, .hybridCorrelation:
            stepDirectional(now: now, dt: dt)
        }

        let staleThreshold: TimeInterval
        switch layoutMode {
        case .legacyScatter:
            staleThreshold = 16
        case .directionalAggregated:
            staleThreshold = 25
        case .hybridCorrelation:
            staleThreshold = 30
        }
        nodes = nodes.filter { now.timeIntervalSince($0.value.lastSeen) < staleThreshold }
    }

    private func stepDirectional(now: Date, dt: Double) {
        for key in edgeStates.keys {
            guard var edge = edgeStates[key] else { continue }
            edge.activityEMA *= exp(-dt * 0.82)
            edge.confidenceEMA *= exp(-dt * 0.58)
            edge.strengthEMA *= exp(-dt * 0.54)
            let age = now.timeIntervalSince(edge.lastSeen)

            if age > 13.0 && edge.activityEMA < 0.025 {
                edgeStates.removeValue(forKey: key)
                continue
            }

            let emitRate = 1.8 + (6.6 * edge.activityEMA)
            let interval = 1.0 / max(0.5, emitRate)
            let shouldEmit = (edge.lastEmit == nil) || now.timeIntervalSince(edge.lastEmit!) >= interval
            if shouldEmit, nodes[edge.key.fromID] != nil, nodes[edge.key.toID] != nil, edge.key.fromID != edge.key.toID {
                let pulseSpeed = 0.22 + (0.58 * edge.strengthEMA)
                let pulseConfidence = max(0.1, min(1.0, edge.confidenceEMA))
                edgePulses.append(
                    EdgePulseState(
                        id: UUID(),
                        edgeKey: edge.key,
                        progress: 0,
                        speed: pulseSpeed,
                        color: edge.color,
                        radius: CGFloat(3.6 + (5.8 * pulseConfidence)),
                        birth: now,
                        life: max(0.86, 1.6 - (edge.activityEMA * 0.34)),
                        strength: max(0.2, min(1.0, (edge.activityEMA * 0.58) + (edge.confidenceEMA * 0.42))),
                        isExplicitTarget: edge.isExplicitTarget,
                        edgeActivity: max(0.04, min(1.0, edge.activityEMA)),
                        edgeConfidence: pulseConfidence
                    )
                )
                edge.lastEmit = now
            }

            edgeStates[key] = edge
        }

        edgePulses = edgePulses.compactMap { pulse in
            var pulse = pulse
            pulse.progress += pulse.speed * dt
            let age = now.timeIntervalSince(pulse.birth)
            if pulse.progress >= 1.0 || age > pulse.life {
                return nil
            }
            return pulse
        }

        if edgePulses.count > 1500 {
            edgePulses.removeFirst(edgePulses.count - 1500)
        }
    }

    private func updateHybridTargets(now: Date, dt: Double) {
        guard !nodes.isEmpty else { return }

        let center = CGPoint(x: 0.5, y: 0.5)
        let realHubIDs = nodes.keys.filter { $0.hasPrefix("node:") }.sorted()
        let hubIDs: [String]
        if realHubIDs.isEmpty {
            hubIDs = nodes.values
                .sorted { ($0.inboundRatePerSec + $0.outboundRatePerSec) > ($1.inboundRatePerSec + $1.outboundRatePerSec) }
                .prefix(2)
                .map(\.id)
        } else {
            hubIDs = realHubIDs
        }

        var targets: [String: CGPoint] = [:]
        targets.reserveCapacity(nodes.count)

        if !hubIDs.isEmpty {
            let hubRadius: CGFloat = hubIDs.count == 1 ? 0 : 0.08
            for (index, hubID) in hubIDs.enumerated() {
                let angle = (Double(index) / Double(max(1, hubIDs.count))) * .pi * 2.0
                let target = CGPoint(
                    x: center.x + (CGFloat(Foundation.cos(angle)) * hubRadius),
                    y: center.y + (CGFloat(Foundation.sin(angle)) * hubRadius)
                )
                targets[hubID] = clampPoint(target, padding: 0.04)
            }
        }

        var directedActivity: [String: Double] = [:]
        for edge in edgeStates.values {
            let key = "\(edge.key.fromID)|\(edge.key.toID)"
            directedActivity[key, default: 0] += edge.activityEMA
        }

        for (id, node) in nodes {
            if hubIDs.contains(id) {
                continue
            }

            let strength = clamp01(node.avgStrength ?? node.lastConfidence ?? 0.35)
            let desiredRadius = CGFloat(0.15 + ((1.0 - strength) * 0.33))

            var anchorID = hubIDs.first
            var bestWeight = -1.0
            for hubID in hubIDs {
                let forward = directedActivity["\(hubID)|\(id)"] ?? 0
                let reverse = directedActivity["\(id)|\(hubID)"] ?? 0
                let weight = max(forward, reverse)
                if weight > bestWeight {
                    bestWeight = weight
                    anchorID = hubID
                }
            }

            let anchor = anchorID.flatMap { targets[$0] } ?? center
            let baseAngle = stableAngle(for: id)
            var target = CGPoint(
                x: anchor.x + (CGFloat(Foundation.cos(baseAngle)) * desiredRadius),
                y: anchor.y + (CGFloat(Foundation.sin(baseAngle)) * desiredRadius)
            )

            if !node.peerScores.isEmpty {
                var weightedX: CGFloat = 0
                var weightedY: CGFloat = 0
                var totalWeight: CGFloat = 0

                for (peerID, score) in node.peerScores
                    .sorted(by: { $0.value > $1.value })
                    .prefix(6)
                {
                    guard let peerPoint = targets[peerID] ?? nodes[peerID]?.position else { continue }
                    let weight = CGFloat(min(1.0, max(0.08, score)))
                    weightedX += peerPoint.x * weight
                    weightedY += peerPoint.y * weight
                    totalWeight += weight
                }

                if totalWeight > 0 {
                    let peerCenter = CGPoint(x: weightedX / totalWeight, y: weightedY / totalWeight)
                    target.x = (target.x * 0.84) + (peerCenter.x * 0.16)
                    target.y = (target.y * 0.84) + (peerCenter.y * 0.16)
                }
            }

            targets[id] = clampPoint(target, padding: 0.038)
        }

        for edge in edgeStates.values where edge.activityEMA > 0.1 {
            guard var from = targets[edge.key.fromID], var to = targets[edge.key.toID] else { continue }

            let pull = CGFloat(0.011 + (edge.activityEMA * 0.024))
            let dx = to.x - from.x
            let dy = to.y - from.y

            from.x += dx * pull
            from.y += dy * pull
            to.x -= dx * pull
            to.y -= dy * pull

            targets[edge.key.fromID] = clampPoint(from, padding: 0.03)
            targets[edge.key.toID] = clampPoint(to, padding: 0.03)
        }

        let repulsionIDs = nodes.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(320)
            .map(\.id)

        if repulsionIDs.count > 1 {
            for i in 0..<(repulsionIDs.count - 1) {
                for j in (i + 1)..<repulsionIDs.count {
                    let idA = repulsionIDs[i]
                    let idB = repulsionIDs[j]
                    guard var a = targets[idA], var b = targets[idB] else { continue }

                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let distance = sqrt((dx * dx) + (dy * dy))
                    let radiusA = nodes[idA]?.radius ?? 7
                    let radiusB = nodes[idB]?.radius ?? 7
                    let minDistance = 0.028 + ((radiusA + radiusB) / 280.0)
                    guard distance > 0.0001, distance < minDistance else { continue }

                    let push = (minDistance - distance) * 0.44
                    let nx = dx / distance
                    let ny = dy / distance

                    a.x -= nx * push
                    a.y -= ny * push
                    b.x += nx * push
                    b.y += ny * push

                    targets[idA] = clampPoint(a, padding: 0.03)
                    targets[idB] = clampPoint(b, padding: 0.03)
                }
            }
        }

        let attractionBlend = CGFloat(min(0.26, max(0.12, dt * 4.2)))
        for (id, target) in targets {
            guard var node = nodes[id] else { continue }
            node.target.x = (node.target.x * (1 - attractionBlend)) + (target.x * attractionBlend)
            node.target.y = (node.target.y * (1 - attractionBlend)) + (target.y * attractionBlend)

            let dynamicStrength = clamp01(node.avgStrength ?? node.lastConfidence ?? 0.35)
            node.radius = max(5.8, min(13.2, CGFloat(6.2 + (dynamicStrength * 4.8))))
            nodes[id] = node
        }
    }

    private func makeSnapshot(layoutMode: SpectrumLayoutMode) -> SpectrumSnapshot {
        let mappedNodes: [SpectrumNode] = nodes.values.map { node in
            let correlatedPeers = node.peerScores
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map(\.key)

            return SpectrumNode(
                id: node.id,
                position: CGPoint(x: node.position.x, y: node.position.y),
                color: node.color,
                radius: node.radius,
                detail: SpectrumNodeDetail(
                    id: node.id,
                    renderKind: node.renderKind,
                    lastSeen: node.lastSeen,
                    source: node.lastSource,
                    channel: node.lastChannel,
                    rssi: node.lastRSSI,
                    confidence: node.lastConfidence,
                    summary: node.lastSummary,
                    eventData: node.lastEventData,
                    frameData: node.lastFrameData,
                    inboundRatePerSec: node.inboundRatePerSec,
                    outboundRatePerSec: node.outboundRatePerSec,
                    avgStrength: node.avgStrength,
                    avgRSSI: node.avgRSSI,
                    correlatedPeers: correlatedPeers
                )
            )
        }

        let sortedNodes = mappedNodes.sorted { $0.id < $1.id }

        let mappedPulses: [SpectrumPulse]
        let links: [SpectrumLink]

        switch layoutMode {
        case .legacyScatter:
            mappedPulses = scatterPulses.map { pulse in
                SpectrumPulse(
                    position: pulse.position,
                    color: pulse.color,
                    radius: pulse.radius,
                    opacity: 1.0,
                    fromID: "legacy",
                    toID: "legacy",
                    isExplicitTarget: true,
                    direction: .zero
                )
            }

            if sortedNodes.count >= 2 {
                var chainLinks: [SpectrumLink] = []
                for index in 1..<sortedNodes.count {
                    let previous = sortedNodes[index - 1]
                    let current = sortedNodes[index]
                    chainLinks.append(
                        SpectrumLink(
                            fromID: previous.id,
                            toID: current.id,
                            from: previous.position,
                            to: current.position,
                            color: current.color,
                            intensity: 0.35,
                            isExplicitTarget: true,
                            edgeActivity: 0.35,
                            edgeConfidence: 0.35
                        )
                    )
                }
                links = chainLinks
            } else {
                links = []
            }

        case .directionalAggregated, .hybridCorrelation:
            let nodeByID = Dictionary(uniqueKeysWithValues: sortedNodes.map { ($0.id, $0) })

            var directionalLinks: [SpectrumLink] = []
            for edge in edgeStates.values {
                guard let from = nodeByID[edge.key.fromID], let to = nodeByID[edge.key.toID] else { continue }
                let activity = clamp01(edge.activityEMA)
                let confidence = clamp01(edge.confidenceEMA)
                let intensity = clamp01((activity * 0.65) + (confidence * 0.35))

                directionalLinks.append(
                    SpectrumLink(
                        fromID: edge.key.fromID,
                        toID: edge.key.toID,
                        from: from.position,
                        to: to.position,
                        color: edge.color,
                        intensity: intensity,
                        isExplicitTarget: edge.isExplicitTarget,
                        edgeActivity: activity,
                        edgeConfidence: confidence
                    )
                )
            }
            links = directionalLinks.sorted { $0.edgeActivity < $1.edgeActivity }

            mappedPulses = edgePulses.compactMap { pulse in
                guard let from = nodeByID[pulse.edgeKey.fromID], let to = nodeByID[pulse.edgeKey.toID] else { return nil }
                let x = from.position.x + ((to.position.x - from.position.x) * pulse.progress)
                let y = from.position.y + ((to.position.y - from.position.y) * pulse.progress)
                let opacity = max(0.2, min(1.0, pulse.strength * (1 - pulse.progress * 0.55)))
                let radius = pulse.radius * CGFloat(1.0 - pulse.progress * 0.15)
                let direction = CGVector(
                    dx: CGFloat(to.position.x - from.position.x),
                    dy: CGFloat(to.position.y - from.position.y)
                ).normalized
                return SpectrumPulse(
                    position: CGPoint(x: x, y: y),
                    color: pulse.color,
                    radius: max(3.0, radius),
                    opacity: opacity,
                    fromID: pulse.edgeKey.fromID,
                    toID: pulse.edgeKey.toID,
                    isExplicitTarget: pulse.isExplicitTarget,
                    direction: direction
                )
            }
        }

        return SpectrumSnapshot(nodes: sortedNodes, pulses: mappedPulses, links: links)
    }

    private func upsertNode(
        id: String,
        position: CGPoint?,
        color: Color,
        radius: CGFloat,
        renderKind: SignalRenderKind,
        source: String?,
        channel: String?,
        rssi: Double?,
        confidence: Double?,
        summary: String?,
        strengthSample: Double? = nil,
        rssiSample: Double? = nil,
        eventData: [String: JSONValue]? = nil,
        frameData: [String: JSONValue]? = nil,
        now: Date
    ) {
        if var node = nodes[id] {
            if let position {
                node.target = position
            }
            node.color = color
            node.radius = radius
            node.renderKind = renderKind
            node.lastSeen = now
            if let source { node.lastSource = source }
            if let channel { node.lastChannel = channel }
            if let rssi { node.lastRSSI = rssi }
            if let confidence { node.lastConfidence = confidence }
            if let summary, !summary.isEmpty { node.lastSummary = summary }
            if let eventData, !eventData.isEmpty { node.lastEventData = eventData }
            if let frameData, !frameData.isEmpty { node.lastFrameData = frameData }
            if let strengthSample {
                let clamped = clamp01(strengthSample)
                node.avgStrength = ema(current: node.avgStrength ?? clamped, new: clamped, alpha: 0.24)
            }
            if let rssiSample {
                node.avgRSSI = ema(current: node.avgRSSI ?? rssiSample, new: rssiSample, alpha: 0.19)
            }
            nodes[id] = node
            return
        }

        let seeded = position ?? seededPosition(for: id)
        nodes[id] = NodeState(
            id: id,
            position: seeded,
            target: seeded,
            velocity: .zero,
            color: color,
            radius: radius,
            lastSeen: now,
            renderKind: renderKind,
            lastSource: source,
            lastChannel: channel,
            lastRSSI: rssi,
            lastConfidence: confidence,
            lastSummary: summary,
            lastEventData: eventData ?? [:],
            lastFrameData: frameData ?? [:],
            avgRSSI: rssiSample,
            avgStrength: strengthSample.map(clamp01),
            inboundRatePerSec: 0,
            outboundRatePerSec: 0,
            peerScores: [:]
        )
    }

    private func recordEdge(
        fromID: String,
        toID: String,
        renderKind: SignalRenderKind,
        color: Color,
        confidence: Double,
        strength: Double,
        rssi: Double?,
        isExplicitTarget: Bool,
        now: Date
    ) {
        guard fromID != toID else { return }

        let confidenceValue = clamp01(confidence)
        let strengthValue = clamp01(strength)
        let activitySample = clamp01((confidenceValue * 0.55) + (strengthValue * 0.45))

        let key = EdgeKey(fromID: fromID, toID: toID, renderKind: renderKind)
        if var edge = edgeStates[key] {
            edge.lastSeen = now
            edge.color = color
            edge.activityEMA = ema(current: edge.activityEMA, new: activitySample, alpha: 0.28)
            edge.confidenceEMA = ema(current: edge.confidenceEMA, new: confidenceValue, alpha: 0.24)
            edge.strengthEMA = ema(current: edge.strengthEMA, new: strengthValue, alpha: 0.24)
            edge.isExplicitTarget = edge.isExplicitTarget || isExplicitTarget
            edgeStates[key] = edge
        } else {
            edgeStates[key] = EdgeState(
                key: key,
                color: color,
                activityEMA: max(0.08, activitySample),
                confidenceEMA: max(0.08, confidenceValue),
                strengthEMA: max(0.1, strengthValue),
                lastSeen: now,
                lastEmit: nil,
                isExplicitTarget: isExplicitTarget
            )
        }

        let flowWeight = 0.6 + (activitySample * 2.8)

        if var fromNode = nodes[fromID] {
            fromNode.outboundRatePerSec += flowWeight
            fromNode.avgStrength = ema(current: fromNode.avgStrength ?? strengthValue, new: strengthValue, alpha: 0.12)
            fromNode.peerScores[toID, default: 0] += activitySample
            nodes[fromID] = fromNode
        }

        if var toNode = nodes[toID] {
            toNode.inboundRatePerSec += flowWeight
            toNode.avgStrength = ema(current: toNode.avgStrength ?? strengthValue, new: strengthValue, alpha: 0.14)
            if let rssi {
                toNode.avgRSSI = ema(current: toNode.avgRSSI ?? rssi, new: rssi, alpha: 0.18)
            }
            toNode.peerScores[fromID, default: 0] += activitySample
            nodes[toID] = toNode
        }
    }

    private func explicitTargetID(from event: NormalizedEvent) -> String? {
        let keys = [
            "target_id", "targetId", "target", "target_node", "targetNode", "to",
            "device_id", "deviceId", "device", "mac", "mac_address", "bssid", "ble_addr"
        ]

        let renderKind = SignalRenderKind.from(event: event)
        for key in keys {
            guard let raw = event.data[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            return normalizeTargetID(raw, key: key, renderKind: renderKind)
        }

        return nil
    }

    private func eventConfidence(_ event: NormalizedEvent) -> Double {
        if let value = event.data["confidence"]?.doubleValue {
            if value > 1.0 { return clamp01(value / 100.0) }
            return clamp01(value)
        }

        if let value = event.data["score"]?.doubleValue {
            if value > 1.0 { return clamp01(value / 100.0) }
            return clamp01(value)
        }

        if let rssi = event.signal.strength {
            return clamp01((rssi + 95.0) / 45.0)
        }

        return 0.55
    }

    private func normalizedStrength(rssi: Double?, confidence: Double?, inferredHint: Bool = false) -> (value: Double, inferred: Bool) {
        if !inferredHint, let rssi {
            let normalized = clamp01((rssi + 95.0) / 45.0)
            return (value: normalized, inferred: false)
        }

        if let confidence {
            let resolved = confidence > 1.0 ? confidence / 100.0 : confidence
            return (value: clamp01(resolved), inferred: true)
        }

        return (value: 0.35, inferred: true)
    }

    private func frameData(from frame: SignalFrame) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "t": .number(Double(frame.t)),
            "source": .string(frame.source),
            "node_id": .string(frame.nodeID),
            "device_id": .string(frame.deviceID),
            "channel": .number(Double(frame.channel)),
            "frequency": .number(Double(frame.frequency)),
            "rssi": .number(frame.rssi),
            "confidence": .number(frame.confidence),
            "persistence": .number(frame.persistence),
            "color": .object([
                "h": .number(frame.color.h),
                "s": .number(frame.color.s),
                "l": .number(frame.color.l)
            ])
        ]

        if let inferred = frame.strengthInferred {
            payload["strength_inferred"] = .bool(inferred)
        }

        if let x = frame.x {
            payload["x"] = .number(x)
        }
        if let y = frame.y {
            payload["y"] = .number(y)
        }
        if let z = frame.z {
            payload["z"] = .number(z)
        }
        if let glow = frame.glow {
            payload["glow"] = .number(glow)
        }
        if let velocity = frame.velocity {
            payload["velocity"] = .number(velocity)
        }

        return payload
    }

    private func normalizeNodeID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "node:unknown" }
        if trimmed.hasPrefix("node:") { return trimmed }
        return "node:\(trimmed)"
    }

    private func normalizeTargetID(_ rawValue: String, key: String?, renderKind: SignalRenderKind) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "unknown" }

        if value.hasPrefix("node:") || value.hasPrefix("ble:") || value.hasPrefix("host:") || value.hasPrefix("onvif:") {
            return value
        }

        let lowerKey = key?.lowercased() ?? ""

        if lowerKey.contains("node") {
            return "node:\(value)"
        }

        if lowerKey == "ble_addr" || renderKind == .ble {
            return value.hasPrefix("ble:") ? value : "ble:\(value)"
        }

        if value.isLikelyIPv4 {
            return "host:\(value)"
        }

        if ["target", "to", "target_id", "targetid", "target_node", "targetnode"].contains(lowerKey), !value.contains(":") {
            return "node:\(value)"
        }

        return value
    }

    private func seededPosition(for id: String) -> CGPoint {
        let seed = abs(id.hashValue)
        let px = CGFloat(seed % 100) / 100.0
        let py = CGFloat((seed / 100) % 100) / 100.0
        return CGPoint(x: min(0.94, max(0.06, px)), y: min(0.94, max(0.06, py)))
    }

    private func randomVelocity(scale: CGFloat) -> CGVector {
        let x = CGFloat.random(in: -scale...scale)
        let y = CGFloat.random(in: -scale...scale)
        return CGVector(dx: x, dy: y)
    }

    private func stableAngle(for id: String) -> Double {
        SignalColor.stableHue(for: id) * .pi * 2.0
    }

    private func ema(current: Double, new sample: Double, alpha: Double) -> Double {
        current + ((sample - current) * alpha)
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private func clampPoint(_ point: CGPoint, padding: CGFloat) -> CGPoint {
        CGPoint(
            x: min(1 - padding, max(padding, point.x)),
            y: min(1 - padding, max(padding, point.y))
        )
    }
}

private struct SpectrumSnapshot {
    let nodes: [SpectrumNode]
    let pulses: [SpectrumPulse]
    let links: [SpectrumLink]
}

private struct SpectrumNode {
    let id: String
    let position: CGPoint
    let color: Color
    let radius: CGFloat
    let detail: SpectrumNodeDetail
}

private struct SpectrumPulse {
    let position: CGPoint
    let color: Color
    let radius: CGFloat
    let opacity: Double
    let fromID: String
    let toID: String
    let isExplicitTarget: Bool
    let direction: CGVector
}

private struct SpectrumLink {
    let fromID: String
    let toID: String
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let intensity: Double
    let isExplicitTarget: Bool
    let edgeActivity: Double
    let edgeConfidence: Double
}

private struct FocusContext {
    let focusNodeID: String?
    let highlightedNodeIDs: Set<String>
    let secondaryNodeIDs: Set<String>

    func nodeOpacityMultiplier(for id: String) -> Double {
        guard let focusNodeID else { return 1.0 }
        if id == focusNodeID { return 1.0 }
        if highlightedNodeIDs.contains(id) { return 0.96 }
        if secondaryNodeIDs.contains(id) { return 0.62 }
        return 0.28
    }

    func linkOpacityMultiplier(fromID: String, toID: String) -> Double {
        guard let focusNodeID else { return 1.0 }
        if fromID == focusNodeID || toID == focusNodeID {
            return 1.0
        }
        if highlightedNodeIDs.contains(fromID) && highlightedNodeIDs.contains(toID) {
            return 0.78
        }
        if secondaryNodeIDs.contains(fromID) || secondaryNodeIDs.contains(toID) {
            return 0.46
        }
        return 0.22
    }
}

private extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return sqrt((dx * dx) + (dy * dy))
    }
}

private extension CGVector {
    var normalized: CGVector {
        let magnitude = sqrt((dx * dx) + (dy * dy))
        guard magnitude > 0.00001 else {
            return .zero
        }
        return CGVector(dx: dx / magnitude, dy: dy / magnitude)
    }
}

private extension String {
    var isLikelyIPv4: Bool {
        let parts = split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
        }
        return true
    }
}
