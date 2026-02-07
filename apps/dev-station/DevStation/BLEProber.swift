import Foundation
import CoreBluetooth

@MainActor
final class BLEProber: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BLEProber()

    struct ProbeStatus: Hashable {
        var inProgress: Bool
        var status: String
        var lastError: String?
        var lastUpdated: Date?
    }

    @Published private(set) var statuses: [String: ProbeStatus] = [:]
    @Published private(set) var results: [String: BLEProbeResult] = [:]

    private let logStore = LogStore.shared
    private var central: CBCentralManager!
    private var activeContext: ProbeContext?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func canProbe(fingerprintID: String) -> Bool {
        return activeContext == nil
    }

    func startProbe(peripheralInfo: BLEPeripheral) {
        let fingerprintID = peripheralInfo.fingerprintID
        guard peripheralInfo.fingerprint.isConnectable == true else {
            logStore.log(.warn, "BLE probe blocked (not connectable) id=\(fingerprintID)")
            updateStatus(fingerprintID: fingerprintID, status: "Not connectable", error: "Peripheral is not connectable.")
            return
        }
        guard activeContext == nil else {
            logStore.log(.warn, "BLE probe blocked (busy) id=\(fingerprintID)")
            updateStatus(fingerprintID: fingerprintID, status: "Busy", error: "Another probe is in progress.")
            return
        }

        let peripherals = central.retrievePeripherals(withIdentifiers: [peripheralInfo.id])
        guard let peripheral = peripherals.first else {
            logStore.log(.warn, "BLE probe failed to retrieve peripheral id=\(fingerprintID)")
            updateStatus(fingerprintID: fingerprintID, status: "Not available", error: "Peripheral not available.")
            return
        }

        let context = ProbeContext(
            fingerprintID: fingerprintID,
            peripheralID: peripheralInfo.id,
            name: peripheralInfo.name,
            peripheral: peripheral
        )
        activeContext = context
        peripheral.delegate = self
        updateStatus(fingerprintID: fingerprintID, status: "Connecting...", error: nil, inProgress: true)
        logStore.log(.info, "BLE probe connect start id=\(fingerprintID)")
        central.connect(peripheral, options: nil)
    }

    func stopProbe() {
        guard let context = activeContext else { return }
        logStore.log(.info, "BLE probe cancel id=\(context.fingerprintID)")
        central.cancelPeripheralConnection(context.peripheral)
        finishProbe(success: false, error: "Probe cancelled.")
    }

    func snapshotProbeResults() -> [BLEProbeResult] {
        Array(results.values)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            if let context = activeContext {
                logStore.log(.warn, "BLE probe stopped (Bluetooth not powered on) id=\(context.fingerprintID)")
                finishProbe(success: false, error: "Bluetooth not powered on.")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        logStore.log(.info, "BLE probe connected id=\(context.fingerprintID)")
        updateStatus(fingerprintID: context.fingerprintID, status: "Discovering services...", error: nil, inProgress: true)
        let serviceUUIDs = [CBUUID(string: "180A"), CBUUID(string: "180F"), CBUUID(string: "1800")]
        peripheral.discoverServices(serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        let message = error?.localizedDescription ?? "Failed to connect."
        logStore.log(.warn, "BLE probe connect failed id=\(context.fingerprintID) error=\(message)")
        finishProbe(success: false, error: message)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        if context.isComplete {
            logStore.log(.info, "BLE probe disconnected id=\(context.fingerprintID)")
        } else {
            let message = error?.localizedDescription ?? "Disconnected."
            logStore.log(.warn, "BLE probe disconnected before completion id=\(context.fingerprintID) error=\(message)")
            finishProbe(success: false, error: message)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        if let error {
            logStore.log(.warn, "BLE probe discover services failed id=\(context.fingerprintID) error=\(error.localizedDescription)")
            finishProbe(success: false, error: error.localizedDescription)
            return
        }
        let services = peripheral.services ?? []
        context.discoveredServices = services.map { $0.uuid.uuidString }
        updateStatus(fingerprintID: context.fingerprintID, status: "Discovering characteristics...", error: nil, inProgress: true)
        logStore.log(.info, "BLE probe services discovered id=\(context.fingerprintID) count=\(services.count)")

        for service in services {
            let charUUIDs = targetCharacteristicUUIDs(for: service.uuid)
            if !charUUIDs.isEmpty {
                peripheral.discoverCharacteristics(charUUIDs, for: service)
            }
        }
        checkCompletionIfIdle()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        if let error {
            logStore.log(.warn, "BLE probe discover characteristics failed id=\(context.fingerprintID) error=\(error.localizedDescription)")
            finishProbe(success: false, error: error.localizedDescription)
            return
        }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics where characteristic.properties.contains(.read) {
            if isTargetCharacteristic(characteristic.uuid) {
                context.pendingReads += 1
                peripheral.readValue(for: characteristic)
            }
        }
        checkCompletionIfIdle()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let context = activeContext, context.peripheral == peripheral else { return }
        defer {
            if context.pendingReads > 0 {
                context.pendingReads -= 1
            }
            checkCompletionIfIdle()
        }
        if let error {
            logStore.log(.warn, "BLE probe read failed id=\(context.fingerprintID) char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        if uuid == "2A29" { context.manufacturerName = decodeString(data) }
        if uuid == "2A24" { context.modelNumber = decodeString(data) }
        if uuid == "2A25" { context.serialNumber = decodeString(data) }
        if uuid == "2A26" { context.firmwareRevision = decodeString(data) }
        if uuid == "2A27" { context.hardwareRevision = decodeString(data) }
        if uuid == "2A23" { context.systemID = data.map { String(format: "%02X", $0) }.joined() }
        if uuid == "2A19" { context.batteryLevel = Int(data.first ?? 0) }
        if uuid == "2A00" { context.deviceName = decodeString(data) }
        logStore.log(.info, "BLE probe read id=\(context.fingerprintID) char=\(uuid)")
    }

    private func updateStatus(fingerprintID: String, status: String, error: String?, inProgress: Bool? = nil) {
        var current = statuses[fingerprintID] ?? ProbeStatus(inProgress: false, status: "", lastError: nil, lastUpdated: nil)
        current.status = status
        current.lastError = error
        current.lastUpdated = Date()
        if let inProgress {
            current.inProgress = inProgress
        }
        statuses[fingerprintID] = current
    }

    private func finishProbe(success: Bool, error: String?) {
        guard let context = activeContext else { return }
        let fingerprintID = context.fingerprintID

        let alias = IdentityResolver.shared.resolveLabel(keys: [fingerprintID])
        let result = BLEProbeResult(
            fingerprintID: fingerprintID,
            peripheralID: context.peripheralID.uuidString,
            name: context.name,
            alias: alias,
            lastUpdated: ISO8601DateFormatter().string(from: Date()),
            status: success ? "success" : "failed",
            error: error ?? "",
            discoveredServices: context.discoveredServices.sorted(),
            manufacturerName: context.manufacturerName,
            modelNumber: context.modelNumber,
            serialNumber: context.serialNumber,
            firmwareRevision: context.firmwareRevision,
            hardwareRevision: context.hardwareRevision,
            systemID: context.systemID,
            batteryLevel: context.batteryLevel,
            deviceName: context.deviceName
        )
        results[fingerprintID] = result

        updateStatus(
            fingerprintID: fingerprintID,
            status: success ? "Completed" : "Failed",
            error: error,
            inProgress: false
        )
        activeContext = nil
    }

    private func checkCompletionIfIdle() {
        guard let context = activeContext else { return }
        if context.pendingReads == 0, context.didStartReads {
            context.isComplete = true
            logStore.log(.info, "BLE probe complete id=\(context.fingerprintID)")
            central.cancelPeripheralConnection(context.peripheral)
            finishProbe(success: true, error: nil)
        } else if context.pendingReads > 0 {
            context.didStartReads = true
        } else if !context.didStartReads {
            context.didStartReads = true
            checkCompletionIfIdle()
        }
    }

    private func targetCharacteristicUUIDs(for serviceUUID: CBUUID) -> [CBUUID] {
        let id = serviceUUID.uuidString.uppercased()
        switch id {
        case "180A":
            return ["2A29", "2A24", "2A25", "2A26", "2A27", "2A23"].map { CBUUID(string: $0) }
        case "180F":
            return [CBUUID(string: "2A19")]
        case "1800":
            return [CBUUID(string: "2A00")]
        default:
            return []
        }
    }

    private func isTargetCharacteristic(_ uuid: CBUUID) -> Bool {
        let id = uuid.uuidString.uppercased()
        return ["2A29", "2A24", "2A25", "2A26", "2A27", "2A23", "2A19", "2A00"].contains(id)
    }

    private func decodeString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? data.map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
private final class ProbeContext {
    let fingerprintID: String
    let peripheralID: UUID
    let name: String?
    let peripheral: CBPeripheral
    var pendingReads: Int = 0
    var didStartReads: Bool = false
    var isComplete: Bool = false
    var discoveredServices: [String] = []

    var manufacturerName: String?
    var modelNumber: String?
    var serialNumber: String?
    var firmwareRevision: String?
    var hardwareRevision: String?
    var systemID: String?
    var batteryLevel: Int?
    var deviceName: String?

    init(fingerprintID: String, peripheralID: UUID, name: String?, peripheral: CBPeripheral) {
        self.fingerprintID = fingerprintID
        self.peripheralID = peripheralID
        self.name = name
        self.peripheral = peripheral
    }
}
