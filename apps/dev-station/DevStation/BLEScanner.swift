import Foundation
import CoreBluetooth
import CryptoKit

@MainActor
final class BLEScanner: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = BLEScanner()

    @Published private(set) var peripherals: [BLEPeripheral] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var stateDescription: String = "unknown"
    @Published private(set) var isAvailableForScan: Bool = false
    @Published private(set) var authorizationDescription: String = "unknown"
    @Published private(set) var authorizationStatus: CBManagerAuthorization = .notDetermined
    @Published private(set) var lastPermissionMessage: String = ""

    private let logStore = LogStore.shared
    private(set) var scanMode: ScanMode = .oneShot
    private let oneShotDuration: TimeInterval = 8
    private var oneShotTask: Task<Void, Never>?
    private var central: CBCentralManager!
    private var shouldScan = false
    private var lastStateDescription: String?
    private var firstDeviceLogged = false
    private let rssiAlpha = 0.2
    private let rssiHistoryWindow: TimeInterval = 20

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        authorizationStatus = CBManager.authorization
        authorizationDescription = describe(authorization: authorizationStatus)
        stateDescription = describe(state: central.state)
        logStore.log(.info, "BLE manager init: auth=\(authorizationDescription), state=\(stateDescription)")
    }

    func setScanning(_ enabled: Bool, mode: ScanMode = .continuous) {
        if enabled {
            startScan(mode: mode)
        } else {
            stopScan()
        }
    }

    func startScan(mode: ScanMode = .continuous) {
        logStore.log(.info, "BLE scan requested")
        scanMode = mode
        shouldScan = mode == .continuous
        oneShotTask?.cancel()
        Task { @MainActor in
            await touchForPermissionIfNeeded()
            startScanningIfReady()
            if mode == .oneShot {
                oneShotTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.oneShotDuration ?? 8) * 1_000_000_000)
                    await MainActor.run {
                        self?.stopScan()
                    }
                }
            }
        }
    }

    func stopScan() {
        logStore.log(.info, "BLE toggle off")
        shouldScan = false
        oneShotTask?.cancel()
        oneShotTask = nil
        stopScanning()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = describe(state: central.state)
        stateDescription = newState
        isAvailableForScan = central.state == .poweredOn
        authorizationStatus = CBManager.authorization
        authorizationDescription = describe(authorization: authorizationStatus)
        if lastStateDescription != newState {
            lastStateDescription = newState
            logStore.log(.info, "BLE state: \(newState)")
        }
        logStore.log(.info, "CBCentralManager didUpdateState: \(newState), auth=\(authorizationDescription)")
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            lastPermissionMessage = "Bluetooth permission is blocked by system policy."
        }

        if central.state == .poweredOn {
            startScanningIfReady()
        } else {
            stopScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString.uppercased() } ?? []
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturerHex = manufacturerData?.map { String(format: "%02X", $0) }.joined()
        let fingerprint = makeFingerprint(
            localName: name,
            advertisementData: advertisementData,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData
        )
        let fingerprintID = computeFingerprintID(fingerprint)
        let bleConfidence = computeBLEConfidence(fingerprint)

        if let index = peripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
            let previousSmoothed = peripherals[index].smoothedRSSI
            let currentRSSI = Double(RSSI.intValue)
            let smoothed = previousSmoothed == 0 ? currentRSSI : (rssiAlpha * currentRSSI + (1 - rssiAlpha) * previousSmoothed)
            peripherals[index].name = name ?? peripherals[index].name
            peripherals[index].rssi = RSSI.intValue
            peripherals[index].smoothedRSSI = smoothed
            peripherals[index].rssiHistory.append(BLERSSISample(timestamp: Date(), smoothedRSSI: smoothed))
            let cutoff = Date().addingTimeInterval(-rssiHistoryWindow)
            peripherals[index].rssiHistory.removeAll { $0.timestamp < cutoff }
            if !serviceUUIDs.isEmpty {
                peripherals[index].serviceUUIDs = serviceUUIDs
            }
            if let manufacturerHex = manufacturerHex {
                peripherals[index].manufacturerDataHex = manufacturerHex
            }
            peripherals[index].fingerprint = fingerprint
            peripherals[index].fingerprintID = fingerprintID
            peripherals[index].bleConfidence = bleConfidence
            peripherals[index].lastSeen = Date()
        } else {
            if !firstDeviceLogged {
                firstDeviceLogged = true
                logStore.log(.info, "BLE first device discovered")
            }
            let initialSmoothed = Double(RSSI.intValue)
            let history = [BLERSSISample(timestamp: Date(), smoothedRSSI: initialSmoothed)]
            let item = BLEPeripheral(
                id: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                smoothedRSSI: initialSmoothed,
                rssiHistory: history,
                serviceUUIDs: serviceUUIDs,
                manufacturerDataHex: manufacturerHex,
                fingerprint: fingerprint,
                fingerprintID: fingerprintID,
                bleConfidence: bleConfidence,
                lastSeen: Date()
            )
            peripherals.append(item)
            logNewPeripheral(item)
        }
    }

    func snapshotEvidence() -> [BLEEvidence] {
        peripherals.map { peripheral in
            BLEEvidence(
                id: peripheral.id.uuidString,
                name: peripheral.name ?? "",
                rssi: peripheral.rssi,
                serviceUUIDs: peripheral.serviceUUIDs,
                manufacturerDataHex: peripheral.manufacturerDataHex ?? "",
                manufacturerCompanyID: peripheral.fingerprint.manufacturerCompanyID,
                manufacturerCompanyName: peripheral.fingerprint.manufacturerCompanyName,
                manufacturerAssignmentDate: peripheral.fingerprint.manufacturerAssignmentDate,
                servicesDecoded: peripheral.fingerprint.servicesDecoded,
                unknownServices: peripheral.fingerprint.unknownServices,
                bleConfidence: peripheral.bleConfidence
            )
        }
    }

    private func startScanningIfReady() {
        guard shouldScan || scanMode == .oneShot else { return }
        guard central.state == .poweredOn else { return }
        guard !isScanning else { return }
        isScanning = true
        firstDeviceLogged = false
        logStore.log(.info, "BLE scan started")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func stopScanning() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        logStore.log(.info, "BLE scan stopped")
        logStore.log(.info, "BLE peripherals discovered: \(peripherals.count)")
        logBLEConfidenceSummary()
    }

    private func logNewPeripheral(_ item: BLEPeripheral) {
        let name = item.name ?? ""
        let company = item.fingerprint.manufacturerCompanyName ?? ""
        let beacon = item.fingerprint.beaconHint ?? ""
        let count = item.fingerprint.serviceUUIDs.count
        logStore.log(.info, "BLE device \(item.id.uuidString) name=\(name) company=\(company) beacon=\(beacon) services=\(count)")
    }

    @MainActor
    func touchForPermissionIfNeeded() async {
        let auth = CBManager.authorization
        authorizationStatus = auth
        authorizationDescription = describe(authorization: auth)
        if auth == .notDetermined {
            lastPermissionMessage = "Requesting Bluetooth permission..."
            logStore.log(.info, "BLE permission nudge scan started")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            central.stopScan()
            logStore.log(.info, "BLE permission nudge scan stopped")
            lastPermissionMessage = "Bluetooth permission prompt requested."
        } else if auth == .denied || auth == .restricted {
            lastPermissionMessage = "Bluetooth permission is blocked. Enable it in System Settings."
            logStore.log(.warn, "BLE permission blocked: auth=\(authorizationDescription), state=\(stateDescription)")
        } else {
            lastPermissionMessage = "Bluetooth permission is allowed."
        }
    }

    private func describe(authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways:
            return "allowedAlways"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    private func computeFingerprintID(_ fingerprint: BLEAdFingerprint) -> String {
        let company = fingerprint.manufacturerCompanyID.map { String(format: "%04X", $0) } ?? ""
        let prefix = fingerprint.manufacturerDataPrefixHex ?? ""
        let uuids = fingerprint.serviceUUIDs.sorted().joined(separator: ",")
        let name = fingerprint.localName ?? ""
        let input = "\(company)|\(prefix)|\(uuids)|\(name)"
        let hash = SHA256.hash(data: Data(input.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(10))
    }

    private func computeBLEConfidence(_ fingerprint: BLEAdFingerprint) -> BLEConfidence {
        var score = 0
        var reasons: [String] = []

        if fingerprint.manufacturerCompanyName != nil {
            score += 20
            reasons.append("Known company ID (+20)")
        }
        if let hint = fingerprint.beaconHint, hint == "iBeacon" || hint == "Eddystone" {
            score += 15
            reasons.append("Beacon hint \(hint) (+15)")
        }
        if !fingerprint.serviceUUIDs.isEmpty {
            score += 10
            reasons.append("Service UUIDs present (+10)")
        }
        if fingerprint.isConnectable == true {
            score += 10
            reasons.append("Connectable advertisement (+10)")
        }
        if fingerprint.txPower != nil {
            score += 5
            reasons.append("TX power present (+5)")
        }
        if fingerprint.manufacturerCompanyID == 0x004C,
           let prefix = fingerprint.manufacturerDataPrefixHex,
           prefix.hasPrefix("4C001219") {
            score += 10
            reasons.append("Apple Find My-style payload (+10)")
        }

        score = max(0, min(100, score))
        let level: ConfidenceLevel
        if score >= 70 {
            level = .high
        } else if score >= 40 {
            level = .medium
        } else {
            level = .low
        }
        return BLEConfidence(score: score, level: level, reasons: reasons)
    }

    private func logBLEConfidenceSummary() {
        let scored = peripherals.count
        let high = peripherals.filter { $0.bleConfidence.level == .high }.count
        let med = peripherals.filter { $0.bleConfidence.level == .medium }.count
        let low = peripherals.filter { $0.bleConfidence.level == .low }.count
        logStore.log(.info, "Scored BLE: \(scored) (high: \(high), med: \(med), low: \(low))")
    }

    private func makeFingerprint(
        localName: String?,
        advertisementData: [String: Any],
        serviceUUIDs: [String],
        manufacturerData: Data?
    ) -> BLEAdFingerprint {
        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue

        var companyID: UInt16?
        var companyName: String?
        var companyAssignment: String?
        var dataPrefixHex: String?
        if let manufacturerData, manufacturerData.count >= 2 {
            companyID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
            if let companyID {
                if let info = BLEMetadataStore.shared.companyInfo(for: companyID) {
                    companyName = info.name
                    companyAssignment = info.assignmentDate
                }
            }
            let prefixLength = min(8, manufacturerData.count)
            dataPrefixHex = manufacturerData.prefix(prefixLength).map { String(format: "%02X", $0) }.joined()
        }

        var decodedServices: [BLEServiceDecoded] = []
        var unknownServices: [String] = []
        if !serviceUUIDs.isEmpty {
            for uuid in serviceUUIDs {
                if let info = BLEMetadataStore.shared.assignedUUIDInfo(for: CBUUID(string: uuid)) {
                    decodedServices.append(
                        BLEServiceDecoded(
                            uuid: info.uuidFull,
                            name: info.name,
                            type: info.type,
                            source: info.source
                        )
                    )
                } else {
                    unknownServices.append(uuid)
                }
            }
        }

        var beaconHint: String?
        if let manufacturerData, manufacturerData.count >= 4, companyID == 0x004C {
            if manufacturerData[2] == 0x02 && manufacturerData[3] == 0x15 {
                beaconHint = "iBeacon"
            }
        }
        if beaconHint == nil {
            if serviceUUIDs.contains("FEAA") {
                beaconHint = "Eddystone"
            }
        }

        return BLEAdFingerprint(
            localName: localName,
            isConnectable: isConnectable,
            txPower: txPower,
            serviceUUIDs: serviceUUIDs,
            manufacturerCompanyID: companyID,
            manufacturerCompanyName: companyName,
            manufacturerAssignmentDate: companyAssignment,
            manufacturerDataPrefixHex: dataPrefixHex,
            beaconHint: beaconHint,
            servicesDecoded: decodedServices,
            unknownServices: unknownServices
        )
    }

    private let labelPrefix = "bleLabel."

    func label(for fingerprintID: String) -> String? {
        let key = labelPrefix + fingerprintID
        return UserDefaults.standard.string(forKey: key)
    }

    func setLabel(_ label: String, for fingerprintID: String) {
        let key = labelPrefix + fingerprintID
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    private func describe(state: CBManagerState) -> String {
        switch state {
        case .poweredOn:
            return "poweredOn"
        case .poweredOff:
            return "poweredOff"
        case .unauthorized:
            return "unauthorized"
        case .unsupported:
            return "unsupported"
        case .resetting:
            return "resetting"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}
