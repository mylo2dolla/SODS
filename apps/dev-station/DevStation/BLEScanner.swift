import Foundation
import ScannerSpectrumCore

// DevStation now consumes the shared ScannerSpectrumCore BLE scanner.
typealias BLEScanner = ScannerSpectrumCore.BLEScanner

@MainActor
extension BLEScanner {
    static func configureDevStationLogging(_ logStore: LogStore? = nil) {
        let sink = logStore ?? .shared
        BLEScanner.shared.configureLogger { level, message in
            switch level {
            case .info:
                sink.log(.info, message)
            case .warn:
                sink.log(.warn, message)
            case .error:
                sink.log(.error, message)
            }
        }
    }
}
