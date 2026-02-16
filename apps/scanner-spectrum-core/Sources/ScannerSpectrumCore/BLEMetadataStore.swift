import Foundation
import CoreBluetooth

public struct BLECompanyInfo: Codable, Hashable, Sendable {
    public let name: String
    public let assignmentDate: String?

    public init(name: String, assignmentDate: String?) {
        self.name = name
        self.assignmentDate = assignmentDate
    }
}

public struct BLEAssignedUUIDInfo: Codable, Hashable, Sendable {
    public let uuidFull: String
    public let uuidShort: String?
    public let name: String
    public let type: String
    public let source: String

    public init(uuidFull: String, uuidShort: String?, name: String, type: String, source: String) {
        self.uuidFull = uuidFull
        self.uuidShort = uuidShort
        self.name = name
        self.type = type
        self.source = source
    }
}

public struct BLEMetadataHealth: Hashable, Sendable {
    public let companyCount: Int
    public let assignedCount: Int
    public let serviceCount: Int
    public let parseErrors: Int
    public let warnings: [String]

    public init(companyCount: Int, assignedCount: Int, serviceCount: Int, parseErrors: Int, warnings: [String]) {
        self.companyCount = companyCount
        self.assignedCount = assignedCount
        self.serviceCount = serviceCount
        self.parseErrors = parseErrors
        self.warnings = warnings
    }

    public var isHealthy: Bool {
        warnings.isEmpty
    }

    public var summary: String {
        "company=\(companyCount) assigned=\(assignedCount) services=\(serviceCount) parse_errors=\(parseErrors) healthy=\(isHealthy ? "true" : "false")"
    }
}

public final class BLEMetadataStore: @unchecked Sendable {
    public static let shared = BLEMetadataStore()

    public static let metadataUpdatedNotification = Notification.Name("ScannerSpectrumCoreBLEMetadataUpdated")

    private enum DefaultsKey {
        static let companyMapPath = "ScannerSpectrumCore.BLECompanyMapPath"
        static let assignedMapPath = "ScannerSpectrumCore.BLEAssignedNumbersPath"
    }

    private enum Threshold {
        static let minCompanyCount = 3_972
        static let minAssignedCount = 601
        static let minServiceCount = 75
        static let maxParseErrors = 20
    }

    private let queue = DispatchQueue(label: "ScannerSpectrumCore.BLEMetadataStore", qos: .utility)
    private var companyMap: [UInt16: BLECompanyInfo] = [:]
    private var assignedMap: [String: BLEAssignedUUIDInfo] = [:]
    private var companyHits = 0
    private var companyMisses = 0
    private var assignedHits = 0
    private var assignedMisses = 0
    private var parseErrors = 0
    private var lastCompanyCount = 0
    private var lastAssignedCount = 0
    private var lastServiceCount = 0

    private init() {
        loadMaps(logger: nil)
    }

    public func companyInfo(for id: UInt16) -> BLECompanyInfo? {
        queue.sync {
            if let info = companyMap[id] {
                companyHits += 1
                return info
            }
            companyMisses += 1
            return nil
        }
    }

    public func assignedUUIDInfo(for uuid: CBUUID) -> BLEAssignedUUIDInfo? {
        let key = normalizeUUIDKey(uuid.uuidString)
        return queue.sync {
            if let info = assignedMap[key] {
                assignedHits += 1
                return info
            }
            assignedMisses += 1
            return nil
        }
    }

    public func reload(logger: ScannerCoreLogger? = nil) {
        loadMaps(logger: logger)
    }

    @discardableResult
    public func importCompanyMap(from url: URL, logger: ScannerCoreLogger? = nil) -> Bool {
        importCompanyMapDetailed(from: url, logger: logger).accepted
    }

    @discardableResult
    public func importCompanyMapDetailed(from url: URL, logger: ScannerCoreLogger? = nil) -> ScannerDatabaseImportResult {
        let destination = persistentURL(filename: "BLECompanyIDs.user.txt")
        do {
            let text = try readText(url: url)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let preview = previewCompanyImport(lines: lines)

            if preview.entryCount < Threshold.minCompanyCount {
                let message = "Rejected BLE company import: parsed \(preview.entryCount) entries, minimum \(Threshold.minCompanyCount)."
                coreLog(logger, .warn, message)
                return ScannerDatabaseImportResult(accepted: false, message: message, entryCount: preview.entryCount)
            }
            if preview.parseErrors > Threshold.maxParseErrors {
                let message = "Rejected BLE company import: parse errors \(preview.parseErrors) exceed maximum \(Threshold.maxParseErrors)."
                coreLog(logger, .warn, message)
                return ScannerDatabaseImportResult(accepted: false, message: message, entryCount: preview.entryCount)
            }

            try ensurePersistentDirectory()
            try text.write(to: destination, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(destination.path, forKey: DefaultsKey.companyMapPath)
            loadMaps(logger: logger)

            let message = "Imported BLE company IDs (\(preview.entryCount) entries)."
            coreLog(logger, .info, "Imported BLE company IDs from \(url.path)")
            return ScannerDatabaseImportResult(accepted: true, message: message, entryCount: preview.entryCount)
        } catch {
            let message = "BLE company import failed: \(error.localizedDescription)"
            coreLog(logger, .error, message)
            return ScannerDatabaseImportResult(accepted: false, message: message)
        }
    }

    @discardableResult
    public func importAssignedNumbersMap(from url: URL, logger: ScannerCoreLogger? = nil) -> Bool {
        importAssignedNumbersMapDetailed(from: url, logger: logger).accepted
    }

    @discardableResult
    public func importAssignedNumbersMapDetailed(from url: URL, logger: ScannerCoreLogger? = nil) -> ScannerDatabaseImportResult {
        let destination = persistentURL(filename: "BLEAssignedNumbers.user.txt")
        do {
            let text = try readText(url: url)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let preview = previewAssignedImport(lines: lines)

            if preview.entryCount < Threshold.minAssignedCount {
                let message = "Rejected BLE assigned-numbers import: parsed \(preview.entryCount) entries, minimum \(Threshold.minAssignedCount)."
                coreLog(logger, .warn, message)
                return ScannerDatabaseImportResult(accepted: false, message: message, entryCount: preview.entryCount)
            }
            if preview.parseErrors > Threshold.maxParseErrors {
                let message = "Rejected BLE assigned-numbers import: parse errors \(preview.parseErrors) exceed maximum \(Threshold.maxParseErrors)."
                coreLog(logger, .warn, message)
                return ScannerDatabaseImportResult(accepted: false, message: message, entryCount: preview.entryCount)
            }

            try ensurePersistentDirectory()
            try text.write(to: destination, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(destination.path, forKey: DefaultsKey.assignedMapPath)
            loadMaps(logger: logger)

            let message = "Imported BLE assigned numbers (\(preview.entryCount) entries)."
            coreLog(logger, .info, "Imported BLE assigned numbers from \(url.path)")
            return ScannerDatabaseImportResult(accepted: true, message: message, entryCount: preview.entryCount)
        } catch {
            let message = "BLE assigned-numbers import failed: \(error.localizedDescription)"
            coreLog(logger, .error, message)
            return ScannerDatabaseImportResult(accepted: false, message: message)
        }
    }

    public func clearUserImportOverrides(logger: ScannerCoreLogger? = nil) {
        removeUserOverride(defaultsKey: DefaultsKey.companyMapPath, fallbackFilename: "BLECompanyIDs.user.txt")
        removeUserOverride(defaultsKey: DefaultsKey.assignedMapPath, fallbackFilename: "BLEAssignedNumbers.user.txt")
        coreLog(logger, .info, "Cleared imported BLE metadata overrides; using bundled metadata.")
        loadMaps(logger: logger)
    }

    public func logStats(logger: ScannerCoreLogger? = nil) {
        queue.sync {
            coreLog(logger, .info, "BLE mapping stats: company hits=\(companyHits) misses=\(companyMisses); assigned hits=\(assignedHits) misses=\(assignedMisses); parse errors=\(parseErrors)")
            let health = metadataHealthLocked()
            coreLog(logger, .info, "BLE metadata health: \(health.summary)")
            if !health.isHealthy {
                coreLog(logger, .warn, "BLE metadata warnings: \(health.warnings.joined(separator: " | "))")
            }
        }
    }

    public func tableWarning() -> String? {
        queue.sync {
            let health = metadataHealthLocked()
            if !health.isHealthy {
                return "BLE metadata degraded: \(health.warnings.joined(separator: " | "))"
            }
            return nil
        }
    }

    public func health() -> BLEMetadataHealth {
        queue.sync {
            metadataHealthLocked()
        }
    }

    private func loadMaps(logger: ScannerCoreLogger?) {
        queue.sync {
            companyHits = 0
            companyMisses = 0
            assignedHits = 0
            assignedMisses = 0
            parseErrors = 0

            companyMap = [:]
            assignedMap = [:]

            let moduleBundle: Bundle
            #if SWIFT_PACKAGE
            moduleBundle = Bundle.module
            #else
            moduleBundle = Bundle.main
            #endif
            let fallbackBundle = Bundle.main

            let bundleCompanyURL = moduleBundle.url(forResource: "BLECompanyIDs", withExtension: "txt")
                ?? fallbackBundle.url(forResource: "BLECompanyIDs", withExtension: "txt")
            if let bundleCompanyURL, let bundleCompany = loadLines(url: bundleCompanyURL) {
                mergeCompany(lines: bundleCompany)
            } else {
                coreLog(logger, .warn, "BLECompanyIDs.txt missing in bundle")
            }

            let bundleAssignedURL = moduleBundle.url(forResource: "BLEAssignedNumbers", withExtension: "txt")
                ?? fallbackBundle.url(forResource: "BLEAssignedNumbers", withExtension: "txt")
            if let bundleAssignedURL, let bundleAssigned = loadLines(url: bundleAssignedURL) {
                mergeAssignedNumbers(lines: bundleAssigned)
            } else {
                coreLog(logger, .warn, "BLEAssignedNumbers.txt missing in bundle")
            }

            let bundleServiceURL = moduleBundle.url(forResource: "BLEServiceUUIDs", withExtension: "txt")
                ?? fallbackBundle.url(forResource: "BLEServiceUUIDs", withExtension: "txt")
            if let bundleServiceURL, let bundleServices = loadLines(url: bundleServiceURL) {
                lastServiceCount = mergeServiceUUIDs(lines: bundleServices)
            } else {
                lastServiceCount = 0
                coreLog(logger, .warn, "BLEServiceUUIDs.txt missing in bundle")
            }

            if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.companyMapPath) {
                mergeCompany(lines: loadLines(url: URL(fileURLWithPath: userPath)) ?? [])
            }
            if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.assignedMapPath) {
                mergeAssignedNumbers(lines: loadLines(url: URL(fileURLWithPath: userPath)) ?? [])
            }

            lastCompanyCount = companyMap.count
            lastAssignedCount = assignedMap.count
            coreLog(logger, .info, "BLE company map entries: \(companyMap.count)")
            coreLog(logger, .info, "BLE assigned numbers entries: \(assignedMap.count)")
            coreLog(logger, .info, "BLE service UUID entries: \(lastServiceCount)")
            let health = metadataHealthLocked()
            coreLog(logger, .info, "BLE metadata health: \(health.summary)")
            if !health.isHealthy {
                coreLog(logger, .warn, "BLE metadata warnings: \(health.warnings.joined(separator: " | "))")
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.metadataUpdatedNotification, object: nil)
        }
    }

    private func ensurePersistentDirectory() throws {
        let directory = persistentDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func persistentDirectoryURL() -> URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("ScannerSpectrumCore", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ScannerSpectrumCore", isDirectory: true)
    }

    private func persistentURL(filename: String) -> URL {
        persistentDirectoryURL().appendingPathComponent(filename)
    }

    private func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw NSError(domain: "ScannerSpectrumCore.BLEMetadataStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding"])
    }

    private func loadLines(url: URL?) -> [String]? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let content = try? String(contentsOf: url) else { return nil }
        return content.split(separator: "\n").map(String.init)
    }

    private func mergeCompany(lines: [String]) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let rawKey = String(parts[0])
            let rawName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = parseCompanyID(rawKey) else {
                parseErrors += 1
                continue
            }
            let (name, assignment) = parseAssignmentDate(from: rawName)
            if !name.isEmpty {
                companyMap[id] = BLECompanyInfo(name: name, assignmentDate: assignment)
            }
        }
    }

    private func mergeAssignedNumbers(lines: [String]) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3 else { continue }
            let uuidRaw = String(parts[0])
            let typeRaw = String(parts[1]).lowercased()
            let name = parts.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let full = normalizeUUIDFullOptional(uuidRaw), !name.isEmpty else {
                parseErrors += 1
                continue
            }
            let key = normalizeUUIDKey(uuidRaw)
            let short = shortUUID(from: uuidRaw)
            assignedMap[key] = BLEAssignedUUIDInfo(uuidFull: full, uuidShort: short, name: name, type: typeRaw, source: "bluetooth-sig")
        }
    }

    private func mergeServiceUUIDs(lines: [String]) -> Int {
        var parsedCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let uuidRaw = String(parts[0])
            let name = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let full = normalizeUUIDFullOptional(uuidRaw), !name.isEmpty else {
                parseErrors += 1
                continue
            }
            parsedCount += 1
            let key = normalizeUUIDKey(uuidRaw)
            if assignedMap[key] != nil { continue }
            let short = shortUUID(from: uuidRaw)
            assignedMap[key] = BLEAssignedUUIDInfo(uuidFull: full, uuidShort: short, name: name, type: "service", source: "bluetooth-sig")
        }
        return parsedCount
    }

    private func previewCompanyImport(lines: [String]) -> (entryCount: Int, parseErrors: Int) {
        var entryCount = 0
        var parseErrors = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let rawKey = String(parts[0])
            let rawName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard parseCompanyID(rawKey) != nil else {
                parseErrors += 1
                continue
            }
            let (name, _) = parseAssignmentDate(from: rawName)
            if name.isEmpty {
                parseErrors += 1
                continue
            }
            entryCount += 1
        }

        return (entryCount, parseErrors)
    }

    private func previewAssignedImport(lines: [String]) -> (entryCount: Int, parseErrors: Int) {
        var entryCount = 0
        var parseErrors = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3 else { continue }
            let uuidRaw = String(parts[0])
            let name = parts.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizeUUIDFullOptional(uuidRaw) != nil, !name.isEmpty else {
                parseErrors += 1
                continue
            }
            entryCount += 1
        }

        return (entryCount, parseErrors)
    }

    private func removeUserOverride(defaultsKey: String, fallbackFilename: String) {
        if let userPath = UserDefaults.standard.string(forKey: defaultsKey) {
            let userURL = URL(fileURLWithPath: userPath)
            if FileManager.default.fileExists(atPath: userURL.path) {
                try? FileManager.default.removeItem(at: userURL)
            }
        }

        let fallbackURL = persistentURL(filename: fallbackFilename)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            try? FileManager.default.removeItem(at: fallbackURL)
        }

        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func metadataHealthLocked() -> BLEMetadataHealth {
        var warnings: [String] = []
        if lastCompanyCount < Threshold.minCompanyCount {
            warnings.append("company entries \(lastCompanyCount) below minimum \(Threshold.minCompanyCount)")
        }
        if lastAssignedCount < Threshold.minAssignedCount {
            warnings.append("assigned entries \(lastAssignedCount) below minimum \(Threshold.minAssignedCount)")
        }
        if lastServiceCount < Threshold.minServiceCount {
            warnings.append("service UUID entries \(lastServiceCount) below minimum \(Threshold.minServiceCount)")
        }
        if parseErrors > Threshold.maxParseErrors {
            warnings.append("parse errors \(parseErrors) exceed maximum \(Threshold.maxParseErrors)")
        }
        return BLEMetadataHealth(
            companyCount: lastCompanyCount,
            assignedCount: lastAssignedCount,
            serviceCount: lastServiceCount,
            parseErrors: parseErrors,
            warnings: warnings
        )
    }

    private func parseCompanyID(_ token: String) -> UInt16? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexToken = trimmed.replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
        if trimmed.lowercased().hasPrefix("0x") || hexToken.rangeOfCharacter(from: CharacterSet.letters) != nil {
            return UInt16(hexToken, radix: 16)
        }
        if let value = UInt16(hexToken, radix: 16) {
            return value
        }
        return UInt16(trimmed, radix: 10)
    }

    private func parseAssignmentDate(from name: String) -> (String, String?) {
        guard let start = name.range(of: "(assigned ") else {
            return (name, nil)
        }
        guard let end = name.range(of: ")", range: start.upperBound..<name.endIndex) else {
            return (name, nil)
        }
        let date = String(name[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = name
        cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, date.isEmpty ? nil : date)
    }

    private func normalizeUUIDKey(_ uuid: String) -> String {
        normalizeUUIDFull(uuid).replacingOccurrences(of: "-", with: "")
    }

    private func normalizeUUIDFullOptional(_ uuid: String) -> String? {
        let cleaned = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        return normalizeUUIDFull(cleaned)
    }

    private func normalizeUUIDFull(_ uuid: String) -> String {
        let cleaned = uuid.uppercased().replacingOccurrences(of: "0X", with: "").replacingOccurrences(of: "-", with: "")
        if cleaned.count == 4 {
            return "0000\(cleaned)-0000-1000-8000-00805F9B34FB"
        }
        if cleaned.count == 8 {
            return "\(cleaned.prefix(8))-0000-1000-8000-00805F9B34FB"
        }
        if cleaned.count == 32 {
            let start = cleaned.startIndex
            let a = cleaned[start..<cleaned.index(start, offsetBy: 8)]
            let b = cleaned[cleaned.index(start, offsetBy: 8)..<cleaned.index(start, offsetBy: 12)]
            let c = cleaned[cleaned.index(start, offsetBy: 12)..<cleaned.index(start, offsetBy: 16)]
            let d = cleaned[cleaned.index(start, offsetBy: 16)..<cleaned.index(start, offsetBy: 20)]
            let e = cleaned[cleaned.index(start, offsetBy: 20)..<cleaned.index(start, offsetBy: 32)]
            return "\(a)-\(b)-\(c)-\(d)-\(e)"
        }
        return uuid.uppercased()
    }

    private func shortUUID(from uuid: String) -> String? {
        let cleaned = uuid.uppercased().replacingOccurrences(of: "0X", with: "").replacingOccurrences(of: "-", with: "")
        if cleaned.count == 4 { return cleaned }
        if cleaned.count == 32, cleaned.hasPrefix("0000") {
            let start = cleaned.index(cleaned.startIndex, offsetBy: 4)
            let end = cleaned.index(start, offsetBy: 4)
            return String(cleaned[start..<end])
        }
        return nil
    }
}
