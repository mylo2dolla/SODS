import SwiftUI

struct PresetButtonsView: View {
    @ObservedObject var registry: PresetRegistry
    let onRunPreset: (PresetDefinition) -> Void
    let onOpenRunner: (PresetDefinition) -> Void
    let onOpenBuilder: () -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Buttons")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { onOpenBuilder() } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .help("New Preset")
                    .accessibilityLabel(Text("New Preset"))
            }

            TextField("Search presets", text: $searchText)
                .textFieldStyle(.roundedBorder)

            let filtered = registry.presets.filter { preset in
                if searchText.isEmpty { return true }
                let needle = searchText.lowercased()
                return preset.id.lowercased().contains(needle)
                    || (preset.title?.lowercased().contains(needle) ?? false)
                    || (preset.tags?.joined(separator: " ").lowercased().contains(needle) ?? false)
            }

            if filtered.isEmpty {
                Text("No presets available.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { preset in
                        Button(action: { onRunPreset(preset) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preset.title ?? preset.id)
                                    .font(.system(size: 13, weight: .semibold))
                                if let desc = preset.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panelAlt)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .shadow(color: Theme.accent.opacity(0.2), radius: 6, x: 0, y: 3)
                        }
                        .contextMenu {
                            Button { onOpenRunner(preset) } label: {
                                Label("Open Runner", systemImage: "play.circle")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear { registry.reload() }
    }
}
