import Foundation
import Darwin

enum StationEndpointResolver {
    private static let stationBaseURLKey = "SODSBaseURL"
    private static let vaultHostKey = "VaultHost"
    private static let piLoggerURLKey = "PiLoggerURL"
    private static let fallbackAuxHost = "192.168.8.114"
    private static let fallbackVaultHost = "192.168.8.160"
    private static let probeTimeoutSeconds: TimeInterval = 2.0

    struct ProbeHTTPResponse: Equatable {
        let statusCode: Int
        let data: Data
    }

    typealias ProbeFetcher = (_ url: URL) async throws -> ProbeHTTPResponse

    enum ProbeResult: Equatable {
        case stationOK
        case nonStationService(serviceName: String?)
        case unreachable
        case invalidResponse
    }

    private static func defaultLoggerChain(env: [String: String]) -> String {
        let aux = env["AUX_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredHost = (aux?.isEmpty == false) ? aux! : fallbackAuxHost
        let auxHost = isResolvableHost(preferredHost) ? preferredHost : fallbackAuxHost
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
           let normalized = sanitizeLoggerList(canonicalized),
           let reachable = resolvableLoggerList(normalized) {
            return reachable
        }
        if let saved = defaults.string(forKey: piLoggerURLKey),
           let canonicalized = canonicalizeLoggerList(saved, env: env),
           let normalized = sanitizeLoggerList(canonicalized),
           let reachable = resolvableLoggerList(normalized) {
            if reachable != saved {
                defaults.set(reachable, forKey: piLoggerURLKey)
            }
            return reachable
        }
        defaults.set(fallback, forKey: piLoggerURLKey)
        return fallback
    }

    static func defaultVaultHost(baseURL _: String? = nil, defaults: UserDefaults = .standard) -> String {
        let env = ProcessInfo.processInfo.environment

        if let envHost = normalizedVaultHostCandidate(firstNonEmpty(env["VAULT_HOST"])),
           isResolvableHost(envHost) {
            return envHost
        }

        if let savedRaw = defaults.string(forKey: vaultHostKey),
           let savedHost = normalizedVaultHostCandidate(savedRaw),
           isResolvableHost(savedHost) {
            if savedHost != savedRaw {
                defaults.set(savedHost, forKey: vaultHostKey)
            }
            return savedHost
        }

        if let loggerHost = normalizedVaultHostCandidate(firstNonEmpty(env["LOGGER_HOST"])),
           isResolvableHost(loggerHost) {
            defaults.set(loggerHost, forKey: vaultHostKey)
            return loggerHost
        }

        defaults.set(fallbackVaultHost, forKey: vaultHostKey)
        return fallbackVaultHost
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

    static func probeStationAPI(baseURL: String, fetcher: @escaping ProbeFetcher = liveProbeFetcher) async -> ProbeResult {
        guard let statusURL = endpointURL(baseURL: baseURL, path: "/api/status"),
              let healthURL = endpointURL(baseURL: baseURL, path: "/health") else {
            return .invalidResponse
        }

        var statusRequestReachedHost = false

        do {
            let statusResponse = try await fetcher(statusURL)
            statusRequestReachedHost = true
            if (200 ... 299).contains(statusResponse.statusCode),
               hasStationOKField(in: statusResponse.data) {
                return .stationOK
            }
        } catch {
            statusRequestReachedHost = false
        }

        do {
            let healthResponse = try await fetcher(healthURL)
            if (200 ... 299).contains(healthResponse.statusCode),
               let serviceName = nonEmptyServiceName(in: healthResponse.data) {
                return .nonStationService(serviceName: serviceName)
            }
            return .invalidResponse
        } catch {
            return statusRequestReachedHost ? .invalidResponse : .unreachable
        }
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

    private static func migrateLegacyLoggerURL(_ value: String, env _: [String: String]) -> String? {
        guard var comps = URLComponents(string: value),
              let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
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

    private static func resolvableLoggerList(_ value: String?) -> String? {
        guard let value else { return nil }
        let entries = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { entry in
                guard let host = URL(string: entry)?.host else { return false }
                return isResolvableHost(host)
            }
        let unique = Array(NSOrderedSet(array: entries)) as? [String] ?? entries
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

    private static func liveProbeFetcher(_ url: URL) async throws -> ProbeHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = probeTimeoutSeconds
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProbeHTTPResponse(statusCode: http.statusCode, data: data)
    }

    private struct ProbeStatusEnvelope: Decodable {
        struct StationPayload: Decodable {
            let ok: Bool?
        }

        let station: StationPayload
    }

    private static func hasStationOKField(in data: Data) -> Bool {
        guard let payload = try? JSONDecoder().decode(ProbeStatusEnvelope.self, from: data) else {
            return false
        }
        return payload.station.ok != nil
    }

    private struct ProbeHealthEnvelope: Decodable {
        let service: String?
    }

    private static func nonEmptyServiceName(in data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(ProbeHealthEnvelope.self, from: data),
              let service = payload.service?.trimmingCharacters(in: .whitespacesAndNewlines),
              !service.isEmpty else {
            return nil
        }
        return service
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1"
    }

    static func isResolvableHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if isLoopbackHost(trimmed) || isIPAddress(trimmed) {
            return true
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: 0,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, nil, &hints, &result)
        if let result {
            freeaddrinfo(result)
        }
        return status == 0
    }

    private static func normalizedVaultHostCandidate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let atIndex = value.lastIndex(of: "@"), atIndex < value.endIndex {
            value = String(value[value.index(after: atIndex)...])
        }

        if let host = URLComponents(string: value)?.host {
            value = host
        } else if let host = URLComponents(string: "http://\(value)")?.host {
            value = host
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value == "valut.local" {
            return "vault.local"
        }
        return value
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            return true
        }
        var addr6 = in6_addr()
        return inet_pton(AF_INET6, host, &addr6) == 1
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
