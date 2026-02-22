import SwiftUI

struct PresetRunResult: Decodable, Identifiable {
    let id: String
    let ok: Bool
    let results: [String: ToolRunResult]
}

struct ToolRunResult: Decodable {
    let ok: Bool
    let name: String
    let exitCode: Int
    let durationMs: Int
    let stdout: String
    let stderr: String
    let resultJson: [String: AnyCodable]?
    let urls: [String]?

    enum CodingKeys: String, CodingKey {
        case ok, name, stdout, stderr, urls
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
        case resultJson = "result_json"
    }
}

struct PresetRunnerView: View {
    let preset: PresetDefinition
    let baseURL: String
    let onOpenViewer: (URL) -> Void
    let onClose: () -> Void

    @State private var output: PresetRunResult?
    @State private var lastError: String?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: preset.name, onBack: nil, onClose: onClose)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let desc = preset.description {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }

                    HStack(spacing: 10) {
                        Text("Run Preset")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button { runPreset() } label: {
                            if isRunning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(isRunning)
                        .help(isRunning ? "Running..." : "Run Preset")
                        .accessibilityLabel(Text(isRunning ? "Running..." : "Run Preset"))
                    }

                    if let lastError {
                        Text(lastError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let output {
                                ForEach(output.results.keys.sorted(), id: \.self) { key in
                                    if let result = output.results[key] {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(key) • \(result.name) • \(result.ok ? "ok" : "err")")
                                                .font(.system(size: 11, weight: .semibold))
                                            Text(result.stdout)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(Theme.textPrimary)
                                            if let urls = result.urls, let first = urls.first, let url = URL(string: first) {
                                                Button { onOpenViewer(url) } label: {
                                                    Image(systemName: "arrow.up.right.square")
                                                        .font(.system(size: 12, weight: .semibold))
                                                }
                                                    .buttonStyle(SecondaryActionButtonStyle())
                                                    .help("Open Viewer")
                                                    .accessibilityLabel(Text("Open Viewer"))
                                            }
                                        }
                                        .padding(8)
                                        .background(Theme.panelAlt)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            } else {
                                Text("No output yet.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    private func runPreset() {
        isRunning = true
        lastError = nil
        output = nil
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/preset/run") else {
            lastError = "Invalid station URL"
            isRunning = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": preset.id])
        Task {
            defer { isRunning = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                output = try JSONDecoder().decode(PresetRunResult.self, from: data)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
