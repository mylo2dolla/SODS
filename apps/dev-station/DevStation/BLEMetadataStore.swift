import Foundation
import AppKit
import CoreBluetooth
import ScannerSpectrumCore

// DevStation now consumes the shared ScannerSpectrumCore BLE metadata store.
typealias BLEMetadataStore = ScannerSpectrumCore.BLEMetadataStore
typealias BLECompanyInfo = ScannerSpectrumCore.BLECompanyInfo
typealias BLEAssignedUUIDInfo = ScannerSpectrumCore.BLEAssignedUUIDInfo
typealias BLEMetadataHealth = ScannerSpectrumCore.BLEMetadataHealth

extension BLEMetadataStore {
    func reload(log: LogStore) {
        reload(logger: makeBLEMetadataLogger(log))
    }

    func importCompanyMap(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                let ok = self.importCompanyMap(from: url, logger: makeBLEMetadataLogger(log))
                if !ok {
                    log.log(.error, "BLE company map import failed from \(url.path)")
                }
            }
        }
    }

    func importAssignedNumbersMap(log: LogStore) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                let ok = self.importAssignedNumbersMap(from: url, logger: makeBLEMetadataLogger(log))
                if !ok {
                    log.log(.error, "BLE assigned-numbers import failed from \(url.path)")
                }
            }
        }
    }

    func logStats(log: LogStore) {
        logStats(logger: makeBLEMetadataLogger(log))
    }
}

private func makeBLEMetadataLogger(_ logStore: LogStore) -> ScannerCoreLogger {
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

extension Notification.Name {
    static let bleMetadataUpdated = BLEMetadataStore.metadataUpdatedNotification
}
