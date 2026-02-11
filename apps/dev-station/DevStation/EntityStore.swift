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
        blePeripherals = items.sorted { $0.lastSeen > $1.lastSeen }
        for peripheral in items {
            let label = IdentityResolver.bleDisplayLabel(for: peripheral)
            recordObservation(kind: .ble, id: peripheral.fingerprintID, label: label, meta: [
                "fingerprint": peripheral.fingerprintID,
                "company": peripheral.fingerprint.manufacturerCompanyName ?? "",
                "beacon": peripheral.fingerprint.beaconHint ?? ""
            ])
        }
        IdentityResolver.shared.updateFromBLE(items)
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
}
