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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Actions")
                    .font(.system(size: 14, weight: .semibold))
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
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
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(!item.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 480)
        .background(Theme.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
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
