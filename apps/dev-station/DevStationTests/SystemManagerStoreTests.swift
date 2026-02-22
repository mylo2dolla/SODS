import XCTest
@testable import DevStation

final class SystemManagerStoreTests: XCTestCase {
    func testParseVMStatOutput() {
        let sample = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                4016.
        Pages active:                            205155.
        Pages inactive:                          202899.
        Pages speculative:                         1483.
        Pages occupied by compressor:            437081.
        """

        let parsed = SystemManagerStore.parseVMStat(sample)
        XCTAssertEqual(parsed?.pageSize, 16_384)
        XCTAssertEqual(parsed?.freePages, 4_016)
        XCTAssertEqual(parsed?.speculativePages, 1_483)
        XCTAssertEqual(parsed?.compressorPages, 437_081)
    }

    func testParseSwapUsageOutput() {
        let sample = "vm.swapusage: total = 2048.00M  used = 1396.10M  free = 651.90M  (encrypted)"
        let parsed = SystemManagerStore.parseSwapUsage(sample)
        XCTAssertEqual(parsed?.totalBytes, 2_147_483_648)
        XCTAssertEqual(parsed?.usedBytes, 1_463_916_953)
    }

    func testParseProcessRowsHandlesSpacingAndFiltersUser() {
        let sample = """
          101 tester  2.5  2048 /Applications/Dev Station.app/Contents/MacOS/DevStation
          102 tester  0.1   512 /usr/bin/python3
          999 root    0.0   256 /sbin/launchd
        """

        let rows = SystemManagerStore.parseProcessRows(
            sample,
            currentUser: "tester",
            currentPID: 101,
            parentPID: 1
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.pid, 101)
        XCTAssertTrue(rows.first?.isProtected == true)
        XCTAssertTrue(rows[1].canTerminate)
        XCTAssertEqual(rows[0].command, "/Applications/Dev Station.app/Contents/MacOS/DevStation")
    }

    func testProtectedProcessRules() {
        XCTAssertTrue(SystemManagerStore.isProtectedProcess(pid: 1, command: "/sbin/launchd", currentPID: 500, parentPID: 400))
        XCTAssertTrue(SystemManagerStore.isProtectedProcess(pid: 500, command: "/Applications/DevStation", currentPID: 500, parentPID: 400))
        XCTAssertTrue(SystemManagerStore.isProtectedProcess(pid: 400, command: "/usr/bin/zsh", currentPID: 500, parentPID: 400))
        XCTAssertTrue(SystemManagerStore.isProtectedProcess(pid: 600, command: "/System/Library/CoreServices/Finder", currentPID: 500, parentPID: 400))
        XCTAssertFalse(SystemManagerStore.isProtectedProcess(pid: 601, command: "/usr/bin/python3", currentPID: 500, parentPID: 400))
    }

    @MainActor
    func testTerminateSelectedProcessesEmptySelectionNoop() {
        let store = makeStore(processOutput: """
          777 tester 0.2 1024 /usr/bin/python3
        """)

        store.refreshNow()
        store.selectedPIDs = []
        store.terminateSelectedProcesses()
        XCTAssertEqual(store.lastActionMessage, "No process selected.")
        XCTAssertTrue(store.terminationResults.isEmpty)
    }

    @MainActor
    func testTerminateSelectedProcessesReportsPermissionDenied() {
        var sentSignals: [Int32] = []
        var errnoValue: Int32 = 0

        let store = makeStore(
            processOutput: """
              500 tester 3.4 800 /Applications/DevStation.app/Contents/MacOS/DevStation
              501 tester 1.2 4096 /usr/bin/python3
              502 tester 0.6 2048 /usr/bin/node
              503 tester 0.0 100 /System/Library/CoreServices/Finder
            """,
            currentPID: 500,
            parentPID: 42,
            signalSender: { pid, _ in
                sentSignals.append(pid)
                if pid == 501 {
                    errnoValue = EPERM
                    return -1
                }
                return 0
            },
            errnoProvider: { errnoValue }
        )

        store.refreshNow()
        store.selectedPIDs = [500, 501, 502, 503]
        store.terminateSelectedProcesses()

        XCTAssertEqual(sentSignals, [501, 502])
        XCTAssertEqual(store.terminationResults.count, 2)
        XCTAssertEqual(store.terminationResults.first(where: { $0.pid == 501 })?.status, .permissionDenied)
        XCTAssertEqual(store.terminationResults.first(where: { $0.pid == 502 })?.status, .success)
    }

    func testDeepLinkResolverRoutesSystemManager() {
        XCTAssertEqual(
            DevStationDeepLinkResolver.resolve(URL(string: "devstation://system-manager")!),
            .openSystemManager(optimize: false)
        )
        XCTAssertEqual(
            DevStationDeepLinkResolver.resolve(URL(string: "devstation://system-manager?action=optimize")!),
            .openSystemManager(optimize: true)
        )
        XCTAssertNil(DevStationDeepLinkResolver.resolve(URL(string: "https://example.com/system-manager")!))
    }

    @MainActor
    func testWidgetSnapshotBridgeEncodeWriteRead() throws {
        let bridge = SystemWidgetSnapshotBridge(reloadDebounceSeconds: 0)
        let snapshot = SystemSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            cpuUserPercent: 11.2,
            cpuSystemPercent: 6.5,
            cpuIdlePercent: 82.3,
            memTotalBytes: 16_000_000_000,
            memUsedBytes: 10_000_000_000,
            memFreeBytes: 6_000_000_000,
            memCompressedBytes: 1_000_000_000,
            swapUsedBytes: 2_000_000_000,
            swapTotalBytes: 4_000_000_000,
            processCount: 123
        )

        let data = try bridge.encode(snapshot: snapshot)
        let decoded = try bridge.decode(data: data)
        XCTAssertEqual(decoded, snapshot)

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("system-widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try bridge.write(snapshot: snapshot, to: tmpURL)
        let loaded = try bridge.readSnapshot(from: tmpURL)
        XCTAssertEqual(loaded, snapshot)
    }

    @MainActor
    private func makeStore(
        processOutput: String,
        currentPID: Int32 = 500,
        parentPID: Int32 = 42,
        signalSender: @escaping SystemManagerStore.SignalSender = { _, _ in 0 },
        errnoProvider: @escaping SystemManagerStore.ErrnoProvider = { 0 }
    ) -> SystemManagerStore {
        let runner: SystemManagerStore.CommandRunner = { executable, arguments, _ in
            switch executable {
            case "/usr/bin/top":
                return """
                Processes: 100 total
                CPU usage: 30.0% user, 10.0% sys, 60.0% idle
                """
            case "/usr/bin/vm_stat":
                return """
                Mach Virtual Memory Statistics: (page size of 16384 bytes)
                Pages free: 1000.
                Pages speculative: 200.
                Pages occupied by compressor: 500.
                """
            case "/usr/sbin/sysctl":
                if arguments == ["-n", "hw.memsize"] {
                    return "17179869184\n"
                }
                if arguments == ["-n", "vm.swapusage"] {
                    return "vm.swapusage: total = 1024.00M  used = 128.00M  free = 896.00M  (encrypted)\n"
                }
                XCTFail("Unexpected sysctl arguments: \(arguments)")
                return ""
            case "/bin/ps":
                return processOutput
            default:
                XCTFail("Unexpected command: \(executable)")
                return ""
            }
        }

        return SystemManagerStore(
            currentUser: "tester",
            currentPID: currentPID,
            parentPID: parentPID,
            commandRunner: runner,
            signalSender: signalSender,
            errnoProvider: errnoProvider,
            delayedRefreshNanoseconds: 0,
            persistSnapshot: { _, _ in }
        )
    }
}
