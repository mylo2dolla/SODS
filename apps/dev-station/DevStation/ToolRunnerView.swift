import SwiftUI

struct ToolRunnerView: View {
    let baseURL: String
    let tool: ToolDefinition
    let onOpenViewer: (URL) -> Void
    let onClose: () -> Void
    let onBack: (() -> Void)?

    @State private var fieldInputs: [String: String] = [:]
    @State private var jsonInput: String = "{}"
    @State private var outputText: String = ""
    @State private var lastError: String?
    @State private var isRunning = false
    @State private var useJsonEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: tool.name, onBack: onBack, onClose: onClose)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tool.description ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)

                    if !inputFields.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(inputFields, id: \.self) { field in
                                HStack {
                                    Text(field)
                                        .font(.system(size: 11))
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: Binding(
                                        get: { fieldInputs[field] ?? "" },
                                        set: { fieldInputs[field] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        Toggle("Advanced JSON input", isOn: $useJsonEditor)
                            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                            .font(.system(size: 11))
                    }

                    if useJsonEditor {
                        TextEditor(text: $jsonInput)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                    }

                    HStack(spacing: 8) {
                        Text("Run")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button { runTool() } label: {
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
                        .help(isRunning ? "Running..." : "Run")
                        .accessibilityLabel(Text(isRunning ? "Running..." : "Run"))
                        Spacer()
                    }

                    if let lastError {
                        Text(lastError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    ScrollView {
                        Text(outputText.isEmpty ? "No output yet." : outputText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.panelAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            seedDefaultInput()
            if inputFields.isEmpty {
                useJsonEditor = true
            }
        }
    }

    private var inputFields: [String] {
        let raw = (tool.input ?? "").lowercased()
        if raw == "none" { return [] }
        let parts = (tool.input ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let fields = parts.compactMap { part -> String? in
            let key = part.split(separator: " ").first?.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            return key?.isEmpty == false ? String(key!) : nil
        }
        return Array(Set(fields)).sorted()
    }

    private func seedDefaultInput() {
        if !inputFields.isEmpty {
            for field in inputFields where fieldInputs[field] == nil {
                fieldInputs[field] = ""
            }
        }
    }

    private func runTool() {
        isRunning = true
        lastError = nil
        outputText = ""
        let payload = buildInputPayload()
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tool/run") else {
            lastError = "Invalid station URL"
            isRunning = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": tool.name, "input": payload]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            defer { isRunning = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let pretty = prettyJSON(data) {
                    outputText = pretty
                } else {
                    outputText = String(data: data, encoding: .utf8) ?? ""
                }
                tryOpenViewer(from: data)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func buildInputPayload() -> [String: String] {
        if useJsonEditor {
            if let data = jsonInput.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return obj
            }
        }
        return fieldInputs
    }

    private func prettyJSON(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: pretty, encoding: .utf8)
        }
        return nil
    }

    private func tryOpenViewer(from data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let urls = obj["urls"] as? [String], let first = urls.first, let url = URL(string: first) {
            onOpenViewer(url)
            return
        }
        if let result = obj["result_json"] as? [String: Any], let urlString = result["url"] as? String, let url = URL(string: urlString) {
            onOpenViewer(url)
        }
    }
}
