import SwiftUI

enum LegalDocument {
    case privacyPolicy
    case termsOfUse

    var title: String {
        switch self {
        case .privacyPolicy:
            return "Privacy Policy"
        case .termsOfUse:
            return "Terms of Use"
        }
    }

    var resourceName: String {
        switch self {
        case .privacyPolicy:
            return "PrivacyPolicy"
        case .termsOfUse:
            return "TermsOfUse"
        }
    }
}

struct LegalView: View {
    let document: LegalDocument

    @State private var renderedText: AttributedString = AttributedString("Loading...")

    var body: some View {
        ScrollView {
            Text(renderedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            renderedText = await loadDocument()
        }
    }

    private func loadDocument() async -> AttributedString {
        guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: "md", subdirectory: "Legal") else {
            return AttributedString("Document unavailable in this build.")
        }

        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            if let attributed = try? AttributedString(markdown: markdown) {
                return attributed
            }
            return AttributedString(markdown)
        } catch {
            return AttributedString("Unable to load legal document.")
        }
    }
}
