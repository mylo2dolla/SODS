import SwiftUI
import AppKit

struct APIInspectorView: View {
    let baseURL: String
    @State var endpoint: ContentView.APIEndpoint
    let onClose: () -> Void
    let onBack: (() -> Void)?

    @State private var jsonText: String = ""
    @State private var isLoading = false
    @State private var lastError: String?
    @State private var autoRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "API Inspector", onBack: onBack, onClose: onClose)

            HStack(spacing: 10) {
                Picker("Endpoint", selection: $endpoint) {
                    ForEach(ContentView.APIEndpoint.allCases) { ep in
                        Text(ep.label).tag(ep)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Auto-refresh", isOn: $autoRefresh)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    .font(.system(size: 11))
                Button("Refresh") { fetch() }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Copy JSON") { copyJSON() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            ScrollView {
                Text(jsonText.isEmpty ? "No data yet." : jsonText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear { fetch() }
        .onChange(of: endpoint) { _ in fetch() }
        .onChange(of: autoRefresh) { enabled in
            if enabled {
                scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        Task {
            while autoRefresh {
                fetch()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetch() {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base + endpoint.rawValue) else { return }
        isLoading = true
        lastError = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let pretty = prettyJSON(data) {
                    jsonText = pretty
                } else {
                    jsonText = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                lastError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func prettyJSON(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: pretty, encoding: .utf8)
        }
        return nil
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jsonText, forType: .string)
    }
}
