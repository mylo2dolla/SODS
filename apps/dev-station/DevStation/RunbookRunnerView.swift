import SwiftUI
import AppKit

struct RunbookRunResult: Decodable {
    let ok: Bool
    let id: String
    let results: [String: ToolRunResult]
    let summary: String?
    let artifacts: [RunbookArtifact]?
}

struct RunbookArtifact: Decodable, Identifiable {
    let path: String
    let filename: String
    var id: String { path }
}

struct RunbookRunnerView: View {
    let runbook: RunbookDefinition
    let baseURL: String
    let onOpenViewer: (URL) -> Void
    let onClose: () -> Void

    @State private var output: RunbookRunResult?
    @State private var lastError: String?
    @State private var isRunning = false
    @State private var inputJson = "{}"
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: runbook.name, onBack: nil, onClose: onClose)

            if let desc = runbook.description {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                Button { runRunbook() } label: {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isRunning)
                    .help(isRunning ? "Running..." : "Run")
                    .accessibilityLabel(Text(isRunning ? "Running..." : "Run"))
                Button { stopRunbook() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!isRunning)
                    .help("Stop")
                    .accessibilityLabel(Text("Stop"))
                Button { copyReport() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Copy Report")
                    .accessibilityLabel(Text("Copy Report"))
                Spacer()
            }

            GroupBox("Input JSON") {
                TextEditor(text: $inputJson)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 90)
            }
            if let schema = runbook.inputSchema, !schema.isEmpty {
                Text("Input schema: \(schema.keys.sorted().joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            GroupBox("Steps") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runbook.steps ?? []) { entry in
                        if case .parallel(let group) = entry {
                            Text("Parallel group")
                                .font(.system(size: 11, weight: .semibold))
                            ForEach(group.parallel) { step in
                                stepRow(step)
                            }
                        } else if case .single(let step) = entry {
                            stepRow(step)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let output {
                        if let artifacts = output.artifacts, !artifacts.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Artifacts")
                                    .font(.system(size: 11, weight: .semibold))
                                ForEach(artifacts) { artifact in
                                    Text(artifact.filename)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
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
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onDisappear { task?.cancel() }
    }

    private func stepRow(_ step: RunbookStep) -> some View {
        let status = output?.results[step.id]?.ok == true ? "ok" : (output?.results[step.id] == nil ? (isRunning ? "running" : "pending") : "err")
        return HStack(spacing: 8) {
            Text(step.id)
                .font(.system(size: 11, weight: .semibold))
            Text(step.tool)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(status)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.panel)
                .clipShape(Capsule())
        }
    }

    private func runRunbook() {
        isRunning = true
        lastError = nil
        output = nil
        task?.cancel()
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/runbook/run") else {
            lastError = "Invalid station URL"
            isRunning = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let input = parseJson(inputJson)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": runbook.id, "input": input])
        task = Task {
            defer { isRunning = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                output = try JSONDecoder().decode(RunbookRunResult.self, from: data)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func stopRunbook() {
        task?.cancel()
        isRunning = false
        lastError = "Stopped (local cancel)"
    }

    private func copyReport() {
        let summary = output?.summary ?? "runbook \(runbook.id)"
        var lines = [summary]
        if let output {
            for (key, result) in output.results {
                lines.append("\(key): \(result.ok ? "ok" : "err")")
            }
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func parseJson(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8) else { return [:] }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []), let dict = obj as? [String: Any] {
            return dict
        }
        return [:]
    }
}
