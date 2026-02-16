import Foundation
import SwiftUI
import ScannerSpectrumCore

struct SpectrumView: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    @AppStorage("SODSScanneriOS.spectrum.selectedKinds")
    private var persistedKindsRaw = "__default__"

    @State private var selectedKinds: Set<SignalRenderKind> = Set(SignalRenderKind.allCases)
    @State private var selectedNodeDetail: SpectrumNodeDetail?
    @State private var didLoadPersistedKinds = false
    @State private var showUpgradeSheet = false

    @State private var showCorrelationLinks = true
    @State private var showInferredLinks = true
    @State private var showStrengthRingOverlay = true
    @State private var strongOnly = false
    @State private var recentOnly = false
    @State private var focusedNodeID: String?

    private let recentWindowSeconds: TimeInterval = 20

    private var hasSpectrumAccess: Bool {
        subscriptionManager.canUse(.spectrum)
    }

    private var recencyCutoff: Date {
        Date().addingTimeInterval(-recentWindowSeconds)
    }

    private var filteredEvents: [NormalizedEvent] {
        coordinator.normalizedEvents.filter { event in
            let kind = SignalRenderKind.from(event: event)
            guard selectedKinds.contains(kind) else {
                return false
            }
            if strongOnly, eventStrength(event) < 0.55 {
                return false
            }
            if recentOnly {
                let ts = event.eventTs ?? event.recvTs ?? .distantPast
                if ts < recencyCutoff {
                    return false
                }
            }
            return true
        }
    }

    private var filteredFrames: [SignalFrame] {
        coordinator.signalFrames.filter { frame in
            let kind = SignalRenderKind.from(source: frame.source)
            guard selectedKinds.contains(kind) else {
                return false
            }
            if strongOnly, frameStrength(frame) < 0.55 {
                return false
            }
            if recentOnly {
                let ts = Date(timeIntervalSince1970: Double(frame.t) / 1000.0)
                if ts < recencyCutoff {
                    return false
                }
            }
            return true
        }
    }

    private var eventCountByKind: [SignalRenderKind: Int] {
        coordinator.normalizedEvents.reduce(into: [SignalRenderKind: Int]()) { partial, event in
            partial[SignalRenderKind.from(event: event), default: 0] += 1
        }
    }

    private var frameCountByKind: [SignalRenderKind: Int] {
        coordinator.signalFrames.reduce(into: [SignalRenderKind: Int]()) { partial, frame in
            partial[SignalRenderKind.from(source: frame.source), default: 0] += 1
        }
    }

    private var displayOptions: SpectrumDisplayOptions {
        SpectrumDisplayOptions(
            showCorrelationLinks: showCorrelationLinks,
            showInferredLinks: showInferredLinks,
            showStrengthRingOverlay: showStrengthRingOverlay,
            focusNodeID: focusedNodeID
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                filterStrip
                    .allowsHitTesting(hasSpectrumAccess)
                    .opacity(hasSpectrumAccess ? 1.0 : 0.66)

                correlationControls
                    .allowsHitTesting(hasSpectrumAccess)
                    .opacity(hasSpectrumAccess ? 1.0 : 0.66)

                SpectrumFieldView(
                    events: filteredEvents,
                    frames: filteredFrames,
                    layoutMode: .hybridCorrelation,
                    displayOptions: displayOptions,
                    onNodeTap: hasSpectrumAccess ? { detail in
                        focusedNodeID = detail.id
                        selectedNodeDetail = detail
                    } : nil
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .center) {
                    if !hasSpectrumAccess {
                        spectrumLockOverlay
                    }
                }

                if selectedKinds.isEmpty {
                    Text("All signal types are filtered out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let focusedNodeID {
                    HStack(spacing: 8) {
                        Text("Focused: \(focusedNodeID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Clear Focus") {
                            self.focusedNodeID = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                legendAndSemantics
                    .opacity(hasSpectrumAccess ? 1.0 : 0.72)
            }
            .padding(16)
            .navigationTitle("Spectrum")
            .sheet(item: $selectedNodeDetail) { detail in
                DeviceInfoSheet(detail: detail)
            }
            .sheet(isPresented: $showUpgradeSheet) {
                UpgradeView()
                    .environmentObject(subscriptionManager)
            }
            .onAppear {
                loadPersistedKindsIfNeeded()
            }
            .onChange(of: selectedKinds) {
                persistSelectedKinds()
            }
        }
    }

    private var spectrumLockOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.white)
            Text("Spectrum Pro")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Upgrade to unlock hybrid correlation layout, directional aggregated pulses, type filters, and tap-to-inspect node details.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Upgrade to Pro") {
                showUpgradeSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
    }

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Type Filters")
                    .font(.headline)
                Spacer()
                Text("Events \(filteredEvents.count) • Frames \(filteredFrames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    Button("All") {
                        selectedKinds = Set(SignalRenderKind.allCases)
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        selectedKinds.removeAll()
                    }
                    .buttonStyle(.bordered)

                    ForEach(SignalRenderKind.allCases, id: \.self) { kind in
                        Button {
                            if selectedKinds.contains(kind) {
                                selectedKinds.remove(kind)
                            } else {
                                selectedKinds.insert(kind)
                            }
                        } label: {
                            Text("\(kind.label) \(kindCount(kind))")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(selectedKinds.contains(kind) ? Color.red : Color.primary)
                                .background(
                                    Capsule()
                                        .fill(selectedKinds.contains(kind) ? Color.red.opacity(0.16) : Color(.tertiarySystemBackground))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(selectedKinds.contains(kind) ? Color.red.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                toggleChip(title: "Strong only", isOn: $strongOnly)
                toggleChip(title: "Recent only", isOn: $recentOnly)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var correlationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Correlation Controls")
                .font(.headline)

            HStack(spacing: 8) {
                toggleChip(title: "Correlation links", isOn: $showCorrelationLinks)
                toggleChip(title: "Inferred links", isOn: $showInferredLinks)
                toggleChip(title: "Strength rings", isOn: $showStrengthRingOverlay)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var legendAndSemantics: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                legendItem(title: "BLE", kind: .ble)
                legendItem(title: "Wi-Fi/LAN", kind: .wifi)
                legendItem(title: "Node", kind: .node)
                legendItem(title: "Action", kind: .tool)
                legendItem(title: "Error", kind: .error)
            }
            .font(.caption)

            Text("Hue = signal type • Distance = relative strength • Line width / pulse density = activity • Solid = explicit target • Dashed = inferred correlation")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func toggleChip(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isOn.wrappedValue ? Color.red : Color.primary)
                .background(
                    Capsule()
                        .fill(isOn.wrappedValue ? Color.red.opacity(0.16) : Color(.tertiarySystemBackground))
                )
                .overlay(
                    Capsule()
                        .stroke(isOn.wrappedValue ? Color.red.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func kindCount(_ kind: SignalRenderKind) -> Int {
        eventCountByKind[kind, default: 0] + frameCountByKind[kind, default: 0]
    }

    private func loadPersistedKindsIfNeeded() {
        guard !didLoadPersistedKinds else { return }
        didLoadPersistedKinds = true

        if persistedKindsRaw == "__default__" {
            selectedKinds = Set(SignalRenderKind.allCases)
            return
        }

        if persistedKindsRaw == "__empty__" {
            selectedKinds = []
            return
        }

        let decoded = Set(
            persistedKindsRaw
                .split(separator: ",")
                .compactMap { SignalRenderKind(rawValue: String($0)) }
        )

        selectedKinds = decoded
    }

    private func persistSelectedKinds() {
        if selectedKinds.isEmpty {
            persistedKindsRaw = "__empty__"
            return
        }

        let encoded = selectedKinds
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        persistedKindsRaw = encoded
    }

    private func eventStrength(_ event: NormalizedEvent) -> Double {
        if let strength = event.signal.strength {
            return max(0.0, min(1.0, (strength + 95.0) / 45.0))
        }

        if let confidence = event.data["confidence"]?.doubleValue {
            return max(0.0, min(1.0, confidence > 1 ? confidence / 100.0 : confidence))
        }

        if let score = event.data["score"]?.doubleValue {
            return max(0.0, min(1.0, score > 1 ? score / 100.0 : score))
        }

        return 0.35
    }

    private func frameStrength(_ frame: SignalFrame) -> Double {
        if frame.strengthInferred == true {
            return max(0.0, min(1.0, frame.confidence))
        }
        return max(0.0, min(1.0, (frame.rssi + 95.0) / 45.0))
    }

    private func legendItem(title: String, kind: SignalRenderKind) -> some View {
        let color = PlatformColorSupport.swiftUIColor(
            SignalColor.typeFirstColor(renderKind: kind, deviceID: "legend-\(kind.rawValue)")
        )
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }
}
