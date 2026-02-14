import Foundation

enum StationEndpointResolver {
    private static let stationBaseURLKey = "SODSBaseURL"
    private static let vaultHostKey = "VaultHost"
    private static let piLoggerURLKey = "PiLoggerURL"
    private static func defaultLoggerChain(env: [String: String]) -> String {
        let aux = env["AUX_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auxHost = (aux?.isEmpty == false) ? aux! : "pi-aux.local"
        return "http://\(auxHost):9101"
    }

    static func stationBaseURL(defaults: UserDefaults = .standard) -> String {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = firstNonEmpty(env["SODS_BASE_URL"], env["SODS_STATION_URL"], env["STATION_URL"]),
           let normalized = normalizeStationBaseURL(fromEnv, requireLocalHost: true).url {
            return normalized
        }
        if let saved = defaults.string(forKey: stationBaseURLKey),
           let normalized = normalizeStationBaseURL(saved, requireLocalHost: true).url {
            // Migration guard: older builds sometimes used the Pi-Aux control server port (8787/8788) as the Station port.
            // That conflicts with Dev Station's own control plane listener and causes the Station auto-start loop to thrash.
            if let url = URL(string: normalized),
               let host = url.host,
               isLocalStationHost(host),
               let port = url.port,
               (port == 8787 || port == 8788) {
                // Reset persisted bad value so future runs don't regress.
                defaults.removeObject(forKey: stationBaseURLKey)
            } else {
                return normalized
            }
        }
        let port = Int(env["SODS_PORT"] ?? "") ?? 9123
        return "http://127.0.0.1:\(port)"
    }

    static func loggerURL(baseURL: String? = nil, defaults: UserDefaults = .standard) -> String {
        let env = ProcessInfo.processInfo.environment
        let fallback = defaultLoggerChain(env: env)
        if let fromEnv = firstNonEmpty(env["PI_LOGGER_URL"], env["PI_LOGGER"]),
           let canonicalized = canonicalizeLoggerList(fromEnv, env: env),
           let normalized = sanitizeLoggerList(canonicalized) {
            return normalized
        }
        if let saved = defaults.string(forKey: piLoggerURLKey),
           let canonicalized = canonicalizeLoggerList(saved, env: env),
           let normalized = sanitizeLoggerList(canonicalized) {
            if normalized != saved {
                defaults.set(normalized, forKey: piLoggerURLKey)
            }
            return normalized
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
        if let station = normalizeStationBaseURL(baseURL, requireLocalHost: false).url {
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

    static func endpointURL(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    static func normalizeStationBaseURL(_ value: String, requireLocalHost: Bool) -> (url: String?, error: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Base URL is required.") }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var comps = URLComponents(string: candidate) else { return (nil, "Base URL is invalid.") }
        if comps.scheme == nil {
            comps.scheme = "http"
        }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (nil, "Base URL must start with http:// or https://")
        }
        guard let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return (nil, "Base URL must include a host.")
        }
        if let port = comps.port, port == 8787 || port == 8788 {
            return (nil, "Base URL port conflicts with control listener. Use Station port 9123.")
        }
        if requireLocalHost && !isLocalStationHost(host) {
            return (nil, "Base URL must resolve to this machine (localhost or local IP).")
        }
        comps.host = host
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return (nil, "Base URL is invalid.") }
        return (url.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression), nil)
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

    private static func canonicalizeLoggerList(_ value: String, env: [String: String]) -> String? {
        guard let normalized = normalizeURLList(value) else { return nil }
        let entries = normalized
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { migrateLegacyLoggerURL($0, env: env) }
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

    private static func migrateLegacyLoggerURL(_ value: String, env: [String: String]) -> String? {
        guard var comps = URLComponents(string: value),
              let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }

        let aux = env["AUX_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalAux = (aux?.isEmpty == false) ? aux! : "pi-aux.local"

        // One-time migration for legacy LAN IP defaults.
        if host == "192.168.8.114" || host == "192.168.8.160" {
            comps.host = canonicalAux
        }

        if comps.port == nil {
            comps.port = 9101
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return comps.url?.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
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
                return port == 9101
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

    private static func isLocalStationHost(_ host: String) -> Bool {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        if isLoopbackHost(lowered) { return true }

        var localHosts: Set<String> = []
        if let localName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !localName.isEmpty {
            localHosts.insert(localName)
            localHosts.insert("\(localName).local")
        }
        for name in Host.current().names {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty { localHosts.insert(clean) }
        }
        for addr in Host.current().addresses {
            let clean = addr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty { localHosts.insert(clean) }
        }
        return localHosts.contains(lowered)
    }
}
