import Foundation

enum StationEndpointResolver {
    private static let stationBaseURLKey = "SODSBaseURL"
    private static let vaultHostKey = "VaultHost"
    private static let piLoggerURLKey = "PiLoggerURL"
    private static func defaultLoggerChain(env: [String: String]) -> String {
        let aux = env["AUX_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let logger = env["LOGGER_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auxHost = (aux?.isEmpty == false) ? aux! : "192.168.8.114"
        let loggerHost = (logger?.isEmpty == false) ? logger! : "192.168.8.160"
        return "http://\(auxHost):9101,http://pi-logger.local:8088,http://\(loggerHost):8088"
    }

    static func stationBaseURL(defaults: UserDefaults = .standard) -> String {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = firstNonEmpty(env["SODS_BASE_URL"], env["SODS_STATION_URL"], env["STATION_URL"]),
           let normalized = normalizeBaseURL(fromEnv) {
            return normalized
        }
        if let saved = defaults.string(forKey: stationBaseURLKey),
           let normalized = normalizeBaseURL(saved) {
            return normalized
        }
        let port = Int(env["SODS_PORT"] ?? "") ?? 9123
        return "http://127.0.0.1:\(port)"
    }

    static func loggerURL(baseURL: String? = nil, defaults: UserDefaults = .standard) -> String {
        let env = ProcessInfo.processInfo.environment
        let fallback = defaultLoggerChain(env: env)
        if let fromEnv = firstNonEmpty(env["PI_LOGGER_URL"], env["SODS_LOGGER_URL"]),
           let normalized = sanitizeLoggerList(normalizeURLList(fromEnv)) {
            return normalized
        }
        if let saved = defaults.string(forKey: piLoggerURLKey),
           let normalized = sanitizeLoggerList(normalizeURLList(saved)) {
            return normalized
        }
        let station = baseURL ?? stationBaseURL(defaults: defaults)
        if let stationURL = URL(string: station), let host = stationURL.host, !host.isEmpty {
            if isLoopbackHost(host) {
                return fallback
            }
            return "http://\(host):8088"
        }
        return fallback
    }

    static func defaultVaultHost(baseURL: String? = nil, defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: vaultHostKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        let logger = loggerURL(baseURL: baseURL, defaults: defaults)
        let primary = logger.split(separator: ",").map { String($0) }.first ?? logger
        if let host = URL(string: primary)?.host, !host.isEmpty {
            return host
        }
        return "localhost"
    }

    static func diagnosticsTargets(baseURL: String, defaults: UserDefaults = .standard) -> (dns: [String], http: [String]) {
        var dns: Set<String> = []
        var http: Set<String> = []
        if let station = normalizeBaseURL(baseURL) {
            http.insert("\(station)/health")
            if let host = URL(string: station)?.host, !host.isEmpty {
                dns.insert(host)
            }
        }
        let loggerList = loggerURL(baseURL: baseURL, defaults: defaults)
        let loggerEntries = loggerList
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { normalizeAbsoluteURL($0) }
        for logger in loggerEntries {
            http.insert("\(logger)/health")
            if let host = URL(string: logger)?.host, !host.isEmpty {
                dns.insert(host)
            }
        }
        return (dns: Array(dns).sorted(), http: Array(http).sorted())
    }

    private static func normalizeBaseURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var comps = URLComponents(string: trimmed) else { return nil }
        if comps.scheme == nil {
            comps.scheme = "http"
        }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        comps.host = host
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return nil }
        return url.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    private static func normalizeAbsoluteURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"), url.host != nil else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func normalizeURLList(_ value: String) -> String? {
        let entries = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { normalizeAbsoluteURL($0) }
        guard !entries.isEmpty else { return nil }
        var seen: Set<String> = []
        var unique: [String] = []
        for entry in entries {
            let key = entry.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(entry)
        }
        return unique.joined(separator: ",")
    }

    private static func sanitizeLoggerList(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { entry in
                guard let url = URL(string: entry), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
                    return false
                }
                guard let host = url.host, !host.isEmpty else { return false }
                let port = url.port ?? (scheme == "https" ? 443 : 80)
                return port == 9101 || port == 8088
            }
        let unique = Array(NSOrderedSet(array: cleaned)) as? [String] ?? cleaned
        return unique.isEmpty ? nil : unique.joined(separator: ",")
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1"
    }
}
