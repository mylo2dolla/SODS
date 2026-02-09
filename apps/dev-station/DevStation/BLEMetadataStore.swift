import Foundation
import AppKit
import CoreBluetooth

struct BLECompanyInfo: Codable, Hashable {
    let name: String
    let assignmentDate: String?
}

struct BLEAssignedUUIDInfo: Codable, Hashable {
    let uuidFull: String
    let uuidShort: String?
    let name: String
    let type: String
    let source: String
}

final class BLEMetadataStore {
    static let shared = BLEMetadataStore()

    private enum DefaultsKey {
        static let companyMapPath = "BLECompanyMapPath"
        static let assignedMapPath = "BLEAssignedNumbersPath"
    }

    private let queue = DispatchQueue(label: "BLEMetadataStore.queue", qos: .utility)
    private var companyMap: [UInt16: BLECompanyInfo] = [:]
    private var assignedMap: [String: BLEAssignedUUIDInfo] = [:]
    private var companyHits = 0
    private var companyMisses = 0
    private var assignedHits = 0
    private var assignedMisses = 0
    private var parseErrors = 0
    private var lastCompanyCount = 0
    private var lastAssignedCount = 0

    private init() {
        loadMaps(log: nil)
    }

    func companyInfo(for id: UInt16) -> BLECompanyInfo? {
        queue.sync {
            if let info = companyMap[id] {
                companyHits += 1
                return info
            }
            companyMisses += 1
            return nil
        }
    }

    func assignedUUIDInfo(for uuid: CBUUID) -> BLEAssignedUUIDInfo? {
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

    func reload(log: LogStore) {
        loadMaps(log: log)
    }

    func importCompanyMap(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(url.path, forKey: DefaultsKey.companyMapPath)
                log.log(.info, "Imported BLE company IDs from \(url.path)")
                Task.detached {
                    self.loadMaps(log: log)
                }
            }
        }
    }

    func importAssignedNumbersMap(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(url.path, forKey: DefaultsKey.assignedMapPath)
                log.log(.info, "Imported BLE assigned numbers from \(url.path)")
                Task.detached {
                    self.loadMaps(log: log)
                }
            }
        }
    }

    func logStats(log: LogStore) {
        queue.sync {
            log.log(.info, "BLE mapping stats: company hits=\(companyHits) misses=\(companyMisses); assigned hits=\(assignedHits) misses=\(assignedMisses); parse errors=\(parseErrors)")
        }
    }

    func tableWarning() -> String? {
        queue.sync {
            if lastCompanyCount == 0 || lastAssignedCount == 0 {
                return "BLE tables are empty; decoding coverage will be limited."
            }
            return nil
        }
    }

    private func loadMaps(log: LogStore?) {
        queue.sync {
            companyHits = 0
            companyMisses = 0
            assignedHits = 0
            assignedMisses = 0
            parseErrors = 0

            companyMap = builtInCompanyMap()
            assignedMap = builtInAssignedMap()

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
                log?.log(.warn, "BLECompanyIDs.txt missing in bundle")
            }

            let bundleAssignedURL = moduleBundle.url(forResource: "BLEAssignedNumbers", withExtension: "txt")
                ?? fallbackBundle.url(forResource: "BLEAssignedNumbers", withExtension: "txt")
            if let bundleAssignedURL, let bundleAssigned = loadLines(url: bundleAssignedURL) {
                mergeAssignedNumbers(lines: bundleAssigned)
            } else {
                log?.log(.warn, "BLEAssignedNumbers.txt missing in bundle")
            }

            let bundleServiceURL = moduleBundle.url(forResource: "BLEServiceUUIDs", withExtension: "txt")
                ?? fallbackBundle.url(forResource: "BLEServiceUUIDs", withExtension: "txt")
            if let bundleServiceURL, let bundleServices = loadLines(url: bundleServiceURL) {
                mergeServiceUUIDs(lines: bundleServices)
            } else {
                log?.log(.warn, "BLEServiceUUIDs.txt missing in bundle")
            }

            if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.companyMapPath) {
                mergeCompany(lines: loadLines(url: URL(fileURLWithPath: userPath)) ?? [])
            }
            if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.assignedMapPath) {
                mergeAssignedNumbers(lines: loadLines(url: URL(fileURLWithPath: userPath)) ?? [])
            }

            lastCompanyCount = companyMap.count
            lastAssignedCount = assignedMap.count
            log?.log(.info, "BLE company map entries: \(companyMap.count)")
            log?.log(.info, "BLE assigned numbers entries: \(assignedMap.count)")
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .bleMetadataUpdated, object: nil)
        }
    }

    private func builtInCompanyMap() -> [UInt16: BLECompanyInfo] {
        [:]
    }

    private func builtInAssignedMap() -> [String: BLEAssignedUUIDInfo] {
        [:]
    }

    private func loadLines(url: URL?) -> [String]? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? String(contentsOf: url))
            .map { $0.split(separator: "\n").map(String.init) }
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

    private func mergeServiceUUIDs(lines: [String]) {
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
            let key = normalizeUUIDKey(uuidRaw)
            if assignedMap[key] != nil { continue }
            let short = shortUUID(from: uuidRaw)
            assignedMap[key] = BLEAssignedUUIDInfo(uuidFull: full, uuidShort: short, name: name, type: "service", source: "bluetooth-sig")
        }
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

extension Notification.Name {
    static let bleMetadataUpdated = Notification.Name("bleMetadataUpdated")
}
