import Foundation

@MainActor
final class IdentityResolver: ObservableObject {
    static let shared = IdentityResolver()

    private var labels: [String: String] = [:]
    private var overrides: [String: String] = [:]

    private init() {}

    func updateOverrides(_ map: [String: String]) {
        overrides = map
    }

    func record(keys: [String], label: String?) {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if overrides[trimmed] != nil { continue }
            labels[trimmed] = label
        }
    }

    func resolveLabel(keys: [String]) -> String? {
        for key in keys {
            if let override = overrides[key], !override.isEmpty {
                return override
            }
        }
        for key in keys {
            if let label = labels[key], !label.isEmpty {
                return label
            }
        }
        return nil
    }

    func aliasMap() -> [String: String] {
        var merged = labels
        for (key, value) in overrides {
            merged[key] = value
        }
        return merged
    }

    func updateFromHosts(_ hosts: [HostEntry]) {
        for host in hosts {
            let label = host.hostname ?? host.vendor ?? host.ip
            record(keys: [host.ip, host.hostname ?? "", host.macAddress ?? ""], label: label)
        }
    }

    func updateFromDevices(_ devices: [Device]) {
        for device in devices {
            let label = device.httpTitle ?? device.vendor ?? device.ip
            record(keys: [device.ip, device.macAddress ?? ""], label: label)
        }
    }

    func updateFromBLE(_ peripherals: [BLEPeripheral]) {
        for peripheral in peripherals {
            let label = peripheral.name ?? peripheral.fingerprintID
            record(keys: [peripheral.fingerprintID, peripheral.id.uuidString], label: label)
        }
    }

    func updateFromNodes(_ nodes: [NodeRecord]) {
        for node in nodes {
            record(keys: [node.id, "node:\(node.id)"], label: node.label)
        }
    }

    func updateFromSignals(_ signals: [SignalNode]) {
        for node in signals {
            let label = node.hostname ?? node.ip ?? node.id
            record(keys: [node.id, node.hostname ?? "", node.ip ?? ""], label: label)
        }
    }
}
