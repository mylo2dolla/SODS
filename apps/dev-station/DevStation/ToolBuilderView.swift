import SwiftUI

struct ToolBuilderView: View {
    let baseURL: String
    let onClose: () -> Void

    @State private var name = ""
    @State private var title = ""
    @State private var description = ""
    @State private var runner = "shell"
    @State private var kind = "inspect"
    @State private var tags = ""
    @State private var timeoutMs = ""
    @State private var script = ""
    @State private var inputSchema = "{}"
    @State private var outputFormat = "text"
    @State private var lastError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Tool Builder", onBack: nil, onClose: onClose)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("Description", text: $description)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Picker("Runner", selection: $runner) {
                            Text("shell").tag("shell")
                            Text("python").tag("python")
                            Text("node").tag("node")
                        }
                        .pickerStyle(.segmented)
                        Picker("Kind", selection: $kind) {
                            Text("inspect").tag("inspect")
                            Text("action").tag("action")
                            Text("report").tag("report")
                        }
                        .pickerStyle(.segmented)
                        TextField("Timeout ms (optional)", text: $timeoutMs)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("Tags (comma-separated)", text: $tags)
                        .textFieldStyle(.roundedBorder)

                    Text("Input Schema (JSON)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextEditor(text: $inputSchema)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

                    TextField("Output format (text|json|url|ndjson)", text: $outputFormat)
                        .textFieldStyle(.roundedBorder)

                    Text("Script")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextEditor(text: $script)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

                    if let lastError {
                        Text(lastError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    HStack(spacing: 10) {
                        Text("Save Tool")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button { saveTool() } label: {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(isSaving)
                        .help(isSaving ? "Saving..." : "Save Tool")
                        .accessibilityLabel(Text(isSaving ? "Saving..." : "Save Tool"))
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    private func saveTool() {
        guard !name.isEmpty else {
            lastError = "Name is required."
            return
        }
        isSaving = true
        lastError = nil
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let inputSchemaObj = parseJson(inputSchema)
        var entry: [String: Any] = [
            "name": name,
            "title": title.isEmpty ? name : title,
            "description": description,
            "runner": runner,
            "kind": kind,
            "tags": tagList,
            "input_schema": inputSchemaObj,
            "output": ["format": outputFormat]
        ]
        if let timeoutValue = Int(timeoutMs), timeoutValue > 0 {
            entry["timeout_ms"] = timeoutValue
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/tools/user/add") else {
            lastError = "Invalid station URL"
            isSaving = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["entry": entry, "script": script])
        Task {
            defer { isSaving = false }
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = "Save failed (\(http.statusCode))."
                }
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
