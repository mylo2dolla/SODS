import Foundation
import AppKit
import ScannerSpectrumCore

// DevStation now consumes the shared ScannerSpectrumCore OUI store.
typealias OUIStore = ScannerSpectrumCore.OUIStore

extension OUIStore {
    nonisolated func loadPreferredIfNeeded(log: LogStore) async {
        await loadPreferredIfNeeded(logger: makeOUIStoreLogger(log))
    }

    nonisolated func reloadPreferred(log: LogStore) async -> Int? {
        await reloadPreferred(logger: makeOUIStoreLogger(log))
    }

    nonisolated func importFromOpenPanel(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    let ok = await self.importFromURL(url, logger: makeOUIStoreLogger(log))
                    if !ok {
                        log.log(.error, "OUI import failed from \(url.path)")
                    }
                }
            }
        }
    }
}

private func makeOUIStoreLogger(_ logStore: LogStore) -> ScannerCoreLogger {
    { level, message in
        switch level {
        case .info:
            logStore.log(.info, message)
        case .warn:
            logStore.log(.warn, message)
        case .error:
            logStore.log(.error, message)
        }
    }
}
