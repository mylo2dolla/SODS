import SwiftUI

struct AliasManagerView: View {
    let aliases: [String: String]
    let onSave: (String, String) -> Void
    let onDelete: (String) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var editing: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Aliases", onBack: nil, onClose: onClose)
            HStack {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Close") { onClose() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredKeys, id: \.self) { id in
                        AliasRow(
                            id: id,
                            alias: aliasValue(for: id),
                            onSave: { value in onSave(id, value) },
                            onDelete: { onDelete(id) }
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.background)
        .frame(minWidth: 500, minHeight: 420)
    }

    private var filteredKeys: [String] {
        let keys = aliases.keys.sorted()
        guard !searchText.isEmpty else { return keys }
        return keys.filter { $0.localizedCaseInsensitiveContains(searchText) || aliasValue(for: $0).localizedCaseInsensitiveContains(searchText) }
    }

    private func aliasValue(for id: String) -> String {
        if let edit = editing[id] { return edit }
        return aliases[id] ?? ""
    }
}

struct AliasRow: View {
    let id: String
    let alias: String
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(id)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            HStack(spacing: 8) {
                TextField("alias", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { text = alias }
                Button("Save") { onSave(text) }
                    .buttonStyle(SecondaryActionButtonStyle())
                Button("Delete") { onDelete() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            Divider().opacity(0.2)
        }
    }
}
