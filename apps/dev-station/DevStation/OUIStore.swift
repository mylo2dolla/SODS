import Foundation
import AppKit

actor OUIStore {
    static let shared = OUIStore()

    private var map: [String: String] = [:]
    private var loadedDefault = false

    func loadPreferredIfNeeded(log: LogStore) async {
        guard !loadedDefault else { return }
        loadedDefault = true
        _ = await reloadPreferred(log: log)
    }

    func reloadPreferred(log: LogStore) async -> Int? {
        let userURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("SODS/oui/oui_combined.txt")
        if FileManager.default.fileExists(atPath: userURL.path) {
            if let count = await loadFromURL(userURL, log: log),
               count > 0 {
                return count
            }
        }
        let defaultURL = Bundle.main.url(forResource: "OUI", withExtension: "txt")
            ?? Bundle.main.url(forResource: "oui", withExtension: "txt")
        guard let url = defaultURL else {
            log.log(.warn, "OUI default file missing in bundle")
            return nil
        }
        return await loadFromURL(url, log: log)
    }

    nonisolated func importFromOpenPanel(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    await self.loadFromURL(url, log: log)
                }
            }
        }
    }

    func vendorForMAC(_ mac: String) -> String? {
        let normalized = normalizeMAC(mac)
        guard normalized.count >= 6 else { return nil }
        let prefix = String(normalized.prefix(6))
        return map[prefix]
    }

    private func loadFromURL(_ url: URL, log: LogStore) async -> Int? {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                log.log(.error, "OUI import failed: unsupported encoding")
                return nil
            }
            let parsed = parseOUI(text)
            map = parsed
            log.log(.info, "OUI import loaded \(parsed.count) entries")
            return parsed.count
        } catch {
            log.log(.error, "OUI import failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseOUI(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        for lineSub in lines {
            let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
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
}
