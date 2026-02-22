import Combine
import Foundation
import ScannerSpectrumCore

@MainActor
public final class ScanCoordinator: ObservableObject {
    private static let lanAliveOnlyDefaultsKey = "SODSScanner.shared.lanAliveOnly"

    @Published public var blePeripherals: [BLEPeripheral] = []
    @Published public var hosts: [HostEntry] = []
    @Published public var devices: [Device] = []
    @Published public var normalizedEvents: [NormalizedEvent] = []
    @Published public var signalFrames: [SignalFrame] = []
    @Published public var statusMessage: String = "Ready"
    @Published public var lanCapabilities: LANDiscoveryCapabilities
    @Published public var ouiHealth = OUIStoreHealth(
        entryCount: 0,
        source: "unloaded",
        warning: "OUI database not loaded."
    )

    @Published public var lanOnvifEnabled = true
    @Published public var lanServiceDiscoveryEnabled = true
    @Published public var lanArpWarmupEnabled = true
    @Published public var lanAliveOnly = true {
        didSet {
            UserDefaults.standard.set(lanAliveOnly, forKey: Self.lanAliveOnlyDefaultsKey)
        }
    }
    @Published public var scanMode: ScanMode = .continuous

    private let freeHistoryCap = 250
    private let proHistoryCap = 5000

    private let bleScanner = BLEScanner.shared
    public let lanScanner = LANScannerEngine()
    private let synthesizer = SpectrumLocalEventSynthesizer(localNodeID: "sods-client")

    private var cancellables: Set<AnyCancellable> = []
    private var proEntitlementBinding: AnyCancellable?
    private var proUnlocked = false

    public init() {
        lanCapabilities = lanScanner.capabilities
        if let persistedAliveOnly = UserDefaults.standard.object(forKey: Self.lanAliveOnlyDefaultsKey) as? Bool {
            lanAliveOnly = persistedAliveOnly
        }

        bleScanner.configureLogger { level, message in
            print("[BLE][\(level.rawValue)] \(message)")
        }
        lanScanner.configureLogger { level, message in
            print("[LAN][\(level.rawValue)] \(message)")
        }

        bind()

        Task { [weak self] in
            await OUIStore.shared.loadPreferredIfNeeded()
            await self?.refreshOUIHealth()
        }
    }

    public var bleIsScanning: Bool { bleScanner.isScanning }
    public var lanIsScanning: Bool { lanScanner.isScanning }
    public var isProUnlocked: Bool { proUnlocked }

    public var metadataHealth: BLEMetadataHealth {
        BLEMetadataStore.shared.health()
    }

    public var lanVisibleHosts: [HostEntry] {
        if lanAliveOnly {
            return hosts.filter(\.isAlive)
        }
        return hosts
    }

    public func setProUnlocked(_ unlocked: Bool) {
        guard proUnlocked != unlocked else { return }
        proUnlocked = unlocked
        applyHistoryRetention()
    }

    public func bindProEntitlement(initialIsPro: Bool, updates: AnyPublisher<Bool, Never>) {
        setProUnlocked(initialIsPro)
        proEntitlementBinding = updates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPro in
                self?.setProUnlocked(isPro)
            }
    }

    public func bleForID(_ rawID: String) -> BLEPeripheral? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bareID: String
        if trimmed.lowercased().hasPrefix("ble:") {
            bareID = String(trimmed.dropFirst("ble:".count))
        } else {
            bareID = trimmed
        }

        return blePeripherals.first { peripheral in
            peripheral.id.uuidString.caseInsensitiveCompare(bareID) == .orderedSame ||
            "ble:\(peripheral.id.uuidString)".caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public func hostForID(_ rawID: String) -> HostEntry? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bareID: String
        if trimmed.lowercased().hasPrefix("host:") {
            bareID = String(trimmed.dropFirst("host:".count))
        } else {
            bareID = trimmed
        }

        return hosts.first { host in
            host.id == trimmed || host.id == bareID ||
            host.ip == trimmed || host.ip == bareID ||
            "host:\(host.ip)" == trimmed
        }
    }

    public func deviceForID(_ rawID: String) -> Device? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bareID: String
        if trimmed.lowercased().hasPrefix("onvif:") {
            bareID = String(trimmed.dropFirst("onvif:".count))
        } else {
            bareID = trimmed
        }

        return devices.first { device in
            device.id == trimmed || device.id == bareID ||
            device.ip == trimmed || device.ip == bareID ||
            "onvif:\(device.ip)" == trimmed
        }
    }

    public func startBLE() {
        bleScanner.startScan(mode: scanMode)
    }

    public func stopBLE() {
        bleScanner.stopScan()
    }

    public func startLAN() {
        lanScanner.startScan(
            enableOnvifDiscovery: lanOnvifEnabled,
            enableServiceDiscovery: lanServiceDiscoveryEnabled,
            enableArpWarmup: lanArpWarmupEnabled,
            scope: .localDefault,
            mode: scanMode
        )
    }

    public func stopLAN() {
        lanScanner.stopScan()
    }

    public func reloadMetadata() {
        BLEMetadataStore.shared.reload()
        Task {
            _ = await OUIStore.shared.reloadPreferred()
            await refreshOUIHealth()
            statusMessage = "Metadata reloaded."
            refreshSpectrum()
        }
    }

    public func importOUI(url: URL) {
        Task {
            let result = await OUIStore.shared.importFromURLDetailed(url)
            statusMessage = result.message
            await refreshOUIHealth()
            refreshSpectrum()
        }
    }

    public func importBLECompany(url: URL) {
        let result = BLEMetadataStore.shared.importCompanyMapDetailed(from: url)
        statusMessage = result.message
        refreshSpectrum()
    }

    public func importBLEAssigned(url: URL) {
        let result = BLEMetadataStore.shared.importAssignedNumbersMapDetailed(from: url)
        statusMessage = result.message
        refreshSpectrum()
    }

    public func resetImportedOverrides() {
        BLEMetadataStore.shared.clearUserImportOverrides()
        Task {
            await OUIStore.shared.clearUserImportOverride()
            await refreshOUIHealth()
            statusMessage = "Cleared imported overrides and restored bundled databases."
            refreshSpectrum()
        }
    }

    private func bind() {
        bleScanner.$peripherals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peripherals in
                guard let self else { return }
                self.blePeripherals = peripherals
                self.refreshSpectrum()
            }
            .store(in: &cancellables)

        lanScanner.$allHosts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                guard let self else { return }
                self.hosts = hosts
                self.refreshSpectrum()
            }
            .store(in: &cancellables)

        lanScanner.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self else { return }
                self.devices = devices
                self.refreshSpectrum()
            }
            .store(in: &cancellables)

        lanScanner.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, let message else { return }
                self.statusMessage = message
            }
            .store(in: &cancellables)

        lanScanner.$capabilities
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capabilities in
                self?.lanCapabilities = capabilities
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: BLEMetadataStore.metadataUpdatedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.statusMessage = "BLE metadata updated."
            }
            .store(in: &cancellables)
    }

    private func refreshOUIHealth() async {
        ouiHealth = await OUIStore.shared.health()
    }

    private func refreshSpectrum() {
        let synthesized = synthesizer.synthesize(
            blePeripherals: blePeripherals,
            hosts: hosts,
            devices: devices
        )

        if !synthesized.events.isEmpty {
            normalizedEvents.append(contentsOf: synthesized.events)
        }

        if !synthesized.frames.isEmpty {
            signalFrames.append(contentsOf: synthesized.frames)
        }

        applyHistoryRetention()
    }

    private func applyHistoryRetention() {
        let cap = proUnlocked ? proHistoryCap : freeHistoryCap

        if normalizedEvents.count > cap {
            normalizedEvents.removeFirst(normalizedEvents.count - cap)
        }

        if signalFrames.count > cap {
            signalFrames.removeFirst(signalFrames.count - cap)
        }
    }
}
