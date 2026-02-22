import SwiftUI
import AppKit

struct AliasManagerView: View {
    let aliases: [String: String]
    let onSave: (String, String) -> Void
    let onDelete: (String) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var editing: [String: String] = [:]
    @State private var showImport = false
    @State private var importText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Aliases", onBack: nil, onClose: onClose)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        Button { exportAliases() } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Export")
                            .accessibilityLabel(Text("Export"))
                        Button { showImport = true } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Import")
                            .accessibilityLabel(Text("Import"))
                        Button { onClose() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .help("Close")
                            .accessibilityLabel(Text("Close"))
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
            }
        }
        .padding(16)
        .background(Theme.background)
        .frame(minWidth: 520, minHeight: 360)
        .sheet(isPresented: $showImport) {
            VStack(alignment: .leading, spacing: 12) {
                ModalHeaderView(title: "Import Aliases", onBack: nil, onClose: { showImport = false })
                Text("Paste JSON mapping of id -> alias.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextEditor(text: $importText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 240)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                HStack {
                    Button { importAliases() } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .help("Apply")
                        .accessibilityLabel(Text("Apply"))
                    Button { showImport = false } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .help("Cancel")
                        .accessibilityLabel(Text("Cancel"))
                }
                Spacer()
            }
            .padding(16)
            .frame(minWidth: 420, minHeight: 320)
        }
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

    private func exportAliases() {
        let payload = ["aliases": aliases]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func importAliases() {
        guard let data = importText.data(using: .utf8) else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let map = (obj["aliases"] as? [String: String]) ?? (obj as? [String: String]) ?? [:]
            for (id, alias) in map {
                onSave(id, alias)
            }
            showImport = false
        }
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
                Button { onSave(text) } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Save")
                    .accessibilityLabel(Text("Save"))
                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .help("Delete")
                    .accessibilityLabel(Text("Delete"))
            }
            Divider().opacity(0.2)
        }
    }
}
