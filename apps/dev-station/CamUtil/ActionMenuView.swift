import SwiftUI

struct ActionMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String?
    let enabled: Bool
    let reason: String?
    let action: () -> Void
}

struct ActionMenuSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [ActionMenuItem]
}

struct ActionMenuView: View {
    let sections: [ActionMenuSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Actions")
                    .font(.system(size: 14, weight: .semibold))
                Menu("Actions…") {
                    ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(section.items) { item in
                            Button {
                                item.action()
                            } label: {
                                if let systemImage = item.systemImage {
                                    Label(item.title, systemImage: systemImage)
                                } else {
                                    Text(item.title)
                                }
                            }
                            .disabled(!item.enabled)
                        }
                        if idx < sections.count - 1 {
                            Divider()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }

            let reasons = disabledReasons()
            if !reasons.isEmpty {
                Text("Disabled: \(reasons.joined(separator: " · "))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(8)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func disabledReasons() -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for section in sections {
            for item in section.items where !item.enabled {
                if let reason = item.reason, !reason.isEmpty, !seen.contains(reason) {
                    seen.insert(reason)
                    results.append(reason)
                }
            }
        }
        return results
    }
}
