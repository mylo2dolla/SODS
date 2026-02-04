import SwiftUI

struct RunbookListView: View {
    @ObservedObject var registry: RunbookRegistry
    let onRunbook: (RunbookDefinition) -> Void
    let onInspect: () -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Runbooks")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("View JSON") { onInspect() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }

            TextField("Search runbooks", text: $searchText)
                .textFieldStyle(.roundedBorder)

            let filtered = registry.runbooks.filter { runbook in
                if searchText.isEmpty { return true }
                let needle = searchText.lowercased()
                return runbook.id.lowercased().contains(needle)
                    || (runbook.title?.lowercased().contains(needle) ?? false)
                    || (runbook.tags?.joined(separator: " ").lowercased().contains(needle) ?? false)
            }

            if filtered.isEmpty {
                Text("No runbooks available.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { runbook in
                        Button(action: { onRunbook(runbook) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(runbook.title ?? runbook.id)
                                    .font(.system(size: 13, weight: .semibold))
                                if let desc = runbook.description, !desc.isEmpty {
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
