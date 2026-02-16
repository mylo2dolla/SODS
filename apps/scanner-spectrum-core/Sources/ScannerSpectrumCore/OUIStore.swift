import Foundation

public actor OUIStore {
    public static let shared = OUIStore()

    private enum DefaultsKey {
        static let userPath = "ScannerSpectrumCore.OUIStoreUserPath"
    }

    private enum Threshold {
        static let minImportEntries = 1_000
        static let minHealthyEntries = 35_000
    }

    private var map: [String: String] = [:]
    private var loadedDefault = false
    private var activeSource = "unloaded"
    private var lastWarning: String?

    public init() {}

    public func loadPreferredIfNeeded(logger: ScannerCoreLogger? = nil) async {
        guard !loadedDefault else { return }
        loadedDefault = true
        _ = await reloadPreferred(logger: logger)
    }

    @discardableResult
    public func reloadPreferred(logger: ScannerCoreLogger? = nil) async -> Int? {
        if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.userPath) {
            let userURL = URL(fileURLWithPath: userPath)
            if FileManager.default.fileExists(atPath: userURL.path),
               let count = await loadFromURLInternal(
                userURL,
                logger: logger,
                sourceDescription: "user override (\(userURL.lastPathComponent))",
                minimumEntries: Threshold.minImportEntries
               ) {
                return count
            }
        }

        #if os(macOS)
        let macUserURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("SODS/oui/oui_combined.txt")
        if FileManager.default.fileExists(atPath: macUserURL.path),
           let count = await loadFromURLInternal(
            macUserURL,
            logger: logger,
            sourceDescription: "macOS runtime override (\(macUserURL.lastPathComponent))",
            minimumEntries: Threshold.minImportEntries
           ) {
            return count
        }
        #endif

        let moduleBundle: Bundle
        #if SWIFT_PACKAGE
        moduleBundle = Bundle.module
        #else
        moduleBundle = Bundle.main
        #endif

        let defaultURL = moduleBundle.url(forResource: "OUI", withExtension: "txt")
            ?? moduleBundle.url(forResource: "oui", withExtension: "txt")
            ?? Bundle.main.url(forResource: "OUI", withExtension: "txt")
            ?? Bundle.main.url(forResource: "oui", withExtension: "txt")

        guard let url = defaultURL else {
            let message = "OUI default file missing in bundle"
            lastWarning = message
            coreLog(logger, .warn, message)
            return nil
        }

        return await loadFromURLInternal(
            url,
            logger: logger,
            sourceDescription: "bundled OUI database",
            minimumEntries: nil
        )
    }

    @discardableResult
    public func importFromURL(_ url: URL, logger: ScannerCoreLogger? = nil) async -> Bool {
        let result = await importFromURLDetailed(url, logger: logger)
        return result.accepted
    }

    public func importFromURLDetailed(_ url: URL, logger: ScannerCoreLogger? = nil) async -> ScannerDatabaseImportResult {
        do {
            let text = try readText(url: url)
            let parsed = parseOUI(text)
            guard parsed.count >= Threshold.minImportEntries else {
                let message = "Rejected OUI import: parsed \(parsed.count) entries, minimum \(Threshold.minImportEntries)."
                lastWarning = message
                coreLog(logger, .warn, message)
                return ScannerDatabaseImportResult(accepted: false, message: message, entryCount: parsed.count)
            }

            try ensurePersistentDirectory()
            let destination = persistentURL(filename: "OUI.user.txt")
            try text.write(to: destination, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(destination.path, forKey: DefaultsKey.userPath)

            map = parsed
            activeSource = "user import (\(url.lastPathComponent))"
            lastWarning = healthWarning(for: parsed.count)

            let message = "Imported OUI database (\(parsed.count) entries)."
            coreLog(logger, .info, message)
            if let warning = lastWarning {
                coreLog(logger, .warn, warning)
            }
            return ScannerDatabaseImportResult(accepted: true, message: message, entryCount: parsed.count)
        } catch {
            let message = "OUI import failed: \(error.localizedDescription)"
            lastWarning = message
            coreLog(logger, .error, message)
            return ScannerDatabaseImportResult(accepted: false, message: message)
        }
    }

    public func clearUserImportOverride(logger: ScannerCoreLogger? = nil) async {
        if let userPath = UserDefaults.standard.string(forKey: DefaultsKey.userPath) {
            let userURL = URL(fileURLWithPath: userPath)
            if FileManager.default.fileExists(atPath: userURL.path) {
                try? FileManager.default.removeItem(at: userURL)
            }
        }

        let defaultUserFile = persistentURL(filename: "OUI.user.txt")
        if FileManager.default.fileExists(atPath: defaultUserFile.path) {
            try? FileManager.default.removeItem(at: defaultUserFile)
        }

        UserDefaults.standard.removeObject(forKey: DefaultsKey.userPath)
        loadedDefault = false
        _ = await reloadPreferred(logger: logger)
        coreLog(logger, .info, "Cleared imported OUI override; using preferred fallback source.")
    }

    public func health() -> OUIStoreHealth {
        OUIStoreHealth(
            entryCount: map.count,
            source: activeSource,
            warning: lastWarning ?? healthWarning(for: map.count)
        )
    }

    public func vendorForMAC(_ mac: String) -> String? {
        let normalized = normalizeMAC(mac)
        guard normalized.count >= 6 else { return nil }
        let prefix = String(normalized.prefix(6))
        return map[prefix]
    }

    @discardableResult
    public func loadFromURL(_ url: URL, logger: ScannerCoreLogger? = nil) async -> Int? {
        await loadFromURLInternal(
            url,
            logger: logger,
            sourceDescription: url.lastPathComponent,
            minimumEntries: nil
        )
    }

    @discardableResult
    private func loadFromURLInternal(
        _ url: URL,
        logger: ScannerCoreLogger?,
        sourceDescription: String,
        minimumEntries: Int?
    ) async -> Int? {
        do {
            let text = try readText(url: url)
            let parsed = parseOUI(text)

            if let minimumEntries, parsed.count < minimumEntries {
                let message = "Rejected OUI source \"\(sourceDescription)\": parsed \(parsed.count) entries, minimum \(minimumEntries)."
                lastWarning = message
                coreLog(logger, .warn, message)
                return nil
            }

            map = parsed
            activeSource = sourceDescription
            lastWarning = healthWarning(for: parsed.count)
            coreLog(logger, .info, "OUI map loaded \(parsed.count) entries from \(sourceDescription)")
            if let warning = lastWarning {
                coreLog(logger, .warn, warning)
            }
            return parsed.count
        } catch {
            let message = "OUI source load failed from \(sourceDescription): \(error.localizedDescription)"
            lastWarning = message
            coreLog(logger, .error, message)
            return nil
        }
    }

    private func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw NSError(domain: "ScannerSpectrumCore.OUIStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding"])
    }

    private func parseOUI(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        for lineSub in lines {
            let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 2 else { continue }
            let key = normalizeMAC(parts[0])
            guard key.count >= 6 else { continue }
            let prefix = String(key.prefix(6))
            let vendor = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !vendor.isEmpty {
                result[prefix] = vendor
            }
        }
        return result
    }

    private func normalizeMAC(_ mac: String) -> String {
        mac.uppercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private func healthWarning(for entryCount: Int) -> String? {
        if entryCount == 0 {
            return "OUI map is empty."
        }
        if entryCount < Threshold.minHealthyEntries {
            return "OUI entries \(entryCount) below expected \(Threshold.minHealthyEntries)."
        }
        return nil
    }

    private func ensurePersistentDirectory() throws {
        try FileManager.default.createDirectory(at: persistentDirectoryURL(), withIntermediateDirectories: true)
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
}
