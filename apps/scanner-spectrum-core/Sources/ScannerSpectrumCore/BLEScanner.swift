import Foundation
import CoreBluetooth
import CryptoKit

@MainActor
public final class BLEScanner: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    public static let shared = BLEScanner()

    @Published public private(set) var peripherals: [BLEPeripheral] = []
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var stateDescription: String = "unknown"
    @Published public private(set) var isAvailableForScan: Bool = false
    @Published public private(set) var authorizationDescription: String = "unknown"
    @Published public private(set) var authorizationStatus: CBManagerAuthorization = .notDetermined
    @Published public private(set) var lastPermissionMessage: String = ""

    private var logger: ScannerCoreLogger?
    public private(set) var scanMode: ScanMode = .continuous
    private let oneShotDuration: TimeInterval = 8
    private var oneShotTask: Task<Void, Never>?
    private var central: CBCentralManager!
    private var shouldScan = false
    private var lastStateDescription: String?
    private var firstDeviceLogged = false
    private let rssiAlpha = 0.2
    private let rssiHistoryWindow: TimeInterval = 20
    private let continuousPublishIntervalMs = 500.0
    private var latestPeripheralByID: [UUID: BLEPeripheral] = [:]
    private var continuousPublishTask: Task<Void, Never>?
    private var lastParityLogAt: Date?
    private let parityLogInterval: TimeInterval = 10

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        authorizationStatus = CBManager.authorization
        authorizationDescription = describe(authorization: authorizationStatus)
        stateDescription = describe(state: central.state)
        coreLog(logger, .info, "BLE manager init: auth=\(authorizationDescription), state=\(stateDescription)")
    }

    public func configureLogger(_ logger: ScannerCoreLogger?) {
        self.logger = logger
    }

    public func setScanning(_ enabled: Bool, mode: ScanMode = .continuous) {
        if enabled {
            startScan(mode: mode)
        } else {
            stopScan()
        }
    }

    public func startScan(mode: ScanMode = .continuous) {
        coreLog(logger, .info, "BLE scan requested")
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

    public func stopScan() {
        coreLog(logger, .info, "BLE toggle off")
        shouldScan = false
        scanMode = .continuous
        oneShotTask?.cancel()
        oneShotTask = nil
        stopScanning()
    }

    public func clearDiscovered() {
        peripherals.removeAll()
        latestPeripheralByID.removeAll()
        continuousPublishTask?.cancel()
        continuousPublishTask = nil
        firstDeviceLogged = false
        coreLog(logger, .info, "BLE discovered list cleared")
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = describe(state: central.state)
        stateDescription = newState
        isAvailableForScan = central.state == .poweredOn
        authorizationStatus = CBManager.authorization
        authorizationDescription = describe(authorization: authorizationStatus)
        if lastStateDescription != newState {
            lastStateDescription = newState
            coreLog(logger, .info, "BLE state: \(newState)")
        }
        coreLog(logger, .info, "CBCentralManager didUpdateState: \(newState), auth=\(authorizationDescription)")
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            lastPermissionMessage = "Bluetooth permission is blocked by system policy."
        }

        if central.state == .poweredOn {
            startScanningIfReady()
        } else {
            stopScanning()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let now = Date()
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
        let existing = latestPeripheralByID[peripheral.identifier]
        let currentRSSI = Double(RSSI.intValue)
        let previousSmoothed = existing?.smoothedRSSI ?? 0
        let smoothed = previousSmoothed == 0 ? currentRSSI : (rssiAlpha * currentRSSI + (1 - rssiAlpha) * previousSmoothed)
        var history = existing?.rssiHistory ?? []
        history.append(BLERSSISample(timestamp: now, smoothedRSSI: smoothed))
        let cutoff = now.addingTimeInterval(-rssiHistoryWindow)
        history.removeAll { $0.timestamp < cutoff }

        let updated = BLEPeripheral(
            id: peripheral.identifier,
            name: name ?? existing?.name,
            rssi: RSSI.intValue,
            smoothedRSSI: smoothed,
            rssiHistory: history,
            serviceUUIDs: serviceUUIDs.isEmpty ? (existing?.serviceUUIDs ?? []) : serviceUUIDs,
            manufacturerDataHex: manufacturerHex ?? existing?.manufacturerDataHex,
            fingerprint: fingerprint,
            fingerprintID: fingerprintID,
            bleConfidence: bleConfidence,
            lastSeen: now,
            provenance: Provenance(source: "ble.scan", mode: scanMode, timestamp: now)
        )

        latestPeripheralByID[peripheral.identifier] = updated
        if existing == nil {
            if !firstDeviceLogged {
                firstDeviceLogged = true
                coreLog(logger, .info, "BLE first device discovered")
            }
            logNewPeripheral(updated)
        }

        if scanMode == .continuous {
            scheduleContinuousPublish()
        } else {
            publishSnapshot()
        }
    }

    public func snapshotEvidence() -> [BLEEvidence] {
        let source = latestPeripheralByID.isEmpty ? peripherals : latestPeripheralByID.values.sorted { $0.lastSeen > $1.lastSeen }
        return source.map { peripheral in
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
        continuousPublishTask?.cancel()
        continuousPublishTask = nil
        let allowDuplicates = scanMode == .continuous
        coreLog(logger, .info, "BLE scan started mode=\(scanMode.rawValue) allowDuplicates=\(allowDuplicates)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    private func stopScanning() {
        guard isScanning else { return }
        continuousPublishTask?.cancel()
        continuousPublishTask = nil
        central.stopScan()
        isScanning = false
        publishSnapshot()
        coreLog(logger, .info, "BLE scan stopped")
        coreLog(logger, .info, "BLE peripherals discovered: \(latestPeripheralByID.count)")
        logBLEConfidenceSummary()
    }

    private func scheduleContinuousPublish() {
        guard continuousPublishTask == nil else { return }
        let delayNs = UInt64(continuousPublishIntervalMs * 1_000_000)
        continuousPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.continuousPublishTask = nil
                self.publishSnapshot()
            }
        }
    }

    private func publishSnapshot() {
        peripherals = latestPeripheralByID.values.sorted { lhs, rhs in
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            if lhs.rssi != rhs.rssi {
                return lhs.rssi > rhs.rssi
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        logParityIfNeeded()
    }

    private func logNewPeripheral(_ item: BLEPeripheral) {
        let name = item.name ?? ""
        let company = item.fingerprint.manufacturerCompanyName ?? ""
        let beacon = item.fingerprint.beaconHint ?? ""
        let count = item.fingerprint.serviceUUIDs.count
        coreLog(logger, .info, "BLE device \(item.id.uuidString) name=\(name) company=\(company) beacon=\(beacon) services=\(count)")
    }

    private func logParityIfNeeded() {
        let now = Date()
        if let last = lastParityLogAt, now.timeIntervalSince(last) < parityLogInterval {
            return
        }
        lastParityLogAt = now
        let scannerCount = latestPeripheralByID.count
        let publishedCount = peripherals.count
        let fingerprintCount = Set(peripherals.map { $0.fingerprintID }).count
        let scannerSamples = sampleUUIDSuffixes(from: latestPeripheralByID.keys.map(\.uuidString))
        let publishedSamples = sampleUUIDSuffixes(from: peripherals.map { $0.id.uuidString })
        coreLog(
            logger,
            .info,
            "BLE parity: scanner=\(scannerCount) published=\(publishedCount) distinct_fingerprints=\(fingerprintCount) scanner_samples=\(scannerSamples) published_samples=\(publishedSamples)"
        )
    }

    private func sampleUUIDSuffixes(from uuids: [String]) -> String {
        let suffixes = uuids
            .sorted()
            .prefix(5)
            .map { uuid -> String in
                String(uuid.suffix(6))
            }
        if suffixes.isEmpty {
            return "-"
        }
        return suffixes.joined(separator: ",")
    }

    @MainActor
    public func touchForPermissionIfNeeded() async {
        let auth = CBManager.authorization
        authorizationStatus = auth
        authorizationDescription = describe(authorization: auth)
        if auth == .notDetermined {
            lastPermissionMessage = "Requesting Bluetooth permission..."
            coreLog(logger, .info, "BLE permission nudge scan started")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            central.stopScan()
            coreLog(logger, .info, "BLE permission nudge scan stopped")
            lastPermissionMessage = "Bluetooth permission prompt requested."
        } else if auth == .denied || auth == .restricted {
            lastPermissionMessage = "Bluetooth permission is blocked. Enable it in System Settings."
            coreLog(logger, .warn, "BLE permission blocked: auth=\(authorizationDescription), state=\(stateDescription)")
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
        coreLog(logger, .info, "Scored BLE: \(scored) (high: \(high), med: \(med), low: \(low))")
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

    public func label(for fingerprintID: String) -> String? {
        let key = labelPrefix + fingerprintID
        return UserDefaults.standard.string(forKey: key)
    }

    public func setLabel(_ label: String, for fingerprintID: String) {
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
