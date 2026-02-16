import Foundation

public enum ScannerCoreLogLevel: String, Sendable {
    case info
    case warn
    case error
}

public typealias ScannerCoreLogger = @Sendable (_ level: ScannerCoreLogLevel, _ message: String) -> Void

@inline(__always)
func coreLog(_ logger: ScannerCoreLogger?, _ level: ScannerCoreLogLevel, _ message: @autoclosure () -> String) {
    logger?(level, message())
}
