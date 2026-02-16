import XCTest
import CoreBluetooth
@testable import ScannerSpectrumCore

final class ParserTests: XCTestCase {
    private let ouiUserDefaultsKey = "ScannerSpectrumCore.OUIStoreUserPath"
    private let bleCompanyDefaultsKey = "ScannerSpectrumCore.BLECompanyMapPath"
    private let bleAssignedDefaultsKey = "ScannerSpectrumCore.BLEAssignedNumbersPath"

    private struct BackupState {
        let defaults: [String: String?]
        let files: [URL: Data?]
    }

    private var backupState: BackupState?

    override func setUpWithError() throws {
        try super.setUpWithError()
        backupState = try captureBackupState()
    }

    override func tearDownWithError() throws {
        if let backupState {
            try restoreBackupState(backupState)
        }

        BLEMetadataStore.shared.reload()
        waitForAsync(description: "Reload OUI store") {
            _ = await OUIStore.shared.reloadPreferred()
        }

        backupState = nil
        try super.tearDownWithError()
    }

    func testOUIImportRejectsTinyFileAndPreservesLoadedDataset() async throws {
        _ = await OUIStore.shared.reloadPreferred()
        let before = await OUIStore.shared.health()

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("tiny-oui.txt")
        let content = """
        A1B2C3 Vendor One
        112233 Vendor Two
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = await OUIStore.shared.importFromURLDetailed(file)
        let after = await OUIStore.shared.health()

        XCTAssertFalse(result.accepted)
        XCTAssertTrue(result.message.contains("minimum"))
        XCTAssertEqual(after.entryCount, before.entryCount)
    }

    func testOUIImportDetailedAcceptsLargeFileAndReportsHealth() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("large-oui.txt")
        var lines: [String] = ["# generated for test"]
        for value in 0..<1_200 {
            lines.append(String(format: "%06X Vendor-%04d", value, value))
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let result = await OUIStore.shared.importFromURLDetailed(file)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.entryCount, 1_200)

        let vendor = await OUIStore.shared.vendorForMAC("00:00:2A:11:22:33")
        XCTAssertEqual(vendor, "Vendor-0042")

        let health = await OUIStore.shared.health()
        XCTAssertEqual(health.entryCount, 1_200)
        XCTAssertTrue(health.source.contains("user import"))
    }

    func testBLEDetailedImportRejectsTinyInputs() throws {
        let before = BLEMetadataStore.shared.health()

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let companies = tempDir.appendingPathComponent("tiny-companies.txt")
        let assigned = tempDir.appendingPathComponent("tiny-assigned.txt")

        try "0xFFFE Test Labs".write(to: companies, atomically: true, encoding: .utf8)
        try "180A service Device Information".write(to: assigned, atomically: true, encoding: .utf8)

        let companyResult = BLEMetadataStore.shared.importCompanyMapDetailed(from: companies)
        let assignedResult = BLEMetadataStore.shared.importAssignedNumbersMapDetailed(from: assigned)
        let after = BLEMetadataStore.shared.health()

        XCTAssertFalse(companyResult.accepted)
        XCTAssertFalse(assignedResult.accepted)
        XCTAssertTrue(companyResult.message.contains("minimum"))
        XCTAssertTrue(assignedResult.message.contains("minimum"))
        XCTAssertEqual(after.companyCount, before.companyCount)
        XCTAssertEqual(after.assignedCount, before.assignedCount)
    }

    func testBLEDetailedImportAcceptsLargeInputsAndCanResetOverrides() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let companies = tempDir.appendingPathComponent("large-companies.txt")
        let assigned = tempDir.appendingPathComponent("large-assigned.txt")

        var companyLines: [String] = [
            "# Source: test",
            "# Updated: 2026-02-16"
        ]
        for value in 0..<3_972 {
            companyLines.append(String(format: "0x%04X Company-%04d", value, value))
        }
        companyLines.append("0xFFFE Reset Test Labs")

        var assignedLines: [String] = [
            "# Source: test",
            "# Updated: 2026-02-16"
        ]
        for offset in 0..<650 {
            assignedLines.append(String(format: "0x%04X characteristic Assigned-%04d", 0xA000 + offset, offset))
        }

        try companyLines.joined(separator: "\n").write(to: companies, atomically: true, encoding: .utf8)
        try assignedLines.joined(separator: "\n").write(to: assigned, atomically: true, encoding: .utf8)

        let companyResult = BLEMetadataStore.shared.importCompanyMapDetailed(from: companies)
        let assignedResult = BLEMetadataStore.shared.importAssignedNumbersMapDetailed(from: assigned)

        XCTAssertTrue(companyResult.accepted)
        XCTAssertTrue(assignedResult.accepted)
        XCTAssertGreaterThanOrEqual(companyResult.entryCount, 3_972)
        XCTAssertGreaterThanOrEqual(assignedResult.entryCount, 601)

        XCTAssertEqual(BLEMetadataStore.shared.companyInfo(for: 0xFFFE)?.name, "Reset Test Labs")
        XCTAssertEqual(BLEMetadataStore.shared.assignedUUIDInfo(for: CBUUID(string: "A000"))?.name, "Assigned-0000")

        BLEMetadataStore.shared.clearUserImportOverrides()

        XCTAssertNil(UserDefaults.standard.string(forKey: bleCompanyDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: bleAssignedDefaultsKey))
        XCTAssertNotEqual(BLEMetadataStore.shared.companyInfo(for: 0xFFFE)?.name, "Reset Test Labs")
    }

    func testOUIClearUserOverrideRestoresPreferredSource() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("large-oui.txt")
        var lines: [String] = []
        for value in 0..<1_500 {
            lines.append(String(format: "%06X TempVendor-%04d", value, value))
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let importResult = await OUIStore.shared.importFromURLDetailed(file)
        XCTAssertTrue(importResult.accepted)

        await OUIStore.shared.clearUserImportOverride()

        XCTAssertNil(UserDefaults.standard.string(forKey: ouiUserDefaultsKey))
        let health = await OUIStore.shared.health()
        XCTAssertGreaterThan(health.entryCount, 10_000)
        XCTAssertFalse(health.source.contains("user import"))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func scannerSupportDirectory() -> URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("ScannerSpectrumCore", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ScannerSpectrumCore", isDirectory: true)
    }

    private func captureBackupState() throws -> BackupState {
        let defaults = [
            ouiUserDefaultsKey: UserDefaults.standard.string(forKey: ouiUserDefaultsKey),
            bleCompanyDefaultsKey: UserDefaults.standard.string(forKey: bleCompanyDefaultsKey),
            bleAssignedDefaultsKey: UserDefaults.standard.string(forKey: bleAssignedDefaultsKey)
        ]

        var trackedFiles: Set<URL> = [
            scannerSupportDirectory().appendingPathComponent("OUI.user.txt"),
            scannerSupportDirectory().appendingPathComponent("BLECompanyIDs.user.txt"),
            scannerSupportDirectory().appendingPathComponent("BLEAssignedNumbers.user.txt")
        ]

        for path in defaults.values.compactMap({ $0 }) {
            trackedFiles.insert(URL(fileURLWithPath: path))
        }

        var files: [URL: Data?] = [:]
        for fileURL in trackedFiles {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                files[fileURL] = try Data(contentsOf: fileURL)
            } else {
                files[fileURL] = nil
            }
        }

        return BackupState(defaults: defaults, files: files)
    }

    private func restoreBackupState(_ backup: BackupState) throws {
        for (key, value) in backup.defaults {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        for (fileURL, data) in backup.files {
            if let data {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func waitForAsync(description: String, timeout: TimeInterval = 5.0, operation: @escaping @Sendable () async -> Void) {
        let expectation = expectation(description: description)
        Task {
            await operation()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }
}
