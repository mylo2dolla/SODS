import SwiftUI

struct ScratchpadView: View {
    let baseURL: String
    let onSaveAsTool: (String, String) -> Void
    let onClose: () -> Void

    @State private var runner = "shell"
    @State private var script = ""
    @State private var inputJson = "{}"
    @State private var outputText = ""
    @State private var lastError: String?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Scratchpad", onBack: nil, onClose: onClose)

            Picker("Runner", selection: $runner) {
                Text("shell").tag("shell")
                Text("python").tag("python")
                Text("node").tag("node")
            }
            .pickerStyle(.segmented)

            Text("Input (JSON)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextEditor(text: $inputJson)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            Text("Script")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextEditor(text: $script)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 10) {
                Button { runScratch() } label: {
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
                Button {
                    onSaveAsTool(runner, script)
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Save as Tool")
                .accessibilityLabel(Text("Save as Tool"))
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
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    private func runScratch() {
        isRunning = true
        lastError = nil
        outputText = ""
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/scratch/run") else {
            lastError = "Invalid station URL"
            isRunning = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let inputObj = parseJson(inputJson)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["runner": runner, "script": script, "input": inputObj])
        Task {
            defer { isRunning = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                outputText = String(data: data, encoding: .utf8) ?? ""
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func parseJson(_ text: String) -> Any {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return obj
        }
        return [:]
    }
}
