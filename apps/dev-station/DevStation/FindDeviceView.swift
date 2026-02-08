import SwiftUI

struct FindDeviceView: View {
    let baseURL: String
    let onBindAlias: (String, String) -> Void
    let onRegisterNode: (WhoamiPayload, DeviceCandidate, String?) -> Void
    let onRegisterFallback: (DeviceCandidate, String?) -> Void
    let onClose: () -> Void

    @State private var nodeID: String = ""
    @State private var isRunning = false
    @State private var statusText: String = ""
    @State private var candidates: [DeviceCandidate] = []
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Find Newly Flashed Device", onBack: nil, onClose: onClose)

            Text("Run a local scan to identify fresh devices, then bind one to a node record.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                TextField("Node ID (optional)", text: $nodeID)
                    .textFieldStyle(.roundedBorder)
                Button(isRunning ? "Scanning..." : "Run Scan") { runScan() }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isRunning)
                Spacer()
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            runScan()
        }
    }

    private func candidateCard(_ candidate: DeviceCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(candidate.displayLabel)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Confidence \(candidate.confidence)%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let ip = candidate.ip {
                Text("IP: \(ip)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            if let mac = candidate.mac {
                Text("MAC: \(mac)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            if let ssid = candidate.ssid {
                Text("SSID: \(ssid)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            if let whoami = candidate.whoami, !whoami.isEmpty {
                Text("Whoami: \(whoami)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                Button("Bind as Node") {
                    bindCandidate(candidate)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Spacer()
            }
        }
        .padding(10)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func bindCandidate(_ candidate: DeviceCandidate) {
        let trimmedNode = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasLabel = trimmedNode.isEmpty ? nil : trimmedNode
        if let ip = candidate.ip {
            onBindAlias(ip, aliasLabel ?? ip)
        }
        if let mac = candidate.mac {
            onBindAlias(mac, aliasLabel ?? mac)
        }
        if let payload = WhoamiParser.parse(candidate.whoami) {
            onRegisterNode(payload, candidate, aliasLabel)
        } else if let ip = candidate.ip {
            Task {
                if let payload = await fetchWhoami(ip: ip) {
                    await MainActor.run {
                        onRegisterNode(payload, candidate, aliasLabel)
                    }
                } else {
                    await MainActor.run {
                        onRegisterFallback(candidate, aliasLabel)
                        lastError = "Registered without /whoami verification."
                    }
                }
            }
        } else if let aliasLabel {
            onBindAlias("node:\(aliasLabel)", aliasLabel)
            onRegisterFallback(candidate, aliasLabel)
        } else {
            onRegisterFallback(candidate, nil)
        }
    }

    private func fetchWhoami(ip: String) async -> WhoamiPayload? {
        guard let url = URL(string: "http://\(ip)/whoami") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status >= 200 && status < 300 else { return nil }
            let text = String(data: data, encoding: .utf8)
            return WhoamiParser.parse(text)
        } catch {
            return nil
        }
    }

    private func runScan() {
        isRunning = true
        lastError = nil
        statusText = "Scanning wifi + arp + whoami..."
        Task {
            defer { isRunning = false }
            let wifi = await safeRunTool(name: "net.wifi_scan", input: ["pattern": "esp|portal|sods|ops|c3|esp32"])
            let arp = await safeRunTool(name: "net.arp", input: [:])
            let rollcall = await safeRunTool(name: "net.whoami_rollcall", input: ["timeout_ms": 1500])

            let candidates = CandidateBuilder.build(wifi: wifi.response, arp: arp.response, whoami: rollcall.response)
            await MainActor.run {
                self.candidates = candidates
                self.statusText = "Found \(candidates.count) candidates"
                let errors = [wifi, arp, rollcall]
                    .filter { !$0.response.ok }
                    .compactMap { $0.errorMessage }
                if !errors.isEmpty {
                    self.lastError = errors.joined(separator: " • ")
                }
            }
        }
    }

    private func runTool(name: String, input: [String: Any]) async throws -> ToolRunResponse {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tool/run") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "input": input])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ToolRunError.httpFailure(status: http.statusCode, body: body)
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(ToolRunResponse.self, from: data) {
            return decoded
        }
        return ToolRunResponse.fallback(name: name, data: data)
    }

    private func safeRunTool(name: String, input: [String: Any]) async -> (response: ToolRunResponse, errorMessage: String?) {
        do {
            let response = try await runTool(name: name, input: input)
            if response.ok {
                return (response, nil)
            }
            let hint = response.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = hint?.isEmpty == false ? hint! : "Tool \(name) returned no results."
            return (response, message)
        } catch {
            let message = "Tool \(name) failed: \(error.localizedDescription)"
            return (ToolRunResponse(ok: false, name: name, stdout: nil, resultJson: nil), message)
        }
    }
}

struct ToolRunResponse: Decodable {
    let ok: Bool
    let name: String?
    let stdout: String?
    let resultJson: JSONValue?

    enum CodingKeys: String, CodingKey {
        case ok
        case name
        case stdout
        case resultJson = "result_json"
    }

    init(ok: Bool, name: String?, stdout: String?, resultJson: JSONValue?) {
        self.ok = ok
        self.name = name
        self.stdout = stdout
        self.resultJson = resultJson
    }

    static func fallback(name: String, data: Data) -> ToolRunResponse {
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let object = json as? [String: Any] {
            let ok = (object["ok"] as? Bool) ?? false
            let stdout = object["stdout"] as? String
            let resultJson: JSONValue? = {
                guard let payload = object["result_json"] else { return nil }
                if let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let decoded = try? JSONDecoder().decode(JSONValue.self, from: encoded) {
                    return decoded
                }
                return nil
            }()
            return ToolRunResponse(ok: ok, name: name, stdout: stdout, resultJson: resultJson)
        }
        let text = String(data: data, encoding: .utf8)
        return ToolRunResponse(ok: false, name: name, stdout: text, resultJson: nil)
    }
}

enum ToolRunError: LocalizedError {
    case httpFailure(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .httpFailure(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Tool endpoint returned HTTP \(status)."
            }
            return "Tool endpoint returned HTTP \(status): \(trimmed)"
        }
    }
}

struct DeviceCandidate: Identifiable {
    let id = UUID()
    let ip: String?
    let mac: String?
    let ssid: String?
    let whoami: String?
    let confidence: Int

    var displayLabel: String {
        if let ip { return ip }
        if let mac { return mac }
        return "Unknown device"
    }
}

enum CandidateBuilder {
    static func build(wifi: ToolRunResponse, arp: ToolRunResponse, whoami: ToolRunResponse) -> [DeviceCandidate] {
        let wifiLines = extractLines(from: wifi)
        let arpLines = extractLines(from: arp)
        let whoamiMap = extractWhoami(from: whoami)

        var byKey: [String: DeviceCandidate] = [:]

        func mergeCandidate(_ current: DeviceCandidate?, with incoming: DeviceCandidate) -> DeviceCandidate {
            guard let current else { return incoming }
            return DeviceCandidate(
                ip: current.ip ?? incoming.ip,
                mac: current.mac ?? incoming.mac,
                ssid: current.ssid ?? incoming.ssid,
                whoami: current.whoami ?? incoming.whoami,
                confidence: max(current.confidence, incoming.confidence)
            )
        }

        func upsert(_ candidate: DeviceCandidate) {
            let macKey = candidate.mac?.lowercased()
            let key: String = {
                if let macKey, !macKey.isEmpty { return "mac:\(macKey)" }
                if let ip = candidate.ip, !ip.isEmpty { return "ip:\(ip)" }
                if let ssid = candidate.ssid, !ssid.isEmpty { return "ssid:\(ssid.lowercased())" }
                return "unknown:\(UUID().uuidString)"
            }()
            byKey[key] = mergeCandidate(byKey[key], with: candidate)
        }

        for line in wifiLines {
            if let mac = matchMac(line) {
                let ssid = line.split(separator: mac).first.map { String($0).trimmingCharacters(in: .whitespaces) }
                upsert(DeviceCandidate(ip: nil, mac: mac, ssid: ssid, whoami: nil, confidence: 55))
            }
        }

        for line in arpLines {
            guard let ip = matchIP(line), let mac = matchMac(line) else { continue }
            upsert(DeviceCandidate(ip: ip, mac: mac, ssid: nil, whoami: nil, confidence: 70))
        }

        for (ip, who) in whoamiMap {
            let keys = byKey.filter { $0.value.ip == ip }.map(\.key)
            if keys.isEmpty {
                upsert(DeviceCandidate(ip: ip, mac: nil, ssid: nil, whoami: who, confidence: 80))
            } else {
                for key in keys {
                    if let existing = byKey[key] {
                        byKey[key] = DeviceCandidate(
                            ip: existing.ip,
                            mac: existing.mac,
                            ssid: existing.ssid,
                            whoami: who,
                            confidence: min(95, existing.confidence + 20)
                        )
                    }
                }
            }
        }

        return byKey.values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            let l = (lhs.ssid ?? lhs.mac ?? lhs.ip ?? "")
            let r = (rhs.ssid ?? rhs.mac ?? rhs.ip ?? "")
            return l < r
        }
    }

    private static func extractLines(from response: ToolRunResponse) -> [String] {
        if let result = response.resultJson?.objectValue,
           let lines = result["lines"]?.arrayValue {
            return lines.compactMap { $0.stringValue }
        }
        return response.stdout?.split(separator: "\n").map(String.init) ?? []
    }

    private static func extractWhoami(from response: ToolRunResponse) -> [String: String] {
        if let result = response.resultJson?.objectValue,
           let results = result["results"]?.objectValue {
            var map: [String: String] = [:]
            for (key, value) in results {
                map[key] = value.stringValue ?? ""
            }
            return map
        }
        return [:]
    }

    private static func matchMac(_ line: String) -> String? {
        let pattern = "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"
        return line.range(of: pattern, options: .regularExpression).map { String(line[$0]) }
    }

    private static func matchIP(_ line: String) -> String? {
        let pattern = "(\\d{1,3}\\.){3}\\d{1,3}"
        return line.range(of: pattern, options: .regularExpression).map { String(line[$0]) }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
