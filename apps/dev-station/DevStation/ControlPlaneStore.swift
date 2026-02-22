import Foundation

@MainActor
final class ControlPlaneStore: ObservableObject {
    static let shared = ControlPlaneStore()

    struct Endpoints: Equatable {
        var vaultHealth: URL
        var gatewayHealth: URL
        var opsFeedHealth: URL
        var tokenEndpoint: URL
    }

    struct CheckResult: Equatable {
        var ok: Bool
        var label: String
        var detail: String
        var checkedAt: Date
    }

    @Published private(set) var vault: CheckResult?
    @Published private(set) var token: CheckResult?
    @Published private(set) var gateway: CheckResult?
    @Published private(set) var opsFeed: CheckResult?

    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        Task {
            async let v = check(url: controlPlaneURLs().vaultHealth, label: "Vault")
            async let g = check(url: controlPlaneURLs().gatewayHealth, label: "God Gateway")
            async let o = check(url: controlPlaneURLs().opsFeedHealth, label: "Ops Feed")
            async let t = checkToken()
            let (vaultRes, gatewayRes, opsRes, tokenRes) = await (v, g, o, t)
            await MainActor.run {
                self.vault = vaultRes
                self.gateway = gatewayRes
                self.opsFeed = opsRes
                self.token = tokenRes
            }
        }
    }

    func probeTokenOnce() {
        Task {
            let tokenRes = await checkToken()
            await MainActor.run {
                self.token = tokenRes
            }
        }
    }

    func probeGatewayOnce() {
        Task {
            let urls = controlPlaneURLs()
            let result = await GodGatewayClient.postAction(
                action: "ritual.rollcall",
                scope: "all",
                target: nil,
                reason: "devstation.probe",
                args: [:]
            )
            let detail = result.detail.isEmpty ? (result.ok ? "ok" : "error") : result.detail
            let res = CheckResult(ok: result.ok, label: "God Gateway", detail: detail, checkedAt: Date())
            await MainActor.run {
                self.gateway = res
            }
            // Keep other checks fresh too, so the dashboard state converges quickly.
            let (vaultRes, opsRes) = await (check(url: urls.vaultHealth, label: "Vault"), check(url: urls.opsFeedHealth, label: "Ops Feed"))
            await MainActor.run {
                self.vault = vaultRes
                self.opsFeed = opsRes
            }
        }
    }

    func endpoints() -> Endpoints {
        let urls = controlPlaneURLs()
        return Endpoints(vaultHealth: urls.vaultHealth, gatewayHealth: urls.gatewayHealth, opsFeedHealth: urls.opsFeedHealth, tokenEndpoint: urls.tokenEndpoint)
    }

    private func controlPlaneURLs() -> (vaultHealth: URL, gatewayHealth: URL, opsFeedHealth: URL, tokenEndpoint: URL) {
        let env = ProcessInfo.processInfo.environment
        let auxHost = normalizedHost(env["AUX_HOST"], fallback: "192.168.8.114")
        let loggerHost = normalizedHost(env["LOGGER_HOST"], fallback: "192.168.8.160")

        let vault = URL(string: env["VAULT_HEALTH_URL"] ?? "http://\(loggerHost):8088/health")!
        let gateway = URL(string: env["GOD_HEALTH_URL"] ?? "http://\(auxHost):8099/health")!
        let opsFeed = URL(string: env["OPS_FEED_HEALTH_URL"] ?? "http://\(auxHost):9101/health")!
        let token = URL(string: env["TOKEN_URL"] ?? "http://\(auxHost):9123/token")!
        return (vaultHealth: vault, gatewayHealth: gateway, opsFeedHealth: opsFeed, tokenEndpoint: token)
    }

    private func normalizedHost(_ rawValue: String?, fallback: String) -> String {
        let cleaned = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? fallback : cleaned
        let lower = value.lowercased()
        if lower == "pi-aux" { return "pi-aux.local" }
        if lower == "pi-logger" { return "pi-logger.local" }
        if lower == "mac16" { return "mac16.local" }
        if lower == "mac8" { return "mac8.local" }
        return value
    }

    private func check(url: URL, label: String) async -> CheckResult {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(status) {
                let text = String(data: data, encoding: .utf8) ?? ""
                let detail = text.count > 180 ? "\(text.prefix(180))…" : text
                return CheckResult(ok: true, label: label, detail: detail.isEmpty ? "ok" : detail, checkedAt: Date())
            }
            return CheckResult(ok: false, label: label, detail: "HTTP \(status)", checkedAt: Date())
        } catch {
            return CheckResult(ok: false, label: label, detail: error.localizedDescription, checkedAt: Date())
        }
    }

    private func checkToken() async -> CheckResult {
        let urls = controlPlaneURLs()
        var req = URLRequest(url: urls.tokenEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["identity": "devstation", "room": "strangelab"], options: [])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                return CheckResult(ok: false, label: "Token", detail: "HTTP \(status)", checkedAt: Date())
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let ok = (obj?["ok"] as? Bool) == true
            let token = (obj?["token"] as? String) ?? ""
            if ok && !token.isEmpty {
                return CheckResult(ok: true, label: "Token", detail: "ok", checkedAt: Date())
            }
            let err = (obj?["error"] as? String) ?? "invalid response"
            return CheckResult(ok: false, label: "Token", detail: err, checkedAt: Date())
        } catch {
            return CheckResult(ok: false, label: "Token", detail: error.localizedDescription, checkedAt: Date())
        }
    }
}
