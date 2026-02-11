import Foundation

enum GodGatewayClient {
    struct GodResponse: Decodable {
        let ok: Bool?
        let error: String?
        let requestId: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case error
            case requestId = "request_id"
        }
    }

    static func godURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = firstNonEmpty(env["GOD_URL"], env["GOD_GATEWAY_URL"]),
           let url = URL(string: fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        let aux = (env["AUX_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "192.168.8.114"
        return URL(string: "http://\(aux):8099/god")
    }

    static func postAction(action: String, scope: String, target: String?, reason: String, args: [String: Any] = [:]) async -> (ok: Bool, detail: String) {
        guard let url = godURL() else { return (false, "invalid GOD_URL") }
        var payload: [String: Any] = [
            "action": action,
            "scope": scope,
            "reason": reason,
            "ts_ms": 0,
            "args": args,
        ]
        payload["target"] = target as Any
        payload["request_id"] = UUID().uuidString

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return (false, "payload encode failed")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                return (false, "HTTP \(status) \(text)")
            }
            if let decoded = try? JSONDecoder().decode(GodResponse.self, from: data) {
                if decoded.ok == true { return (true, "ok") }
                if let err = decoded.error, !err.isEmpty { return (false, err) }
            }
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

