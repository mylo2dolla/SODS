import SwiftUI

struct ToolRegistryView: View {
    @ObservedObject var registry: ToolRegistry
    let baseURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SODS Tool Registry")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Open /tools") {
                    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: trimmed + "/tools") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }

            if let note = registry.policyNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if registry.tools.isEmpty {
                Text("No tools available.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(registry.tools) { tool in
                            ToolRow(tool: tool)
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
    }
}

private struct ToolRow: View {
    let tool: ToolDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(tool.scope)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(tool.kind.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.surface)
                    .clipShape(Capsule())
            }
            Text(tool.description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Input: \(tool.input)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Output: \(tool.output)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}
