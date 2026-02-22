import SwiftUI

struct PresetBuilderView: View {
    let baseURL: String
    let onClose: () -> Void

    @State private var presetId = ""
    @State private var title = ""
    @State private var description = ""
    @State private var kind = "single"
    @State private var toolName = ""
    @State private var inputJson = "{}"
    @State private var varsJson = "{}"
    @State private var stepsJson = "[]"
    @State private var capsule = true
    @State private var lastError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Preset Builder", onBack: nil, onClose: onClose)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("ID", text: $presetId)
                            .textFieldStyle(.roundedBorder)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("Description", text: $description)
                        .textFieldStyle(.roundedBorder)

                    Picker("Kind", selection: $kind) {
                        Text("single").tag("single")
                        Text("macro").tag("macro")
                    }
                    .pickerStyle(.segmented)

                    if kind == "single" {
                        TextField("Tool name", text: $toolName)
                            .textFieldStyle(.roundedBorder)
                        Text("Input (JSON)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextEditor(text: $inputJson)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 100)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    } else {
                        Text("Vars (JSON)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextEditor(text: $varsJson)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 80)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        Text("Steps (JSON array)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextEditor(text: $stepsJson)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 140)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    }

                    Toggle("Show as capsule button", isOn: $capsule)
                        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

                    if let lastError {
                        Text(lastError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    HStack(spacing: 10) {
                        Text("Save Preset")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button { savePreset() } label: {
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
                        .help(isSaving ? "Saving..." : "Save Preset")
                        .accessibilityLabel(Text(isSaving ? "Saving..." : "Save Preset"))
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    private func savePreset() {
        guard !presetId.isEmpty else {
            lastError = "Preset ID is required."
            return
        }
        isSaving = true
        lastError = nil
        var preset: [String: Any] = [
            "id": presetId,
            "title": title.isEmpty ? presetId : title,
            "description": description,
            "kind": kind,
            "ui": ["capsule": capsule]
        ]
        if kind == "single" {
            preset["tool"] = toolName
            preset["input"] = parseJson(inputJson)
        } else {
            preset["vars"] = parseJson(varsJson)
            preset["steps"] = parseJson(stepsJson)
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/presets/user/add") else {
            lastError = "Invalid station URL"
            isSaving = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["preset": preset])
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
        return kind == "macro" ? [] : [:]
    }
}
