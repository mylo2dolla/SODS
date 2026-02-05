import SwiftUI

struct FindDeviceView: View {
    let baseURL: String
    let onBindAlias: (String, String) -> Void
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
        if let ip = candidate.ip {
            onBindAlias(ip, trimmedNode.isEmpty ? ip : trimmedNode)
        }
        if let mac = candidate.mac {
            onBindAlias(mac, trimmedNode.isEmpty ? mac : trimmedNode)
        }
        if !trimmedNode.isEmpty {
            onBindAlias("node:\(trimmedNode)", trimmedNode)
        }
    }

    private func runScan() {
        isRunning = true
        lastError = nil
        statusText = "Scanning wifi + arp + whoami..."
        Task {
            defer { isRunning = false }
            do {
                let wifi = try await runTool(name: "net.wifi_scan", input: ["pattern": "esp|portal|sods|ops|c3|esp32"])
                let arp = try await runTool(name: "net.arp", input: [:])
                let rollcall = try await runTool(name: "net.whoami_rollcall", input: ["timeout_ms": 1500])

                let candidates = CandidateBuilder.build(wifi: wifi, arp: arp, whoami: rollcall)
                await MainActor.run {
                    self.candidates = candidates
                    self.statusText = "Found \(candidates.count) candidates"
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusText = "Scan failed"
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
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(ToolRunResponse.self, from: data)
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

        var byMac: [String: DeviceCandidate] = [:]
        for line in wifiLines {
            if let mac = matchMac(line) {
                let ssid = line.split(separator: mac).first.map { String($0).trimmingCharacters(in: .whitespaces) }
                byMac[mac] = DeviceCandidate(ip: nil, mac: mac, ssid: ssid, whoami: nil, confidence: 55)
            }
        }

        var byIP: [String: DeviceCandidate] = [:]
        for line in arpLines {
            guard let ip = matchIP(line), let mac = matchMac(line) else { continue }
            let existing = byMac[mac]
            byIP[ip] = DeviceCandidate(ip: ip, mac: mac, ssid: existing?.ssid, whoami: nil, confidence: 70)
            if existing == nil {
                byMac[mac] = DeviceCandidate(ip: ip, mac: mac, ssid: nil, whoami: nil, confidence: 65)
            }
        }

        var results: [DeviceCandidate] = []
        for (ip, who) in whoamiMap {
            var entry = byIP[ip] ?? DeviceCandidate(ip: ip, mac: nil, ssid: nil, whoami: nil, confidence: 60)
            entry = DeviceCandidate(ip: entry.ip, mac: entry.mac, ssid: entry.ssid, whoami: who, confidence: min(95, entry.confidence + 20))
            results.append(entry)
        }
        for entry in byIP.values where !results.contains(where: { $0.ip == entry.ip }) {
            results.append(entry)
        }
        for entry in byMac.values where entry.ip == nil {
            results.append(entry)
        }
        return results.sorted { $0.confidence > $1.confidence }
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
