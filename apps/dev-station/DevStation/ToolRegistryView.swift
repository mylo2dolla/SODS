import SwiftUI

struct ToolRegistryView: View {
    @ObservedObject var registry: ToolRegistry
    let baseURL: String
    let onFlash: () -> Void
    let onInspect: (ContentView.APIEndpoint) -> Void
    let onRunTool: (ToolDefinition) -> Void
    let onRunRunbook: (String) -> Void
    let onBuildTool: () -> Void
    let onBuildPreset: () -> Void
    let onScratchpad: () -> Void
    let onClose: () -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Tool Registry", onBack: nil, onClose: onClose)

            HStack(spacing: 10) {
                TextField("Search tools", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("View JSON") {
                    onInspect(.tools)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                Button("Flash") {
                    onFlash()
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Button("Build Tool") { onBuildTool() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Button("Build Preset") { onBuildPreset() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Button("Scratchpad") { onScratchpad() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }

            if let note = registry.policyNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            let filtered = registry.tools.filter { tool in
                if searchText.isEmpty { return true }
                let needle = searchText.lowercased()
                return tool.name.lowercased().contains(needle)
                    || (tool.scope ?? "").lowercased().contains(needle)
                    || (tool.kind ?? "").lowercased().contains(needle)
                    || (tool.description ?? "").lowercased().contains(needle)
            }

            if filtered.isEmpty {
                Text("No tools available.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filtered) { tool in
                            ToolRow(
                                tool: tool,
                                onRun: {
                                    if tool.kind == "runbook" {
                                        onRunRunbook(tool.name)
                                    } else {
                                        onRunTool(tool)
                                    }
                                },
                                onInspect: { onInspect(.tools) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear { registry.reload() }
    }
}

private struct ToolRow: View {
    let tool: ToolDefinition
    let onRun: () -> Void
    let onInspect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.title ?? tool.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(tool.scope ?? (tool.tags?.first ?? "tool"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text((tool.kind ?? "tool").uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.panelAlt)
                    .clipShape(Capsule())
            }
            Text(tool.description ?? "")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let input = tool.input {
                Text("Input: \(input)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let output = tool.output?.format {
                Text("Output: \(output)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button("Run") { onRun() }
                    .buttonStyle(PrimaryActionButtonStyle())
                Button("View JSON") { onInspect() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
            }
        }
        .padding(10)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}
