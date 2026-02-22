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
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("Search tools", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            onInspect(.tools)
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("View JSON")
                        .accessibilityLabel(Text("View JSON"))

                        Button {
                            onFlash()
                        } label: {
                            Image(systemName: "bolt.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .help("Flash")
                        .accessibilityLabel(Text("Flash"))

                        Button { onBuildTool() } label: {
                            Image(systemName: "hammer")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Build Tool")
                            .accessibilityLabel(Text("Build Tool"))

                        Button { onBuildPreset() } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Build Preset")
                            .accessibilityLabel(Text("Build Preset"))

                        Button { onScratchpad() } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Scratchpad")
                            .accessibilityLabel(Text("Scratchpad"))
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
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
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
                Button { onRun() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help("Run")
                    .accessibilityLabel(Text("Run"))
                Button { onInspect() } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("View JSON")
                    .accessibilityLabel(Text("View JSON"))
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
