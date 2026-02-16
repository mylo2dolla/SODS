import SwiftUI
import ScannerSpectrumCore

struct ScannerView: View {
    @EnvironmentObject private var coordinator: IOSScanCoordinator
    @State private var selectedPane: ScannerPane = .ble
    @State private var selectedNodeDetail: SpectrumNodeDetail?
    @State private var showBLEPermissionExplainer = false
    @State private var showLANPermissionExplainer = false
    @AppStorage("SODSScanneriOS.permissions.explainer.ble")
    private var didShowBLEPermissionExplainer = false
    @AppStorage("SODSScanneriOS.permissions.explainer.lan")
    private var didShowLANPermissionExplainer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scannerControls
                    switch selectedPane {
                    case .ble:
                        blePane
                    case .lan:
                        lanPane
                    }
                }
                .padding(16)
            }
            .navigationTitle("Scanner")
            .sheet(item: $selectedNodeDetail) { detail in
                DeviceInfoSheet(detail: detail)
            }
            .alert("Bluetooth Access Needed", isPresented: $showBLEPermissionExplainer) {
                Button("Continue") {
                    didShowBLEPermissionExplainer = true
                    startBLEToggle()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("BLE scanning requires Bluetooth permission. iOS will prompt when scanning starts.")
            }
            .alert("Local Network Access Needed", isPresented: $showLANPermissionExplainer) {
                Button("Continue") {
                    didShowLANPermissionExplainer = true
                    startLANToggle()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("LAN scanning requires Local Network permission. iOS will prompt when scanning starts.")
            }
        }
    }

    private enum ScannerPane: String, CaseIterable, Identifiable {
        case ble = "BLE"
        case lan = "LAN"

        var id: String { rawValue }
    }

    private var scannerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Controls")
                .font(.headline)

            Picker("Scanner View", selection: $selectedPane) {
                ForEach(ScannerPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $coordinator.scanMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(coordinator.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var blePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(coordinator.bleIsScanning ? "Stop BLE" : "Start BLE") {
                if coordinator.bleIsScanning {
                    coordinator.stopBLE()
                } else if didShowBLEPermissionExplainer {
                    startBLEToggle()
                } else {
                    showBLEPermissionExplainer = true
                }
            }
            .buttonStyle(.borderedProminent)

            bleListSection
        }
    }

    private var lanPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(coordinator.lanIsScanning ? "Stop LAN" : "Start LAN") {
                    if coordinator.lanIsScanning {
                        coordinator.stopLAN()
                    } else if didShowLANPermissionExplainer {
                        startLANToggle()
                    } else {
                        showLANPermissionExplainer = true
                    }
                }
                .buttonStyle(.borderedProminent)

                Toggle("Alive only", isOn: $coordinator.lanAliveOnly)
                    .toggleStyle(.switch)
            }

            lanHostsSection
        }
    }

    private var bleListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLE Devices (\(coordinator.blePeripherals.count))")
                .font(.headline)

            if coordinator.blePeripherals.isEmpty {
                Text("No BLE devices yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.blePeripherals.prefix(50)) { peripheral in
                    Button {
                        selectedNodeDetail = bleDetail(for: peripheral)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? peripheral.id.uuidString)
                                    .font(.subheadline)
                                Text("RSSI \(peripheral.rssi) • \(peripheral.bleConfidence.level.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var lanHostsSection: some View {
        let visibleHosts = coordinator.lanVisibleHosts
        let totalHosts = coordinator.hosts.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("LAN Hosts (\(visibleHosts.count)/\(totalHosts))")
                .font(.headline)

            if totalHosts == 0 {
                Text("No LAN hosts yet.")
                    .foregroundStyle(.secondary)
            } else if visibleHosts.isEmpty {
                Text("No alive LAN hosts right now. Turn off \"Alive only\" to show all hosts.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleHosts.prefix(120), id: \.id) { host in
                    Button {
                        selectedNodeDetail = hostDetail(for: host)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host.ip)
                                    .font(.subheadline.monospaced())
                                Text(host.vendor ?? "Unknown vendor")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(host.isAlive ? "Alive" : "No response")
                                .font(.caption)
                                .foregroundStyle(host.isAlive ? .green : .secondary)
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func bleDetail(for peripheral: BLEPeripheral) -> SpectrumNodeDetail {
        let confidence = Double(peripheral.bleConfidence.score) / 100.0
        let eventData: [String: JSONValue] = [
            "device_id": .string("ble:\(peripheral.id.uuidString)"),
            "name": .string(peripheral.name ?? ""),
            "rssi": .number(Double(peripheral.rssi)),
            "company": .string(peripheral.fingerprint.manufacturerCompanyName ?? ""),
            "services_count": .number(Double(peripheral.fingerprint.servicesDecoded.count))
        ]

        let frameData: [String: JSONValue] = [
            "source": .string("ble.scan"),
            "device_id": .string("ble:\(peripheral.id.uuidString)"),
            "channel": .string(peripheral.fingerprint.serviceUUIDs.first ?? "0"),
            "rssi": .number(Double(peripheral.rssi)),
            "confidence": .number(confidence)
        ]

        return SpectrumNodeDetail(
            id: "ble:\(peripheral.id.uuidString)",
            renderKind: .ble,
            lastSeen: peripheral.lastSeen,
            source: "ble.scan",
            channel: peripheral.fingerprint.serviceUUIDs.first,
            rssi: Double(peripheral.rssi),
            confidence: confidence,
            summary: peripheral.name ?? peripheral.fingerprint.manufacturerCompanyName,
            eventData: eventData,
            frameData: frameData
        )
    }

    private func hostDetail(for host: HostEntry) -> SpectrumNodeDetail {
        let confidence = Double(max(host.hostConfidence.score, host.vendorConfidenceScore)) / 100.0
        let eventData: [String: JSONValue] = [
            "device_id": .string("host:\(host.ip)"),
            "ip": .string(host.ip),
            "vendor": .string(host.vendor ?? ""),
            "is_alive": .bool(host.isAlive),
            "open_ports": .array(host.openPorts.map { .number(Double($0)) })
        ]

        let frameData: [String: JSONValue] = [
            "source": .string("lan.scan"),
            "device_id": .string("host:\(host.ip)"),
            "channel": .string(host.openPorts.contains(443) ? "5" : "2"),
            "rssi": .number(host.openPorts.contains(554) ? -48 : -58),
            "confidence": .number(confidence)
        ]

        return SpectrumNodeDetail(
            id: "host:\(host.ip)",
            renderKind: .wifi,
            lastSeen: host.provenance?.timestamp ?? Date(),
            source: "lan.scan",
            channel: host.openPorts.contains(443) ? "5" : "2",
            rssi: nil,
            confidence: confidence,
            summary: host.hostname ?? host.ip,
            eventData: eventData,
            frameData: frameData
        )
    }

    private func startBLEToggle() {
        coordinator.startBLE()
    }

    private func startLANToggle() {
        coordinator.startLAN()
    }
}
