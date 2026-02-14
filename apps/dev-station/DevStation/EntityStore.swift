import Foundation

enum ObservationKind: String, Codable {
    case host
    case device
    case ble
    case node
    case camera
}

struct Observation: Identifiable, Hashable {
    let id = UUID()
    let kind: ObservationKind
    let entityID: String
    let label: String
    let timestamp: Date
    let meta: [String: String]
}

@MainActor
final class EntityStore: ObservableObject {
    static let shared = EntityStore()

    @Published private(set) var hosts: [HostEntry] = []
    @Published private(set) var devices: [Device] = []
    @Published private(set) var blePeripherals: [BLEPeripheral] = []
    @Published private(set) var nodes: [NodeRecord] = []
    @Published private(set) var cameras: [Device] = []
    @Published private(set) var observations: [Observation] = []
    @Published private(set) var lastObservationAt: Date?
    @Published var selectedEntityID: String?
    @Published var selectedEntityKind: ObservationKind?

    private let maxObservations = 800
    private var lastBLEParityLogAt: Date?
    private let bleParityLogInterval: TimeInterval = 10
    private var lastBLEObservationAtByFingerprint: [String: Date] = [:]
    private let bleObservationInterval: TimeInterval = 2

    private init() {}

    func select(id: String?, kind: ObservationKind?) {
        selectedEntityID = id
        selectedEntityKind = kind
    }

    func ingestHosts(_ items: [HostEntry]) {
        hosts = items.sorted { $0.ipNumeric < $1.ipNumeric }
        for host in items {
            let label = host.hostname ?? host.vendor ?? host.ip
            recordObservation(kind: .host, id: host.ip, label: label, meta: [
                "ip": host.ip,
                "mac": host.macAddress ?? "",
                "hostname": host.hostname ?? ""
            ])
        }
        IdentityResolver.shared.updateFromHosts(items)
    }

    func ingestDevices(_ items: [Device]) {
        devices = items.sorted { $0.ip < $1.ip }
        cameras = items.filter { $0.isCameraLikely }
        for device in items {
            let label = device.httpTitle ?? device.vendor ?? device.ip
            recordObservation(kind: .device, id: device.ip, label: label, meta: [
                "ip": device.ip,
                "mac": device.macAddress ?? "",
                "vendor": device.vendor ?? ""
            ])
        }
        IdentityResolver.shared.updateFromDevices(items)
    }

    func ingestBLE(_ items: [BLEPeripheral]) {
        let now = Date()
        blePeripherals = items.sorted { $0.lastSeen > $1.lastSeen }
        for peripheral in items {
            let fingerprintID = peripheral.fingerprintID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fingerprintID.isEmpty else { continue }
            guard shouldRecordBLEObservation(for: fingerprintID, now: now) else { continue }
            let label = IdentityResolver.bleDisplayLabel(for: peripheral)
            recordObservation(kind: .ble, id: fingerprintID, label: label, meta: [
                "fingerprint": fingerprintID,
                "company": peripheral.fingerprint.manufacturerCompanyName ?? "",
                "beacon": peripheral.fingerprint.beaconHint ?? ""
            ])
            lastBLEObservationAtByFingerprint[fingerprintID] = now
        }
        let liveFingerprints = Set(items.map { $0.fingerprintID.trimmingCharacters(in: .whitespacesAndNewlines) })
        lastBLEObservationAtByFingerprint = lastBLEObservationAtByFingerprint.filter { liveFingerprints.contains($0.key) }
        IdentityResolver.shared.updateFromBLE(items)
        logBLEParityIfNeeded(inputCount: items.count)
    }

    func ingestNodes(_ items: [NodeRecord]) {
        nodes = items.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        for node in items {
            recordObservation(kind: .node, id: node.id, label: node.label, meta: [
                "type": node.type.rawValue,
                "caps": node.capabilities.joined(separator: ",")
            ])
        }
        IdentityResolver.shared.updateFromNodes(items)
    }

    private func recordObservation(kind: ObservationKind, id: String, label: String, meta: [String: String]) {
        guard !id.isEmpty else { return }
        let obs = Observation(kind: kind, entityID: id, label: label, timestamp: Date(), meta: meta)
        observations.append(obs)
        if observations.count > maxObservations {
            observations.removeFirst(observations.count - maxObservations)
        }
        lastObservationAt = obs.timestamp
    }

    private func logBLEParityIfNeeded(inputCount: Int) {
        let now = Date()
        if let last = lastBLEParityLogAt, now.timeIntervalSince(last) < bleParityLogInterval {
            return
        }
        lastBLEParityLogAt = now
        let distinctUUIDs = Set(blePeripherals.map { $0.id.uuidString }).count
        let distinctFingerprints = Set(blePeripherals.map { $0.fingerprintID }).count
        let uuidSamples = sampleUUIDSuffixes(from: blePeripherals.map { $0.id.uuidString })
        LogStore.shared.log(
            .info,
            "BLE entity parity: input=\(inputCount) stored=\(blePeripherals.count) distinct_uuids=\(distinctUUIDs) distinct_fingerprints=\(distinctFingerprints) uuid_samples=\(uuidSamples)"
        )
    }

    private func sampleUUIDSuffixes(from uuids: [String]) -> String {
        let suffixes = uuids
            .sorted()
            .prefix(5)
            .map { uuid in
                String(uuid.suffix(6))
            }
        if suffixes.isEmpty {
            return "-"
        }
        return suffixes.joined(separator: ",")
    }

    private func shouldRecordBLEObservation(for fingerprintID: String, now: Date) -> Bool {
        guard let last = lastBLEObservationAtByFingerprint[fingerprintID] else { return true }
        return now.timeIntervalSince(last) >= bleObservationInterval
    }
}
