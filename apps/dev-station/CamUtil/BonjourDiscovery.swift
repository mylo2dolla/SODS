import Foundation
import Network
import Darwin

struct BonjourDiscoveryResult: Hashable {
    let ip: String?
    let service: BonjourService
}

@MainActor
final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var results: [BonjourDiscoveryResult] = []
    private var continuation: CheckedContinuation<[BonjourDiscoveryResult], Never>?
    private var onResult: ((BonjourDiscoveryResult) -> Void)?

    static func discover(
        timeout: TimeInterval,
        log: ((LogLevel, String) -> Void)? = nil,
        onResult: ((BonjourDiscoveryResult) -> Void)? = nil
    ) async -> [BonjourDiscoveryResult] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let discovery = BonjourDiscovery()
                discovery.onResult = onResult
                discovery.continuation = continuation
                discovery.startBrowsing(timeout: timeout, log: log)
            }
        }
    }

    private func startBrowsing(timeout: TimeInterval, log: ((LogLevel, String) -> Void)?) {
        let types = ["_http._tcp.", "_https._tcp.", "_rtsp._tcp.", "_onvif._tcp.", "_ipp._tcp.", "_airplay._tcp.", "_hap._tcp.", "_printer._tcp.", "_smb._tcp."]
        for type in types {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.stopBrowsing(log: log)
        }
    }

    private func stopBrowsing(log: ((LogLevel, String) -> Void)?) {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        services.forEach { $0.stop() }
        services.removeAll()
        continuation?.resume(returning: results)
        continuation = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = resolveIPv4(sender.addresses)
        let port = sender.port
        let txtRecords = sender.txtRecordData().flatMap { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let txt = txtRecords.map { key, value -> String in
            if let string = String(data: value, encoding: .utf8), !string.isEmpty {
                return "\(key)=\(string)"
            }
            return key
        }.sorted()

        let service = BonjourService(name: sender.name, type: sender.type, port: port, txt: txt)
        let result = BonjourDiscoveryResult(ip: ip, service: service)
        results.append(result)
        onResult?(result)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        sender.stop()
    }

    private func resolveIPv4(_ addresses: [Data]?) -> String? {
        guard let addresses = addresses else { return nil }
        for data in addresses {
            let ip = data.withUnsafeBytes { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                let sockAddr = base.assumingMemoryBound(to: sockaddr.self)
                if sockAddr.pointee.sa_family == sa_family_t(AF_INET) {
                    let addrIn = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var address = addrIn.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let ptr = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
                    if let ptr = ptr {
                        return String(cString: ptr)
                    }
                }
                return nil
            }
            if let ip = ip {
                return ip
            }
        }
        return nil
    }
}
