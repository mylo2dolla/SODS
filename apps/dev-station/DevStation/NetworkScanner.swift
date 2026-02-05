import Foundation
import Network
import Darwin

@MainActor
final class NetworkScanner: ObservableObject {
    @Published var devices: [Device] = []
    @Published var progress: ScanProgress?
    @Published var isScanning = false
    @Published var statusMessage: String?
    @Published var subnetDescription: String?
    @Published var onvifFetchInProgress: Set<String> = []
    @Published var allHosts: [HostEntry] = []
    @Published var safeModeEnabled = true

    @Published private(set) var scanMode: ScanMode = .oneShot

    private let ports = [80, 443, 554, 8000, 8080, 8443, 1935, 3702, 8554]
    private let maxConcurrentHosts = 64
    private let maxConcurrentPortProbes = 128
    private let portTimeout: TimeInterval = 1.5
    private let httpTimeout: TimeInterval = 2.5
    private let httpFingerprintTimeout: TimeInterval = 2.0
    private let httpFingerprintSemaphore = AsyncSemaphore(value: 8)
    private let onvifSoapSemaphore = AsyncSemaphore(value: 8)
    private let onvifRtspSemaphore = AsyncSemaphore(value: 4)
    private let rtspProbeSemaphore = AsyncSemaphore(value: 4)
    private let hostnameSemaphore = AsyncSemaphore(value: 16)
    private let hostnameTimeout: TimeInterval = 1.0
    private let logStore = LogStore.shared
    private var lastScanStart: Date?
    private var lastScanEnd: Date?
    private var lastScanScopeDescription: String = ""
    private var lastTotalIPs: Int = 0
    private var lastAliveCount: Int = 0
    private var lastInterestingCount: Int = 0
    private var ouiWatcher: OUIFileWatcher?
    private var hostConfidenceLoggedForScan = false
    private var scanTask: Task<Void, Never>?

    struct ScanSummary: Hashable {
        let start: Date?
        let end: Date?
        let scope: String
        let totalIPs: Int
        let aliveCount: Int
        let interestingCount: Int
        let safeMode: Bool
    }

    init() {
        startOUIWatcher()
    }

    func scanSummary() -> ScanSummary {
        let scope = lastScanScopeDescription.isEmpty ? (subnetDescription ?? "") : lastScanScopeDescription
        return ScanSummary(
            start: lastScanStart,
            end: lastScanEnd,
            scope: scope,
            totalIPs: lastTotalIPs,
            aliveCount: lastAliveCount,
            interestingCount: lastInterestingCount,
            safeMode: safeModeEnabled
        )
    }

    func startScan(enableOnvifDiscovery: Bool, enableServiceDiscovery: Bool, enableArpWarmup: Bool, scope: ScanScope, mode: ScanMode) {
        guard !isScanning else { return }
        scanMode = mode
        isScanning = true
        devices = []
        allHosts = []
        progress = nil
        statusMessage = nil
        subnetDescription = nil
        lastScanStart = Date()
        lastScanEnd = nil
        hostConfidenceLoggedForScan = false

        logStore.log(.info, "Scan started (ONVIF discovery \(enableOnvifDiscovery ? "enabled" : "disabled"), service discovery \(enableServiceDiscovery ? "enabled" : "disabled"), ARP warmup \(enableArpWarmup ? "enabled" : "disabled"), safe mode \(safeModeEnabled ? "on" : "off"))")
        scanTask?.cancel()
        scanTask = Task {
            await runScanLoop(enableOnvifDiscovery: enableOnvifDiscovery, enableServiceDiscovery: enableServiceDiscovery, enableArpWarmup: enableArpWarmup, scope: scope)
        }
    }

    func stopScan() {
        guard isScanning else { return }
        logStore.log(.info, "Scan stopped by operator")
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = "Scan stopped."
    }

    private func runScanLoop(enableOnvifDiscovery: Bool, enableServiceDiscovery: Bool, enableArpWarmup: Bool, scope: ScanScope) async {
        repeat {
            await MainActor.run { self.isScanning = true }
            await runScan(enableOnvifDiscovery: enableOnvifDiscovery, enableServiceDiscovery: enableServiceDiscovery, enableArpWarmup: enableArpWarmup, scope: scope)
            if Task.isCancelled { break }
            if scanMode != .continuous { break }
        } while true
    }

    private func startOUIWatcher() {
        guard ouiWatcher == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fileURL = URL(fileURLWithPath: "\(home)/SODS/oui/oui_combined.txt")
        let watcher = OUIFileWatcher(fileURL: fileURL, log: logStore) { [weak self] in
            guard let self else { return }
            Task {
                await self.reloadOUIAndRefreshVendors()
            }
        }
        ouiWatcher = watcher
        watcher.start()
    }

    private func runScan(enableOnvifDiscovery: Bool, enableServiceDiscovery: Bool, enableArpWarmup: Bool, scope: ScanScope) async {
        guard let activeSubnet = IPv4Subnet.active() else {
            await MainActor.run {
                statusMessage = "No active IPv4 interface found."
                isScanning = false
            }
            logStore.log(.warn, "Scan aborted: no active IPv4 interface found")
            return
        }

        let resolved = resolveScope(scope: scope, activeSubnet: activeSubnet)
        let hostIPs = resolved.hostIPs
        lastScanScopeDescription = resolved.description
        await MainActor.run {
            subnetDescription = resolved.description
        }
        await MainActor.run {
            progress = ScanProgress(scannedHosts: 0, totalHosts: hostIPs.count)
        }
        let localIP = activeSubnet.addressString
        let provenance = Provenance(source: "net.scan", mode: scanMode, timestamp: Date())
        allHosts = hostIPs.map { ip in
            HostEntry(
                id: ip,
                ip: ip,
                isAlive: ip == localIP,
                openPorts: [],
                hostname: nil,
                macAddress: nil,
                vendor: nil,
                vendorConfidenceScore: 0,
                vendorConfidenceReasons: [],
                hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
                ssdpServer: nil,
                ssdpLocation: nil,
                ssdpST: nil,
                ssdpUSN: nil,
                bonjourServices: [],
                httpStatus: nil,
                httpServer: nil,
                httpAuth: nil,
                httpTitle: nil,
                provenance: provenance
            )
        }
        if !allHosts.contains(where: { $0.ip == localIP }) {
            allHosts.append(
                HostEntry(
                    id: localIP,
                    ip: localIP,
                    isAlive: true,
                    openPorts: [],
                    hostname: nil,
                    macAddress: nil,
                    vendor: nil,
                    vendorConfidenceScore: 0,
                    vendorConfidenceReasons: [],
                    hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
                    ssdpServer: nil,
                    ssdpLocation: nil,
                    ssdpST: nil,
                    ssdpUSN: nil,
                    bonjourServices: [],
                    httpStatus: nil,
                    httpServer: nil,
                    httpAuth: nil,
                    httpTitle: nil,
                    provenance: provenance
                )
            )
        }
        lastTotalIPs = hostIPs.count
        logStore.log(.info, "Scan scope: \(resolved.description)")
        logStore.log(.info, "Total IPs to scan: \(hostIPs.count)")

        if hostIPs.isEmpty {
            await MainActor.run {
                statusMessage = "No usable hosts in subnet."
                isScanning = false
            }
            logStore.log(.warn, "Scan aborted: no usable hosts in subnet")
            return
        }

        if enableArpWarmup {
            logStore.log(.info, "ARP warmup started: \(hostIPs.count) IPs")
            await Task.detached {
                await NetworkScanner.runArpWarmup(hostIPs: hostIPs)
            }.value
            logStore.log(.info, "ARP warmup finished")
            await refreshARPInternal()
        }

        let onvifTask: Task<Void, Never>?
        if enableOnvifDiscovery {
            onvifTask = Task {
                let results = await ONVIFDiscovery.discover(timeout: 3.0) { level, message in
                    LogStore.shared.log(level, message)
                }
                await MainActor.run {
                    for result in results {
                        self.mergeOnvifDiscovery(result)
                    }
                }
            }
        } else {
            onvifTask = nil
        }

        let ssdpTask: Task<Void, Never>?
        let bonjourTask: Task<Void, Never>?
        if enableServiceDiscovery {
            ssdpTask = Task {
                logStore.log(.info, "SSDP discovery started")
                let results = await SSDPDiscovery.discover(timeout: 3.0, log: { level, message in
                    LogStore.shared.log(level, message)
                }, onResult: { result in
                    self.mergeSSDPResult(result)
                    LogStore.shared.log(.info, "SSDP response from \(result.ip) server=\(result.server ?? "") location=\(result.location ?? "")")
                })
                LogStore.shared.log(.info, "SSDP responses: \(results.count)")
            }
            bonjourTask = Task {
                logStore.log(.info, "Bonjour discovery started")
                let results = await BonjourDiscovery.discover(timeout: 3.0, log: { level, message in
                    LogStore.shared.log(level, message)
                }, onResult: { result in
                    self.mergeBonjourResult(result)
                })
                LogStore.shared.log(.info, "Bonjour services: \(results.count)")
            }
        } else {
            ssdpTask = nil
            bonjourTask = nil
        }

        let hostSemaphore = AsyncSemaphore(value: maxConcurrentHosts)
        let portSemaphore = AsyncSemaphore(value: maxConcurrentPortProbes)

        await withTaskGroup(of: Device?.self) { group in
            for ip in hostIPs {
                await hostSemaphore.wait()
                group.addTask {
                    defer { Task { await hostSemaphore.signal() } }
                    let result = await self.scanHost(ip: ip, portSemaphore: portSemaphore)
                    await MainActor.run {
                        self.recordHostResult(result)
                        if var current = self.progress {
                            current.scannedHosts += 1
                            self.progress = current
                        }
                    }
                    return result.device
                }
            }

            for await device in group {
                if let device = device {
                    await MainActor.run {
                        self.mergeScannedDevice(device)
                    }
                }
            }
        }

        if let onvifTask = onvifTask {
            await onvifTask.value
        }
        if let ssdpTask = ssdpTask {
            await ssdpTask.value
        }
        if let bonjourTask = bonjourTask {
            await bonjourTask.value
        }

        if !enableServiceDiscovery {
            logHostConfidenceSummaryIfNeeded()
        }

        let aliveCount = allHosts.filter { $0.isAlive }.count
        lastAliveCount = aliveCount
        lastInterestingCount = devices.count
        logStore.log(.info, "Scan finished: alive \(aliveCount) / \(allHosts.count)")
        Task {
            await self.resolveHostnames()
            await self.refreshARPInternal()
            if enableServiceDiscovery {
                await self.runHTTPFingerprinting()
            }
        }

        await MainActor.run {
            statusMessage = "Scan complete."
            isScanning = false
        }
        lastScanEnd = Date()
        logStore.log(.info, "Scan complete")
    }

    private func resolveScope(scope: ScanScope, activeSubnet: IPv4Subnet) -> ResolvedScope {
        let activeDescription = "\(activeSubnet.addressString)/\(activeSubnet.prefixLength)"
        let cidrSubnet = IPv4Subnet.parse(cidr: scope.cidr) ?? activeSubnet
        var targetSubnet = cidrSubnet
        var description = "\(targetSubnet.addressString)/\(targetSubnet.prefixLength)"

        if scope.onlyLocalSubnet {
            if !activeSubnet.contains(targetSubnet.network) || !activeSubnet.contains(targetSubnet.broadcast) {
                targetSubnet = activeSubnet
                description = activeDescription
                logStore.log(.warn, "Scope override blocked by local subnet restriction")
            }
        }

        if let range = scope.ipRange {
            if let start = IPv4Subnet.ipToUInt32(range.start),
               let end = IPv4Subnet.ipToUInt32(range.end),
               start <= end {
                if scope.onlyLocalSubnet && (!activeSubnet.contains(start) || !activeSubnet.contains(end)) {
                    logStore.log(.warn, "IP range override blocked by local subnet restriction")
                } else {
                    let hosts = hostsFromRange(start: start, end: end)
                    description = "\(range.start)-\(range.end)"
                    return ResolvedScope(description: description, hostIPs: hosts)
                }
            }
        }

        return ResolvedScope(description: description, hostIPs: targetSubnet.hostIPs())
    }

    private func hostsFromRange(start: UInt32, end: UInt32) -> [String] {
        if end < start { return [] }
        var results: [String] = []
        results.reserveCapacity(Int(end - start + 1))
        var current = start
        while current <= end {
            results.append(IPv4Subnet.ipString(from: current))
            if current == UInt32.max { break }
            current += 1
        }
        return results
    }

    private func mergeScannedDevice(_ device: Device) {
        if let index = devices.firstIndex(where: { $0.ip == device.ip }) {
            var existing = devices[index]
            existing.openPorts = Array(Set(existing.openPorts).union(device.openPorts)).sorted()
            if existing.httpTitle == nil {
                existing.httpTitle = device.httpTitle
            }
            let host = allHosts.first(where: { $0.ip == existing.ip })
            devices[index] = applyDeviceConfidence(existing, host: host)
        } else {
            let host = allHosts.first(where: { $0.ip == device.ip })
            devices.append(applyDeviceConfidence(device, host: host))
        }
        devices.sort { $0.ip < $1.ip }
    }

    private func mergeOnvifDiscovery(_ result: OnvifDiscoveryResult) {
        let shouldAutoFetch: Bool
        if let index = devices.firstIndex(where: { $0.ip == result.ip }) {
            var existing = devices[index]
            existing.discoveredViaOnvif = true
            existing.onvifXAddrs = Array(Set(existing.onvifXAddrs).union(result.xaddrs)).sorted()
            existing.onvifTypes = existing.onvifTypes ?? result.types
            existing.onvifScopes = existing.onvifScopes ?? result.scopes
            if !existing.openPorts.contains(3702) {
                existing.openPorts.append(3702)
                existing.openPorts.sort()
            }
            let host = allHosts.first(where: { $0.ip == existing.ip })
            devices[index] = applyDeviceConfidence(existing, host: host)
            shouldAutoFetch = !existing.onvifXAddrs.isEmpty && existing.onvifRtspURI == nil
        } else {
            var newDevice = makeDevice(ip: result.ip, openPorts: [3702], httpTitle: nil)
            newDevice.discoveredViaOnvif = true
            newDevice.onvifXAddrs = result.xaddrs
            newDevice.onvifTypes = result.types
            newDevice.onvifScopes = result.scopes
            let host = allHosts.first(where: { $0.ip == newDevice.ip })
            devices.append(applyDeviceConfidence(newDevice, host: host))
            shouldAutoFetch = !newDevice.onvifXAddrs.isEmpty
        }
        devices.sort { $0.ip < $1.ip }
        updateHostConfidence(forIP: result.ip)
        if shouldAutoFetch && !safeModeEnabled {
            fetchOnvifRtsp(for: result.ip, reason: .auto)
        }
    }

    private func mergeSSDPResult(_ result: SSDPDiscoveryResult) {
        if let index = allHosts.firstIndex(where: { $0.ip == result.ip }) {
            var entry = allHosts[index]
            entry.isAlive = true
            entry.ssdpServer = entry.ssdpServer ?? result.server
            entry.ssdpLocation = entry.ssdpLocation ?? result.location
            entry.ssdpST = entry.ssdpST ?? result.st
            entry.ssdpUSN = entry.ssdpUSN ?? result.usn
            let device = devices.first(where: { $0.ip == result.ip })
            allHosts[index] = applyHostConfidence(entry, device: device)
        } else {
            let entry = HostEntry(
                id: result.ip,
                ip: result.ip,
                isAlive: true,
                openPorts: [],
                hostname: nil,
                macAddress: nil,
                vendor: nil,
                vendorConfidenceScore: 0,
                vendorConfidenceReasons: [],
                hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
                ssdpServer: result.server,
                ssdpLocation: result.location,
                ssdpST: result.st,
                ssdpUSN: result.usn,
                bonjourServices: [],
                httpStatus: nil,
                httpServer: nil,
                httpAuth: nil,
                httpTitle: nil
            )
            allHosts.append(applyHostConfidence(entry, device: devices.first(where: { $0.ip == result.ip })))
        }
        allHosts.sort { $0.ip < $1.ip }
        updateDeviceConfidence(forIP: result.ip)
    }

    private func mergeBonjourResult(_ result: BonjourDiscoveryResult) {
        guard let ip = result.ip else { return }
        if let index = allHosts.firstIndex(where: { $0.ip == ip }) {
            var entry = allHosts[index]
            entry.isAlive = true
            if !entry.bonjourServices.contains(result.service) {
                entry.bonjourServices.append(result.service)
            }
            let device = devices.first(where: { $0.ip == ip })
            allHosts[index] = applyHostConfidence(entry, device: device)
        } else {
            let entry = HostEntry(
                id: ip,
                ip: ip,
                isAlive: true,
                openPorts: [],
                hostname: nil,
                macAddress: nil,
                vendor: nil,
                vendorConfidenceScore: 0,
                vendorConfidenceReasons: [],
                hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
                ssdpServer: nil,
                ssdpLocation: nil,
                ssdpST: nil,
                ssdpUSN: nil,
                bonjourServices: [result.service],
                httpStatus: nil,
                httpServer: nil,
                httpAuth: nil,
                httpTitle: nil
            )
            allHosts.append(applyHostConfidence(entry, device: devices.first(where: { $0.ip == ip })))
        }
        allHosts.sort { $0.ip < $1.ip }
    }

    private func scanHost(ip: String, portSemaphore: AsyncSemaphore) async -> HostScanResult {
        var openPorts: [Int] = []
        for port in ports {
            let isOpen = await probePort(ip: ip, port: port, timeout: portTimeout, semaphore: portSemaphore)
            if isOpen {
                openPorts.append(port)
            }
        }

        let title = openPorts.isEmpty ? nil : await fetchHTTPTitle(ip: ip, openPorts: openPorts)
        let device = openPorts.isEmpty ? nil : makeDevice(ip: ip, openPorts: openPorts, httpTitle: title)
        return HostScanResult(ip: ip, openPorts: openPorts, httpTitle: title, device: device)
    }

    private func makeDevice(ip: String, openPorts: [Int], httpTitle: String?) -> Device {
        Device(
            id: ip,
            ip: ip,
            openPorts: openPorts,
            httpTitle: httpTitle,
            macAddress: nil,
            vendor: nil,
            hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
            vendorConfidenceScore: 0,
            vendorConfidenceReasons: [],
            discoveredViaOnvif: false,
            onvifXAddrs: [],
            onvifTypes: nil,
            onvifScopes: nil,
            onvifRtspURI: nil,
            onvifRequiresAuth: false,
            onvifLastError: nil,
            username: "",
            password: "",
            rtspProbeInProgress: false,
            rtspProbeResults: [],
            bestRtspURI: nil,
            lastRtspProbeSummary: nil
        )
    }

    func updateCredentials(for deviceID: String, username: String, password: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].username = username
        devices[index].password = password
    }

    func probeRtsp(for deviceID: String) {
        if safeModeEnabled {
            logStore.log(.warn, "Safe Mode on: blocked RTSP probe for \(deviceID)")
            return
        }
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        if devices[index].rtspProbeInProgress { return }
        devices[index].rtspProbeInProgress = true
        devices[index].rtspProbeResults = []
        devices[index].lastRtspProbeSummary = nil
        Task {
            await runRtspProbe(deviceID: deviceID)
        }
    }

    private func runRtspProbe(deviceID: String) async {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let device = devices[index]
        logStore.log(.info, "RTSP probe started for \(device.ip)")

        let results = await RTSPProber.probe(
            ip: device.ip,
            username: device.username,
            password: device.password,
            semaphore: rtspProbeSemaphore,
            log: { level, message in
                LogStore.shared.log(level, message)
            }
        )

        let successes = results.filter { $0.success }
        let best = successes.first?.uri
        let summary = successes.isEmpty ? "No working RTSP URLs found" : "Found \(successes.count) working RTSP URLs"

        if let updateIndex = devices.firstIndex(where: { $0.id == deviceID }) {
            devices[updateIndex].rtspProbeResults = results
            devices[updateIndex].bestRtspURI = best
            devices[updateIndex].lastRtspProbeSummary = summary
            devices[updateIndex].rtspProbeInProgress = false
            let host = allHosts.first(where: { $0.ip == devices[updateIndex].ip })
            devices[updateIndex] = applyDeviceConfidence(devices[updateIndex], host: host)
            updateHostConfidence(forIP: devices[updateIndex].ip)
        }

        logStore.log(.info, "RTSP probe finished for \(device.ip): \(summary)")
    }

    private func recordHostResult(_ result: HostScanResult) {
        let isAlive = !result.openPorts.isEmpty
        if let index = allHosts.firstIndex(where: { $0.ip == result.ip }) {
            var entry = allHosts[index]
            entry.isAlive = entry.isAlive || isAlive
            entry.openPorts = result.openPorts.sorted()
            if entry.httpTitle == nil {
                entry.httpTitle = result.httpTitle
            }
            let device = devices.first(where: { $0.ip == result.ip })
            allHosts[index] = applyHostConfidence(entry, device: device)
        } else {
            allHosts.append(
                applyHostConfidence(HostEntry(
                    id: result.ip,
                    ip: result.ip,
                    isAlive: isAlive,
                    openPorts: result.openPorts.sorted(),
                    hostname: nil,
                    macAddress: nil,
                    vendor: nil,
                    vendorConfidenceScore: 0,
                    vendorConfidenceReasons: [],
                    hostConfidence: HostConfidence(score: 0, level: .low, reasons: []),
                    ssdpServer: nil,
                    ssdpLocation: nil,
                    ssdpST: nil,
                    ssdpUSN: nil,
                    bonjourServices: [],
                    httpStatus: nil,
                    httpServer: nil,
                    httpAuth: nil,
                    httpTitle: result.httpTitle
                ), device: devices.first(where: { $0.ip == result.ip }))
            )
        }
        allHosts.sort { $0.ip < $1.ip }
        updateDeviceConfidence(forIP: result.ip)
    }

    private func resolveHostnames() async {
        guard !allHosts.isEmpty else { return }
        await OUIStore.shared.loadPreferredIfNeeded(log: logStore)
        logStore.log(.info, "Hostname lookups started")
        await withTaskGroup(of: (String, String?).self) { group in
            for host in allHosts {
                await hostnameSemaphore.wait()
                group.addTask {
                    defer { Task { await self.hostnameSemaphore.signal() } }
                    let name = await self.reverseDNS(ip: host.ip, timeout: self.hostnameTimeout)
                    return (host.ip, name)
                }
            }

            for await (ip, name) in group {
                if let name = name, !name.isEmpty {
                    await MainActor.run {
                        if let index = self.allHosts.firstIndex(where: { $0.ip == ip }) {
                            var entry = self.allHosts[index]
                            entry.hostname = name
                            let device = self.devices.first(where: { $0.ip == ip })
                            self.allHosts[index] = self.applyHostConfidence(entry, device: device)
                            self.updateDeviceConfidence(forIP: ip)
                        }
                    }
                }
            }
        }
        logStore.log(.info, "Hostname lookups finished")
    }

    func refreshARP() {
        Task {
            await refreshARPInternal()
        }
    }

    private func refreshARPInternal() async {
        let output = await runARP()
        let parsed = parseARP(output)
        logStore.log(.info, "ARP parsed entries: \(parsed.count)")
        var macFound = 0
        var vendorHit = 0
        var vendorMiss = 0
        var markedAlive = 0
        await OUIStore.shared.loadPreferredIfNeeded(log: logStore)

        for (ip, mac) in parsed {
            if let index = allHosts.firstIndex(where: { $0.ip == ip }) {
                allHosts[index].macAddress = mac
                if !allHosts[index].isAlive {
                    allHosts[index].isAlive = true
                    markedAlive += 1
                }
                macFound += 1
                let vendor = await OUIStore.shared.vendorForMAC(mac)
                if let vendor = vendor {
                    allHosts[index].vendor = vendor
                    vendorHit += 1
                } else {
                    allHosts[index].vendor = nil
                    vendorMiss += 1
                }
                let device = devices.first(where: { $0.ip == ip })
                allHosts[index] = applyHostConfidence(allHosts[index], device: device)
            }
            if let index = devices.firstIndex(where: { $0.ip == ip }) {
                devices[index].macAddress = mac
                let vendor = await OUIStore.shared.vendorForMAC(mac)
                devices[index].vendor = vendor
                let host = allHosts.first(where: { $0.ip == ip })
                devices[index] = applyDeviceConfidence(devices[index], host: host)
            }
        }

        logStore.log(.info, "ARP hosts with MAC: \(macFound)")
        logStore.log(.info, "ARP marked alive: \(markedAlive)")
        logStore.log(.info, "OUI vendor hits: \(vendorHit), misses: \(vendorMiss)")
        logConfidenceStats(context: "ARP vendor scoring")
    }

    private func reloadOUIAndRefreshVendors() async {
        logStore.log(.info, "OUI reload started")
        let count = await OUIStore.shared.reloadPreferred(log: logStore) ?? 0
        guard count > 0 else {
            logStore.log(.error, "OUI reload failed")
            return
        }
        logStore.log(.info, "OUI reload success: \(count) entries")
        let updated = await refreshVendorsAfterOUIReload()
        logStore.log(.info, "OUI vendor updates: hosts \(updated.hosts), devices \(updated.devices)")
        logConfidenceStats(context: "OUI reload vendor scoring")
    }

    private func refreshVendorsAfterOUIReload() async -> (hosts: Int, devices: Int) {
        var hostUpdated = 0
        var deviceUpdated = 0

        for index in allHosts.indices {
            guard let mac = allHosts[index].macAddress else { continue }
            let vendor = await OUIStore.shared.vendorForMAC(mac)
            if allHosts[index].vendor != vendor {
                hostUpdated += 1
            }
            allHosts[index].vendor = vendor
            let device = devices.first(where: { $0.ip == allHosts[index].ip })
            allHosts[index] = applyHostConfidence(allHosts[index], device: device)
        }

        for index in devices.indices {
            guard let mac = devices[index].macAddress else { continue }
            let vendor = await OUIStore.shared.vendorForMAC(mac)
            if devices[index].vendor != vendor {
                deviceUpdated += 1
            }
            devices[index].vendor = vendor
            let host = allHosts.first(where: { $0.ip == devices[index].ip })
            devices[index] = applyDeviceConfidence(devices[index], host: host)
        }

        return (hostUpdated, deviceUpdated)
    }

    private func updateDeviceConfidence(forIP ip: String) {
        if let deviceIndex = devices.firstIndex(where: { $0.ip == ip }) {
            let host = allHosts.first(where: { $0.ip == ip })
            devices[deviceIndex] = applyDeviceConfidence(devices[deviceIndex], host: host)
        }
    }

    private func updateHostConfidence(forIP ip: String) {
        if let hostIndex = allHosts.firstIndex(where: { $0.ip == ip }) {
            let device = devices.first(where: { $0.ip == ip })
            allHosts[hostIndex] = applyHostConfidence(allHosts[hostIndex], device: device)
        }
    }

    private func applyHostConfidence(_ host: HostEntry, device: Device?) -> HostEntry {
        var updated = host
        let vendorResult = computeVendorConfidence(
            vendor: host.vendor,
            mac: host.macAddress,
            hostname: host.hostname,
            httpServer: host.httpServer,
            httpTitle: host.httpTitle,
            ssdpServer: host.ssdpServer,
            ssdpST: host.ssdpST,
            ssdpUSN: host.ssdpUSN,
            ssdpLocation: host.ssdpLocation
        )
        updated.vendorConfidenceScore = vendorResult.score
        updated.vendorConfidenceReasons = vendorResult.reasons

        let hostResult = computeHostConfidence(host: host, device: device)
        updated.hostConfidence = hostResult
        return updated
    }

    private func applyDeviceConfidence(_ device: Device, host: HostEntry?) -> Device {
        var updated = device
        let result = computeVendorConfidence(
            vendor: device.vendor ?? host?.vendor,
            mac: device.macAddress ?? host?.macAddress,
            hostname: host?.hostname,
            httpServer: host?.httpServer,
            httpTitle: device.httpTitle ?? host?.httpTitle,
            ssdpServer: host?.ssdpServer,
            ssdpST: host?.ssdpST,
            ssdpUSN: host?.ssdpUSN,
            ssdpLocation: host?.ssdpLocation
        )
        updated.vendorConfidenceScore = result.score
        updated.vendorConfidenceReasons = result.reasons
        let hostResult = computeHostConfidence(host: host, device: device)
        updated.hostConfidence = hostResult
        return updated
    }

    private func computeHostConfidence(host: HostEntry?, device: Device?) -> HostConfidence {
        guard let host else {
            return HostConfidence(score: 0, level: .low, reasons: [])
        }

        var score = 0
        var reasons: [String] = []

        if let device = device, !device.onvifXAddrs.isEmpty {
            score += 40
            reasons.append("ONVIF XAddrs present (+40)")
        } else if device?.discoveredViaOnvif == true {
            score += 10
            reasons.append("ONVIF discovery without XAddrs (+10)")
        }

        if let device = device, device.rtspProbeResults.contains(where: { $0.success }) {
            score += 25
            reasons.append("RTSP probe success (+25)")
        } else if host.openPorts.contains(554) {
            score += 10
            reasons.append("RTSP port 554 open (+10)")
        }

        let httpStatus = host.httpStatus
        if let status = httpStatus {
            if status == 200 || status == 401 || status == 403 {
                score += 10
                reasons.append("HTTP UI responds (\(status)) (+10)")
            } else if status == 404 {
                score += 5
                reasons.append("HTTP reachable (404) (+5)")
            }
        }

        let httpEvidence = [host.httpServer, host.httpTitle].compactMap { $0 }.joined(separator: " ").lowercased()
        if looksCameraLike(httpEvidence) {
            score += 15
            reasons.append("HTTP fingerprint looks camera-like (+15)")
        }

        let ssdpEvidence = [host.ssdpServer, host.ssdpST, host.ssdpUSN, host.ssdpLocation].compactMap { $0 }.joined(separator: " ").lowercased()
        if looksMediaLike(ssdpEvidence) {
            score += 15
            reasons.append("SSDP indicates media/camera device (+15)")
        }

        if host.openPorts.contains(8000) {
            score += 10
            reasons.append("Port 8000 open (+10)")
        }
        if host.openPorts.contains(8554) {
            score += 5
            reasons.append("Port 8554 open (+5)")
        }

        if let vendor = host.vendor, !vendor.isEmpty {
            if looksCameraVendor(vendor.lowercased()) {
                score += 10
                reasons.append("Vendor matches camera brand (+10)")
            } else {
                score += 5
                reasons.append("Vendor/OUI match (+5)")
            }
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
        return HostConfidence(score: score, level: level, reasons: reasons)
    }

    private func looksCameraLike(_ text: String) -> Bool {
        let keywords = [
            "camera", "ipcam", "webcam", "nvr", "dvr", "surveillance",
            "hikvision", "dahua", "axis", "reolink", "amcrest",
            "unifi", "ubiquiti", "foscam", "lorex", "annke", "vivotek"
        ]
        return keywords.contains { text.contains($0) }
    }

    private func looksMediaLike(_ text: String) -> Bool {
        let keywords = [
            "media", "mediaserver", "camera", "ipcamera", "nvr", "dvr", "av", "upnp"
        ]
        return keywords.contains { text.contains($0) }
    }

    private func looksCameraVendor(_ vendor: String) -> Bool {
        let keywords = [
            "hikvision", "dahua", "axis", "reolink", "amcrest", "unifi",
            "ubiquiti", "foscam", "lorex", "annke", "vivotek", "swann", "hanwha"
        ]
        return keywords.contains { vendor.contains($0) }
    }

    private func logHostConfidenceSummaryIfNeeded() {
        guard !hostConfidenceLoggedForScan else { return }
        let scored = allHosts.count
        let high = allHosts.filter { $0.hostConfidence.level == .high }.count
        let med = allHosts.filter { $0.hostConfidence.level == .medium }.count
        let low = allHosts.filter { $0.hostConfidence.level == .low }.count
        logStore.log(.info, "Scored hosts: \(scored) (high: \(high), med: \(med), low: \(low))")
        hostConfidenceLoggedForScan = true
    }

    private func computeVendorConfidence(
        vendor: String?,
        mac: String?,
        hostname: String?,
        httpServer: String?,
        httpTitle: String?,
        ssdpServer: String?,
        ssdpST: String?,
        ssdpUSN: String?,
        ssdpLocation: String?
    ) -> (score: Int, reasons: [String]) {
        guard let vendor = vendor, !vendor.isEmpty else {
            return (0, ["No OUI match"])
        }

        var score = 60
        var reasons: [String] = ["OUI vendor match (+60)"]
        let keywords = vendorKeywords(vendor)

        if let httpServer = httpServer, containsVendor(keyword: keywords, in: httpServer) {
            score += 10
            reasons.append("HTTP server matches vendor (+10)")
        }
        if let httpTitle = httpTitle, containsVendor(keyword: keywords, in: httpTitle) {
            score += 10
            reasons.append("HTTP title matches vendor (+10)")
        }

        let ssdpFields = [ssdpServer, ssdpST, ssdpUSN, ssdpLocation].compactMap { $0 }
        if ssdpFields.contains(where: { containsVendor(keyword: keywords, in: $0) }) {
            score += 10
            reasons.append("SSDP/UPnP evidence matches vendor (+10)")
        }

        if let hostname = hostname, containsVendor(keyword: keywords, in: hostname) {
            score += 5
            reasons.append("Hostname matches vendor (+5)")
        }

        if let mac = mac, isLocallyAdministered(mac: mac) {
            score -= 5
            reasons.append("Locally administered MAC (-5)")
        }

        score = max(0, min(100, score))
        return (score, reasons)
    }

    private func vendorKeywords(_ vendor: String) -> [String] {
        let cleaned = vendor.lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let parts = cleaned.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let stopwords: Set<String> = [
            "inc", "ltd", "llc", "corp", "co", "company", "corporation", "gmbh",
            "ag", "sa", "srl", "plc", "limited", "group", "international",
            "technology", "technologies", "systems", "electronics", "holdings"
        ]
        let filtered = parts.filter { $0.count >= 3 && !stopwords.contains($0) }
        if filtered.isEmpty {
            return [cleaned.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return Array(filtered.prefix(3))
    }

    private func containsVendor(keyword: [String], in text: String) -> Bool {
        let haystack = text.lowercased()
        return keyword.contains(where: { !$0.isEmpty && haystack.contains($0) })
    }

    private func isLocallyAdministered(mac: String) -> Bool {
        let normalized = mac.uppercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        guard normalized.count >= 2 else { return false }
        let prefix = String(normalized.prefix(2))
        guard let value = UInt8(prefix, radix: 16) else { return false }
        return (value & 0x02) != 0
    }

    private func logConfidenceStats(context: String) {
        let hostScored = allHosts.filter { ($0.vendor ?? "").isEmpty == false }.count
        let hostHigh = allHosts.filter { $0.vendorConfidenceScore >= 80 }.count
        let deviceScored = devices.filter { ($0.vendor ?? "").isEmpty == false }.count
        let deviceHigh = devices.filter { $0.vendorConfidenceScore >= 80 }.count
        logStore.log(.info, "\(context): hosts scored \(hostScored), high-confidence \(hostHigh); devices scored \(deviceScored), high-confidence \(deviceHigh)")
    }

    private func runARP() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
                process.arguments = ["-an"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }

    private func parseARP(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = output.split(whereSeparator: \.isNewline)
        for lineSub in lines {
            let line = String(lineSub)
            if line.contains("incomplete") { continue }
            guard let ipStart = line.firstIndex(of: "(") else { continue }
            guard let ipEnd = line.firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: ipStart)..<ipEnd])
            if let range = line.range(of: " at ") {
                let remainder = line[range.upperBound...]
                let macParts = remainder.split(separator: " ")
                guard let mac = macParts.first else { continue }
                let macStr = String(mac)
                result[ip] = macStr
            }
        }
        return result
    }

private func reverseDNS(ip: String, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        var addr = sockaddr_in()
                        addr.sin_family = sa_family_t(AF_INET)
                        addr.sin_port = 0
                        inet_pton(AF_INET, ip, &addr.sin_addr)
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NAMEREQD)
                            }
                        }
                        if result == 0 {
                            continuation.resume(returning: String(cString: hostBuffer))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @MainActor
    func buildAuditLog() -> AuditLog? {
        guard let start = lastScanStart, let end = lastScanEnd else { return nil }
        let formatter = ISO8601DateFormatter()
        let scope = lastScanScopeDescription.isEmpty ? (subnetDescription ?? "") : lastScanScopeDescription

        var evidence: [AuditLog.Evidence] = []
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) })
        for host in allHosts {
            var services: [String] = []
            if host.openPorts.contains(80) || host.openPorts.contains(8080) || host.openPorts.contains(8000) {
                services.append("http")
            }
            if host.openPorts.contains(443) || host.openPorts.contains(8443) {
                services.append("https")
            }
            if host.openPorts.contains(554) {
                services.append("rtsp")
            }
            if host.openPorts.contains(3702) {
                services.append("onvif")
            }
            if let device = deviceMap[host.ip], let title = device.httpTitle, !title.isEmpty {
                services.append("http-title:\(title)")
            } else if let title = host.httpTitle, !title.isEmpty {
                services.append("http-title:\(title)")
            }
            let item = AuditLog.Evidence(
                ip: host.ip,
                mac: host.macAddress ?? "",
                vendor: host.vendor ?? "",
                vendorConfidenceScore: host.vendorConfidenceScore,
                vendorConfidenceReasons: host.vendorConfidenceReasons,
                hostConfidence: host.hostConfidence,
                services: services,
                ports: host.openPorts,
                hostname: host.hostname,
                ssdpServer: host.ssdpServer ?? "",
                ssdpLocation: host.ssdpLocation ?? "",
                ssdpST: host.ssdpST ?? "",
                ssdpUSN: host.ssdpUSN ?? "",
                bonjourServices: host.bonjourServices,
                httpStatus: host.httpStatus,
                httpServer: host.httpServer ?? "",
                httpAuth: host.httpAuth ?? "",
                httpTitle: host.httpTitle ?? ""
            )
            evidence.append(item)
        }

        let bleEvidence = BLEScanner.shared.snapshotEvidence()
        let bleProbeResults = BLEProber.shared.snapshotProbeResults()
        let piAuxEvidence = PiAuxStore.shared.events
        return AuditLog(
            exportedAt: formatter.string(from: Date()),
            scanScope: scope,
            startTime: formatter.string(from: start),
            endTime: formatter.string(from: end),
            totalIPs: lastTotalIPs,
            aliveCount: lastAliveCount,
            interestingCount: lastInterestingCount,
            evidences: evidence,
            bleDevices: bleEvidence,
            bleProbeResults: bleProbeResults,
            piAuxEvidence: piAuxEvidence,
            logLines: logStore.lines.map { $0.formatted }
        )
    }

    func buildExportSnapshot() -> ExportSnapshot? {
        guard let start = lastScanStart else { return nil }
        let formatter = ISO8601DateFormatter()
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) })
        let records: [ExportRecord] = allHosts.map { host in
            let device = deviceMap[host.ip]
            return ExportRecord(
                ip: host.ip,
                status: host.isAlive ? "Alive" : "No Response",
                ports: host.openPorts,
                hostname: host.hostname ?? "",
                mac: host.macAddress ?? "",
                vendor: host.vendor ?? "",
                vendorConfidenceScore: host.vendorConfidenceScore,
                vendorConfidenceReasons: host.vendorConfidenceReasons,
                hostConfidence: host.hostConfidence,
                ssdpServer: host.ssdpServer ?? "",
                ssdpLocation: host.ssdpLocation ?? "",
                ssdpST: host.ssdpST ?? "",
                ssdpUSN: host.ssdpUSN ?? "",
                bonjourServices: host.bonjourServices,
                httpStatus: host.httpStatus,
                httpServer: host.httpServer ?? "",
                httpAuth: host.httpAuth ?? "",
                httpTitle: host.httpTitle ?? "",
                onvif: device?.discoveredViaOnvif ?? false,
                rtspURI: device?.onvifRtspURI ?? ""
            )
        }
        return ExportSnapshot(timestamp: formatter.string(from: start), records: records)
    }

    func fetchOnvifRtsp(for deviceID: String, reason: OnvifFetchReason = .manual) {
        if safeModeEnabled {
            logStore.log(.warn, "Safe Mode on: blocked ONVIF RTSP fetch for \(deviceID)")
            return
        }
        guard !onvifFetchInProgress.contains(deviceID) else { return }
        onvifFetchInProgress.insert(deviceID)
        Task {
            await runOnvifRtspFetch(deviceID: deviceID, reason: reason)
        }
    }

    private func runOnvifRtspFetch(deviceID: String, reason: OnvifFetchReason) async {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else {
            onvifFetchInProgress.remove(deviceID)
            return
        }

        let device = devices[index]
        let xaddrs = device.onvifXAddrs
        if xaddrs.isEmpty {
            devices[index].onvifLastError = "No ONVIF XAddrs available."
            onvifFetchInProgress.remove(deviceID)
            logStore.log(.warn, "ONVIF RTSP fetch failed for \(device.ip): no XAddrs")
            return
        }

        devices[index].onvifLastError = nil
        devices[index].onvifRequiresAuth = false

        let reasonText = reason == .auto ? "auto" : "manual"
        logStore.log(.info, "ONVIF RTSP fetch started (\(reasonText)) for \(device.ip)")

        await onvifRtspSemaphore.wait()
        defer { Task { await onvifRtspSemaphore.signal() } }

        let client = ONVIFClient(semaphore: onvifSoapSemaphore)
        let result = await client.fetchRtspURI(xaddrs: xaddrs, username: device.username, password: device.password)

        if let rtsp = result.rtspURI {
            devices[index].onvifRtspURI = rtsp
            devices[index].onvifLastError = nil
            devices[index].onvifRequiresAuth = false
            logStore.log(.info, "ONVIF RTSP fetch succeeded for \(device.ip)")
        } else {
            devices[index].onvifRtspURI = nil
            let requiresAuth = result.requiresAuth || (result.errorMessage?.lowercased().contains("unauthorized") ?? false)
            devices[index].onvifRequiresAuth = requiresAuth
            if requiresAuth {
                devices[index].onvifLastError = "Auth required"
                logStore.log(.warn, "ONVIF RTSP fetch requires auth for \(device.ip)")
            } else {
                devices[index].onvifLastError = result.errorMessage
                if let errorMessage = result.errorMessage {
                    logStore.log(.error, "ONVIF RTSP fetch failed for \(device.ip): \(errorMessage)")
                } else {
                    logStore.log(.error, "ONVIF RTSP fetch failed for \(device.ip)")
                }
            }
        }

        onvifFetchInProgress.remove(deviceID)
    }

    private func fetchHTTPTitle(ip: String, openPorts: [Int]) async -> String? {
        let httpPorts = [80, 8000, 8080]
        let httpsPorts = [443, 8443]

        for port in httpPorts where openPorts.contains(port) {
            if let title = await fetchTitle(urlString: "http://\(ip):\(port)/") {
                return title
            }
        }

        for port in httpsPorts where openPorts.contains(port) {
            if let title = await fetchTitle(urlString: "https://\(ip):\(port)/") {
                return title
            }
        }

        return nil
    }

    private func runHTTPFingerprinting() async {
        let eligibleHosts = allHosts.filter { $0.isAlive || $0.macAddress != nil }
        guard !eligibleHosts.isEmpty else { return }

        let httpPorts = [80, 8000, 8080]
        let httpsPorts = [443, 8443]
        var targets: [(String, Int, Bool)] = []
        for host in eligibleHosts {
            for port in host.openPorts where httpPorts.contains(port) {
                targets.append((host.ip, port, false))
            }
            for port in host.openPorts where httpsPorts.contains(port) {
                targets.append((host.ip, port, true))
            }
        }

        guard !targets.isEmpty else { return }
        logStore.log(.info, "HTTP fingerprinting started (\(targets.count) requests)")

        var attempted = 0
        var succeeded = 0

        await withTaskGroup(of: (String, HTTPFingerprint?).self) { group in
            for (ip, port, isHTTPS) in targets {
                attempted += 1
                group.addTask {
                    await self.httpFingerprintSemaphore.wait()
                    defer { Task { await self.httpFingerprintSemaphore.signal() } }
                    let fingerprint = await self.fetchHTTPFingerprint(ip: ip, port: port, isHTTPS: isHTTPS)
                    return (ip, fingerprint)
                }
            }

            for await (ip, fingerprint) in group {
                guard let fingerprint = fingerprint else { continue }
                succeeded += 1
                if let index = allHosts.firstIndex(where: { $0.ip == ip }) {
                    var entry = allHosts[index]
                    entry.isAlive = true
                    if entry.httpStatus == nil { entry.httpStatus = fingerprint.status }
                    if entry.httpServer == nil { entry.httpServer = fingerprint.server }
                    if entry.httpAuth == nil { entry.httpAuth = fingerprint.auth }
                    if entry.httpTitle == nil { entry.httpTitle = fingerprint.title }
                    let device = devices.first(where: { $0.ip == ip })
                    allHosts[index] = applyHostConfidence(entry, device: device)
                }
                if let deviceIndex = devices.firstIndex(where: { $0.ip == ip }) {
                    if devices[deviceIndex].httpTitle == nil {
                        devices[deviceIndex].httpTitle = fingerprint.title
                    }
                    let host = allHosts.first(where: { $0.ip == ip })
                    devices[deviceIndex] = applyDeviceConfidence(devices[deviceIndex], host: host)
                }
            }
        }

        logStore.log(.info, "HTTP fingerprinting attempted \(attempted), succeeded \(succeeded)")
        logConfidenceStats(context: "HTTP vendor scoring")
        logHostConfidenceSummaryIfNeeded()
    }

    private func fetchHTTPFingerprint(ip: String, port: Int, isHTTPS: Bool) async -> HTTPFingerprint? {
        let scheme = isHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(ip):\(port)/") else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = httpFingerprintTimeout
        config.timeoutIntervalForResource = httpFingerprintTimeout

        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = httpFingerprintTimeout
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            let server = http.value(forHTTPHeaderField: "Server")
            let auth = http.value(forHTTPHeaderField: "WWW-Authenticate")
            let title: String?
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                title = parseTitle(from: html)
            } else {
                title = nil
            }
            return HTTPFingerprint(status: http.statusCode, server: server, auth: auth, title: title)
        } catch {
            return nil
        }
    }

    private func fetchTitle(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = httpTimeout
        config.timeoutIntervalForResource = httpTimeout

        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = httpTimeout
        request.httpMethod = "GET"

        do {
            let (data, _) = try await session.data(for: request)
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                return parseTitle(from: html)
            }
        } catch {
            return nil
        }

        return nil
    }

    private func parseTitle(from html: String) -> String? {
        let lower = html.lowercased()
        guard let startRange = lower.range(of: "<title") else { return nil }
        guard let startTagEnd = lower[startRange.upperBound...].firstIndex(of: ">") else { return nil }
        let titleStart = lower.index(after: startTagEnd)
        guard let endRange = lower[titleStart...].range(of: "</title>") else { return nil }
        let title = String(html[titleStart..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func probePort(ip: String, port: Int, timeout: TimeInterval, semaphore: AsyncSemaphore) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }

        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        let finishState = FinishState()

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ success: Bool) {
                finishState.lock.lock()
                if finishState.finished {
                    finishState.lock.unlock()
                    return
                }
                finishState.finished = true
                finishState.lock.unlock()
                continuation.resume(returning: success)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue(label: "sods.probe.\(ip).\(port)"))

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(false)
            }
        }
    }

    nonisolated private static func runArpWarmup(hostIPs: [String]) async {
        let semaphore = AsyncSemaphore(value: 64)
        await withTaskGroup(of: Void.self) { group in
            for ip in hostIPs {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    await warmupConnect(ip: ip, timeout: 0.2)
                }
            }
        }
    }

    nonisolated private static func warmupConnect(ip: String, timeout: TimeInterval) async {
        guard let port = NWEndpoint.Port(rawValue: 80) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .tcp)
        let finishState = FinishState()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            @Sendable func finish() {
                finishState.lock.lock()
                if finishState.finished {
                    finishState.lock.unlock()
                    return
                }
                finishState.finished = true
                finishState.lock.unlock()
                connection.cancel()
                continuation.resume()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish()
            }
        }
    }
}

struct ScanScope {
    struct Range {
        let start: String
        let end: String
    }

    let cidr: String
    let ipRange: Range?
    let onlyLocalSubnet: Bool
}

private final class OUIFileWatcher {
    private let fileURL: URL
    private let log: LogStore
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var missingLogged = false
    private let queue = DispatchQueue(label: "sods.oui.watcher", qos: .utility)

    init(fileURL: URL, log: LogStore, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.log = log
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        fd = open(directoryURL.path, O_EVTONLY)
        if fd < 0 {
            log.log(.error, "OUI watcher failed to open directory: \(directoryURL.path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                if !self.missingLogged {
                    self.log.log(.warn, "OUI user file missing at \(self.fileURL.path)")
                    self.missingLogged = true
                }
                return
            }
            self.missingLogged = false
            self.onChange()
        }

        source?.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }

        source?.resume()
        log.log(.info, "OUI file watcher started")

        if !FileManager.default.fileExists(atPath: fileURL.path) && !missingLogged {
            log.log(.warn, "OUI user file missing at \(fileURL.path)")
            missingLogged = true
        }
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        log.log(.info, "OUI file watcher stopped")
    }

    deinit {
        stop()
    }
}

private struct ResolvedScope {
    let description: String
    let hostIPs: [String]
}

struct IPv4Subnet {
    let address: UInt32
    let netmask: UInt32

    var network: UInt32 { address & netmask }
    var broadcast: UInt32 { network | ~netmask }

    var prefixLength: Int {
        netmask.nonzeroBitCount
    }

    var addressString: String {
        IPv4Subnet.ipString(from: address)
    }

    func hostIPs() -> [String] {
        let start = network + 1
        let end = broadcast - 1
        if end <= start { return [] }
        var results: [String] = []
        results.reserveCapacity(Int(end - start + 1))
        var current = start
        while current <= end {
            results.append(IPv4Subnet.ipString(from: current))
            if current == UInt32.max { break }
            current += 1
        }
        return results
    }

    static func active() -> IPv4Subnet? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            guard isUp && !isLoopback else { continue }
            guard let addr = current.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let netmaskPtr = current.pointee.ifa_netmask else { continue }

            let sockaddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let netmaskSockaddr = netmaskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

            let ip = UInt32(bigEndian: sockaddr.sin_addr.s_addr)
            let mask = UInt32(bigEndian: netmaskSockaddr.sin_addr.s_addr)
            if mask == 0 { continue }

            return IPv4Subnet(address: ip, netmask: mask)
        }

        return nil
    }

    func contains(_ ip: UInt32) -> Bool {
        (ip & netmask) == network
    }

    static func parse(cidr: String) -> IPv4Subnet? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let ipString = String(parts[0])
        guard let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
        guard let ip = ipToUInt32(ipString) else { return nil }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        return IPv4Subnet(address: ip, netmask: mask)
    }

    static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return (UInt32(parts[0]) << 24) | (UInt32(parts[1]) << 16) | (UInt32(parts[2]) << 8) | UInt32(parts[3])
    }

    static func ipString(from value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return bytes.map(String.init).joined(separator: ".")
    }
}

private final class FinishState {
    var finished = false
    let lock = NSLock()
}

enum OnvifFetchReason {
    case auto
    case manual
}

private struct HostScanResult {
    let ip: String
    let openPorts: [Int]
    let httpTitle: String?
    let device: Device?
}

private struct HTTPFingerprint {
    let status: Int
    let server: String?
    let auth: String?
    let title: String?
}

struct ExportRecord: Codable {
    let ip: String
    let status: String
    let ports: [Int]
    let hostname: String
    let mac: String
    let vendor: String
    let vendorConfidenceScore: Int
    let vendorConfidenceReasons: [String]
    let hostConfidence: HostConfidence
    let ssdpServer: String
    let ssdpLocation: String
    let ssdpST: String
    let ssdpUSN: String
    let bonjourServices: [BonjourService]
    let httpStatus: Int?
    let httpServer: String
    let httpAuth: String
    let httpTitle: String
    let onvif: Bool
    let rtspURI: String
}

struct ExportSnapshot: Codable {
    let timestamp: String
    let records: [ExportRecord]
}
