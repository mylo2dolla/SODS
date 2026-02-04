import Foundation
import Darwin

struct ONVIFDiscovery {
    static func discover(timeout: TimeInterval, log: ((LogLevel, String) -> Void)? = nil) async -> [OnvifDiscoveryResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                log?(.info, "WS-Discovery started (timeout \(String(format: "%.1f", timeout))s)")
                let results = discoverSync(timeout: timeout, log: log)
                log?(.info, "WS-Discovery finished: found \(results.count) device(s)")
                continuation.resume(returning: results)
            }
        }
    }

    private static func discoverSync(timeout: TimeInterval, log: ((LogLevel, String) -> Void)?) -> [OnvifDiscoveryResult] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return [] }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var ttl: UInt8 = 2
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(0).bigEndian
        bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
        var bindSockaddr = sockaddr()
        memcpy(&bindSockaddr, &bindAddr, MemoryLayout<sockaddr_in>.size)
        if withUnsafePointer(to: &bindSockaddr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) != 0 {
            return []
        }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = in_port_t(3702).bigEndian
        destAddr.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))

        let messageID = UUID().uuidString
        let probe = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\"
            xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\"
            xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\"
            xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">
            <e:Header>
                <w:MessageID>uuid:\(messageID)</w:MessageID>
                <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
                <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
            </e:Header>
            <e:Body>
                <d:Probe>
                    <d:Types>dn:NetworkVideoTransmitter</d:Types>
                </d:Probe>
            </e:Body>
        </e:Envelope>
        """

        let probeData = probe.data(using: .utf8) ?? Data()
        let sent = probeData.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(socketFD, buffer.baseAddress, buffer.count, 0, destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent < 0 {
            return []
        }

        let deadline = Date().addingTimeInterval(timeout)
        var resultsByIP: [String: OnvifDiscoveryResult] = [:]

        while Date() < deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let timeoutMs = Int32(remaining * 1000)
            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, timeoutMs)
            if ready <= 0 { break }
            if (pfd.revents & Int16(POLLIN)) == 0 { continue }

            var buffer = [UInt8](repeating: 0, count: 65535)
            var senderAddr = sockaddr_in()
            var senderLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { bufferPtr in
                withUnsafeMutablePointer(to: &senderAddr) { senderPtr in
                    senderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                        recvfrom(socketFD, bufferPtr.baseAddress, bufferPtr.count, 0, addrPtr, &senderLen)
                    }
                }
            }

            if received <= 0 { continue }

            let data = Data(buffer.prefix(received))
            guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                continue
            }

            let ip = ipString(from: senderAddr.sin_addr)
            let xaddrs = extractTag("XAddrs", from: xml).map { parseXAddrs($0) } ?? []
            let types = extractTag("Types", from: xml)
            let scopes = extractTag("Scopes", from: xml)

            if var existing = resultsByIP[ip] {
                let mergedXAddrs = Set(existing.xaddrs).union(xaddrs)
                existing = OnvifDiscoveryResult(
                    ip: ip,
                    xaddrs: Array(mergedXAddrs).sorted(),
                    types: existing.types ?? types,
                    scopes: existing.scopes ?? scopes
                )
                resultsByIP[ip] = existing
            } else {
                resultsByIP[ip] = OnvifDiscoveryResult(ip: ip, xaddrs: xaddrs, types: types, scopes: scopes)
            }
        }

        let results = resultsByIP.values.sorted { $0.ip < $1.ip }
        for result in results {
            log?(.info, "WS-Discovery found device \(result.ip)")
        }
        return results
    }

    private static func ipString(from addr: in_addr) -> String {
        var addrCopy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ptr = inet_ntop(AF_INET, &addrCopy, &buffer, socklen_t(INET_ADDRSTRLEN))
        if ptr != nil {
            return String(cString: buffer)
        }
        return ""
    }

    private static func extractTag(_ tag: String, from xml: String) -> String? {
        let lower = xml.lowercased()
        let startToken = "<\(tag.lowercased())>"
        let endToken = "</\(tag.lowercased())>"
        guard let startRange = lower.range(of: startToken) else { return nil }
        guard let endRange = lower.range(of: endToken, range: startRange.upperBound..<lower.endIndex) else { return nil }
        return String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseXAddrs(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }
}
