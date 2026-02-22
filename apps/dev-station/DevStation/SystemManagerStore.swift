import Foundation
import Darwin

struct SystemSnapshot: Codable, Equatable {
    let timestamp: Date
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let cpuIdlePercent: Double
    let memTotalBytes: Int64
    let memUsedBytes: Int64
    let memFreeBytes: Int64
    let memCompressedBytes: Int64
    let swapUsedBytes: Int64
    let swapTotalBytes: Int64
    let processCount: Int
}

struct ManagedProcessRow: Identifiable, Hashable {
    let pid: Int32
    let user: String
    let cpuPercent: Double
    let rssBytes: Int64
    let command: String
    let isProtected: Bool
    let canTerminate: Bool

    var id: Int32 { pid }
}

enum SystemSortField: String, CaseIterable, Identifiable {
    case memory
    case cpu
    case name
    case pid

    var id: String { rawValue }
}

enum ProcessTerminationStatus: String, Equatable {
    case success
    case alreadyExited
    case permissionDenied
    case failed
}

struct ProcessTerminationResult: Equatable {
    let pid: Int32
    let status: ProcessTerminationStatus
    let detail: String
}

@MainActor
final class SystemManagerStore: ObservableObject {
    typealias CommandRunner = (_ executablePath: String, _ arguments: [String], _ environment: [String: String]) throws -> String
    typealias SignalSender = (_ pid: Int32, _ signal: Int32) -> Int32
    typealias ErrnoProvider = () -> Int32
    typealias SnapshotPersistor = (_ snapshot: SystemSnapshot, _ forceReload: Bool) -> Void

    struct ParsedVMStats: Equatable {
        let pageSize: Int64
        let freePages: Int64
        let speculativePages: Int64
        let compressorPages: Int64
    }

    struct ParsedSwapUsage: Equatable {
        let usedBytes: Int64
        let totalBytes: Int64
    }

    struct ParsedCPUUsage: Equatable {
        let userPercent: Double
        let systemPercent: Double
        let idlePercent: Double
    }

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var processRows: [ManagedProcessRow] = []
    @Published var selectedPIDs: Set<Int32> = []
    @Published var searchText: String = ""
    @Published var sortField: SystemSortField = .memory
    @Published var sortAscending: Bool = false
    @Published private(set) var terminationResults: [ProcessTerminationResult] = []
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var isRefreshing = false

    @Published var showOptimizeSheet = false
    @Published private(set) var optimizeCandidates: [ManagedProcessRow] = []
    @Published var optimizeSelectedPIDs: Set<Int32> = []

    private let commandRunner: CommandRunner
    private let signalSender: SignalSender
    private let errnoProvider: ErrnoProvider
    private let delayedRefreshNanoseconds: UInt64
    private let currentUser: String
    private let currentPID: Int32
    private let parentPID: Int32
    private let persistSnapshot: SnapshotPersistor

    private var refreshTimer: Timer?
    private var optimizeBaselineUsedBytes: Int64?

    private nonisolated static let protectedCommandNames: Set<String> = [
        "launchd",
        "loginwindow",
        "windowserver",
        "systemuiserver",
        "dock",
        "finder",
    ]

    init(
        currentUser: String = NSUserName(),
        currentPID: Int32 = getpid(),
        parentPID: Int32 = getppid(),
        commandRunner: @escaping CommandRunner = SystemManagerStore.liveCommandRunner,
        signalSender: @escaping SignalSender = { pid, signal in Darwin.kill(pid, signal) },
        errnoProvider: @escaping ErrnoProvider = { errno },
        delayedRefreshNanoseconds: UInt64 = 2_000_000_000,
        persistSnapshot: SnapshotPersistor? = nil
    ) {
        self.currentUser = currentUser
        self.currentPID = currentPID
        self.parentPID = parentPID
        self.commandRunner = commandRunner
        self.signalSender = signalSender
        self.errnoProvider = errnoProvider
        self.delayedRefreshNanoseconds = delayedRefreshNanoseconds
        self.persistSnapshot = persistSnapshot ?? { snapshot, forceReload in
            SystemWidgetSnapshotBridge.shared.persist(snapshot: snapshot, forceReload: forceReload)
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var filteredRows: [ManagedProcessRow] {
        let token = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates: [ManagedProcessRow]
        if token.isEmpty {
            candidates = processRows
        } else {
            candidates = processRows.filter { row in
                row.command.lowercased().contains(token)
                    || row.user.lowercased().contains(token)
                    || "\(row.pid)".contains(token)
            }
        }
        return sortedRows(candidates)
    }

    var selectedTerminableCount: Int {
        filteredRows.filter { selectedPIDs.contains($0.pid) && $0.canTerminate }.count
    }

    func startPolling() {
        guard refreshTimer == nil else { return }
        refreshNow()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshNow() {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let topText = try runCommand("/usr/bin/top", arguments: ["-l", "1", "-n", "0"])
            let vmStatText = try runCommand("/usr/bin/vm_stat", arguments: [])
            let memTotalText = try runCommand("/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
            let swapText = try runCommand("/usr/sbin/sysctl", arguments: ["-n", "vm.swapusage"])
            let processText = try runCommand("/bin/ps", arguments: ["-axo", "pid=,user=,pcpu=,rss=,comm="])

            guard let cpuUsage = Self.parseTopCPU(topText) else {
                throw SystemManagerError.parse("Unable to parse CPU stats from top output.")
            }
            guard let vmStats = Self.parseVMStat(vmStatText) else {
                throw SystemManagerError.parse("Unable to parse memory stats from vm_stat output.")
            }
            guard let swapUsage = Self.parseSwapUsage(swapText) else {
                throw SystemManagerError.parse("Unable to parse swap stats from vm.swapusage output.")
            }
            guard let memTotal = Int64(memTotalText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SystemManagerError.parse("Unable to parse total memory from hw.memsize output.")
            }

            let rows = Self.parseProcessRows(
                processText,
                currentUser: currentUser,
                currentPID: currentPID,
                parentPID: parentPID
            )
            processRows = rows
            let validPIDs = Set(rows.map(\.pid))
            selectedPIDs = selectedPIDs.intersection(validPIDs)

            let freeBytes = max(0, vmStats.freePages + vmStats.speculativePages) * vmStats.pageSize
            let usedBytes = max(0, memTotal - freeBytes)
            let compressedBytes = max(0, vmStats.compressorPages) * vmStats.pageSize
            let now = Date()

            let nextSnapshot = SystemSnapshot(
                timestamp: now,
                cpuUserPercent: cpuUsage.userPercent,
                cpuSystemPercent: cpuUsage.systemPercent,
                cpuIdlePercent: cpuUsage.idlePercent,
                memTotalBytes: memTotal,
                memUsedBytes: usedBytes,
                memFreeBytes: freeBytes,
                memCompressedBytes: compressedBytes,
                swapUsedBytes: swapUsage.usedBytes,
                swapTotalBytes: swapUsage.totalBytes,
                processCount: rows.count
            )
            snapshot = nextSnapshot
            lastRefreshAt = now
            lastError = nil
            persistSnapshot(nextSnapshot, false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func terminateSelectedProcesses(selected: Set<Int32>? = nil) {
        let requested = selected ?? selectedPIDs
        guard !requested.isEmpty else {
            lastActionMessage = "No process selected."
            terminationResults = []
            return
        }

        let rowMap = Dictionary(uniqueKeysWithValues: processRows.map { ($0.pid, $0) })
        let targets = requested.compactMap { pid -> ManagedProcessRow? in
            guard let row = rowMap[pid], row.canTerminate else { return nil }
            return row
        }
        guard !targets.isEmpty else {
            lastActionMessage = "No terminable process selected."
            terminationResults = []
            return
        }

        var results: [ProcessTerminationResult] = []
        results.reserveCapacity(targets.count)
        var successCount = 0
        var exitCount = 0
        var deniedCount = 0
        var failedCount = 0

        for row in targets {
            let rc = signalSender(row.pid, SIGTERM)
            if rc == 0 {
                successCount += 1
                results.append(
                    ProcessTerminationResult(
                        pid: row.pid,
                        status: .success,
                        detail: "PID \(row.pid): sent SIGTERM."
                    )
                )
                continue
            }

            let code = errnoProvider()
            if code == ESRCH {
                exitCount += 1
                results.append(
                    ProcessTerminationResult(
                        pid: row.pid,
                        status: .alreadyExited,
                        detail: "PID \(row.pid): process already exited."
                    )
                )
            } else if code == EPERM {
                deniedCount += 1
                results.append(
                    ProcessTerminationResult(
                        pid: row.pid,
                        status: .permissionDenied,
                        detail: "PID \(row.pid): permission denied."
                    )
                )
            } else {
                failedCount += 1
                results.append(
                    ProcessTerminationResult(
                        pid: row.pid,
                        status: .failed,
                        detail: "PID \(row.pid): kill failed (errno \(code))."
                    )
                )
            }
        }

        terminationResults = results.sorted { $0.pid < $1.pid }
        lastActionMessage = "Terminate complete. Success: \(successCount), Exited: \(exitCount), Denied: \(deniedCount), Failed: \(failedCount)."

        refreshNow()
        guard delayedRefreshNanoseconds > 0 else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.delayedRefreshNanoseconds)
            self.refreshNow()
        }
    }

    func optimizeCleanRAMGuided() {
        let candidates = filteredRows
            .filter(\.canTerminate)
            .sorted { $0.rssBytes > $1.rssBytes }
        guard !candidates.isEmpty else {
            lastActionMessage = "No terminable process available for guided cleanup."
            optimizeCandidates = []
            optimizeSelectedPIDs = []
            showOptimizeSheet = false
            return
        }

        let topCandidates = Array(candidates.prefix(10))
        optimizeCandidates = topCandidates
        optimizeSelectedPIDs = Set(topCandidates.prefix(3).map(\.pid))
        optimizeBaselineUsedBytes = snapshot?.memUsedBytes
        showOptimizeSheet = true
        lastActionMessage = "Guided cleanup prepared. Select processes and confirm."
    }

    func setOptimizeSelection(pid: Int32, enabled: Bool) {
        if enabled {
            optimizeSelectedPIDs.insert(pid)
        } else {
            optimizeSelectedPIDs.remove(pid)
        }
    }

    func cancelOptimizeGuided() {
        showOptimizeSheet = false
        optimizeCandidates = []
        optimizeSelectedPIDs = []
    }

    func confirmOptimizeGuided() {
        let selected = optimizeSelectedPIDs
        let baseline = optimizeBaselineUsedBytes ?? snapshot?.memUsedBytes
        showOptimizeSheet = false
        optimizeCandidates = []
        optimizeSelectedPIDs = []

        guard !selected.isEmpty else {
            lastActionMessage = "Optimize canceled: no process selected."
            return
        }

        terminateSelectedProcesses(selected: selected)

        guard let baseline else {
            persistCurrentSnapshot(forceReload: true)
            return
        }

        let delay = max(delayedRefreshNanoseconds + 300_000_000, 500_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            let after = self.snapshot?.memUsedBytes ?? baseline
            let reclaimed = max(0, baseline - after)
            let formatted = Self.memoryFormatter.string(fromByteCount: reclaimed)
            self.lastActionMessage = "Optimize complete. Estimated memory reclaimed: \(formatted)."
            self.persistCurrentSnapshot(forceReload: true)
        }
    }

    private func persistCurrentSnapshot(forceReload: Bool) {
        guard let snapshot else { return }
        persistSnapshot(snapshot, forceReload)
    }

    private func runCommand(_ executablePath: String, arguments: [String]) throws -> String {
        try commandRunner(executablePath, arguments, ["LC_ALL": "C"])
    }

    private func sortedRows(_ rows: [ManagedProcessRow]) -> [ManagedProcessRow] {
        rows.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortField {
            case .memory:
                result = compare(lhs.rssBytes, rhs.rssBytes)
            case .cpu:
                result = compare(lhs.cpuPercent, rhs.cpuPercent)
            case .name:
                result = lhs.command.localizedCaseInsensitiveCompare(rhs.command)
            case .pid:
                result = compare(lhs.pid, rhs.pid)
            }

            switch result {
            case .orderedAscending:
                return sortAscending
            case .orderedDescending:
                return !sortAscending
            case .orderedSame:
                return lhs.pid < rhs.pid
            }
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    nonisolated static func parseVMStat(_ text: String) -> ParsedVMStats? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }

        var pageSize: Int64?
        var freePages: Int64 = 0
        var speculativePages: Int64 = 0
        var compressorPages: Int64 = 0

        for line in lines {
            let lower = line.lowercased()
            if pageSize == nil, lower.contains("page size of"), let value = firstInteger(in: line) {
                pageSize = value
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = String(line[line.index(after: separator)...])
            guard let value = firstInteger(in: rawValue) else { continue }

            switch key {
            case "pages free":
                freePages = value
            case "pages speculative":
                speculativePages = value
            case "pages occupied by compressor":
                compressorPages = value
            default:
                continue
            }
        }

        guard let pageSize, pageSize > 0 else { return nil }
        return ParsedVMStats(
            pageSize: pageSize,
            freePages: freePages,
            speculativePages: speculativePages,
            compressorPages: compressorPages
        )
    }

    nonisolated static func parseSwapUsage(_ text: String) -> ParsedSwapUsage? {
        let total = firstNumberWithUnit(pattern: #"total\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTP])"#, in: text)
        let used = firstNumberWithUnit(pattern: #"used\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTP])"#, in: text)
        guard let total, let used else { return nil }
        return ParsedSwapUsage(usedBytes: used, totalBytes: total)
    }

    nonisolated static func parseTopCPU(_ text: String) -> ParsedCPUUsage? {
        guard let groups = firstMatchGroups(
            pattern: #"CPU usage:\s*([0-9]+(?:\.[0-9]+)?)%\s*user,\s*([0-9]+(?:\.[0-9]+)?)%\s*sys,\s*([0-9]+(?:\.[0-9]+)?)%\s*idle"#,
            in: text
        ), groups.count == 3 else {
            return nil
        }
        guard let user = Double(groups[0]),
              let system = Double(groups[1]),
              let idle = Double(groups[2]) else {
            return nil
        }
        return ParsedCPUUsage(userPercent: user, systemPercent: system, idlePercent: idle)
    }

    nonisolated static func parseProcessRows(
        _ text: String,
        currentUser: String,
        currentPID: Int32,
        parentPID: Int32
    ) -> [ManagedProcessRow] {
        var rows: [ManagedProcessRow] = []
        rows.reserveCapacity(256)

        let normalizedUser = currentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in text.split(whereSeparator: \.isNewline) {
            let row = String(line)
            guard let groups = firstMatchGroups(
                pattern: #"^\s*(\d+)\s+(\S+)\s+([0-9]+(?:\.[0-9]+)?)\s+(\d+)\s+(.+)$"#,
                in: row
            ), groups.count == 5 else {
                continue
            }

            guard let pidValue = Int32(groups[0]) else { continue }
            let user = groups[1]
            guard user == normalizedUser else { continue }
            guard let cpu = Double(groups[2]) else { continue }
            guard let rssKB = Int64(groups[3]) else { continue }

            let command = groups[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let isProtected = isProtectedProcess(
                pid: pidValue,
                command: command,
                currentPID: currentPID,
                parentPID: parentPID
            )

            rows.append(
                ManagedProcessRow(
                    pid: pidValue,
                    user: user,
                    cpuPercent: cpu,
                    rssBytes: max(0, rssKB) * 1024,
                    command: command,
                    isProtected: isProtected,
                    canTerminate: !isProtected
                )
            )
        }

        return rows
    }

    nonisolated static func isProtectedProcess(pid: Int32, command: String, currentPID: Int32, parentPID: Int32) -> Bool {
        if pid <= 1 { return true }
        if pid == currentPID { return true }
        if pid == parentPID { return true }

        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return true }
        let basename = (lowered as NSString).lastPathComponent
        if protectedCommandNames.contains(basename) { return true }
        if protectedCommandNames.contains(lowered) { return true }
        return false
    }

    private nonisolated static func firstInteger(in text: String) -> Int64? {
        text
            .split { !$0.isNumber }
            .compactMap { Int64($0) }
            .first
    }

    private nonisolated static func firstNumberWithUnit(pattern: String, in text: String) -> Int64? {
        guard let groups = firstMatchGroups(pattern: pattern, in: text), groups.count == 2 else {
            return nil
        }
        guard let value = Double(groups[0]) else { return nil }
        let unit = groups[1].uppercased()
        let multiplier: Double
        switch unit {
        case "K":
            multiplier = 1_024
        case "M":
            multiplier = 1_024 * 1_024
        case "G":
            multiplier = 1_024 * 1_024 * 1_024
        case "T":
            multiplier = 1_024 * 1_024 * 1_024 * 1_024
        case "P":
            multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024
        default:
            return nil
        }
        return Int64(value * multiplier)
    }

    private nonisolated static func firstMatchGroups(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return [] }

        var groups: [String] = []
        groups.reserveCapacity(match.numberOfRanges - 1)
        for idx in 1..<match.numberOfRanges {
            let groupRange = match.range(at: idx)
            guard let swiftRange = Range(groupRange, in: text) else {
                groups.append("")
                continue
            }
            groups.append(String(text[swiftRange]))
        }
        return groups
    }

    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private nonisolated static func liveCommandRunner(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SystemManagerError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: -1,
                detail: error.localizedDescription
            )
        }

        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
            throw SystemManagerError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout
    }

    enum SystemManagerError: LocalizedError {
        case parse(String)
        case commandFailed(command: String, status: Int32, detail: String)

        var errorDescription: String? {
            switch self {
            case .parse(let message):
                return message
            case .commandFailed(let command, let status, let detail):
                if detail.isEmpty {
                    return "Command failed (\(status)): \(command)"
                }
                return "Command failed (\(status)): \(command) — \(detail)"
            }
        }
    }
}
