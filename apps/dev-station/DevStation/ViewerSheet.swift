import SwiftUI
import WebKit

struct ViewerSheet: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ModalHeaderView(title: "Viewer", onBack: nil, onClose: onClose)
            WebView(url: url)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(minWidth: 800, minHeight: 600)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }
}

struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
