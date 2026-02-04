import Foundation
import Darwin

struct SSDPDiscoveryResult: Hashable {
    let ip: String
    let st: String?
    let usn: String?
    let location: String?
    let server: String?
    let cacheControl: String?
}

enum SSDPDiscovery {
    static func discover(
        timeout: TimeInterval,
        log: ((LogLevel, String) -> Void)? = nil,
        onResult: ((SSDPDiscoveryResult) -> Void)? = nil
    ) async -> [SSDPDiscoveryResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var results: [SSDPDiscoveryResult] = []
                let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard sock >= 0 else {
                    continuation.resume(returning: [])
                    return
                }

                var reuse: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(0).bigEndian
                addr.sin_addr = in_addr(s_addr: INADDR_ANY)

                let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                    let sockPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
                    return Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
                if bindResult != 0 {
                    close(sock)
                    continuation.resume(returning: [])
                    return
                }

                let request =
                "M-SEARCH * HTTP/1.1\r\n" +
                "HOST: 239.255.255.250:1900\r\n" +
                "MAN: \"ssdp:discover\"\r\n" +
                "MX: 1\r\n" +
                "ST: ssdp:all\r\n" +
                "\r\n"

                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = in_port_t(1900).bigEndian
                dest.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))

                let sent = request.withCString { cstr -> ssize_t in
                    let dataPtr = UnsafeRawPointer(cstr)
                    return withUnsafePointer(to: &dest) { ptr in
                        let sockPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
                        return sendto(sock, dataPtr, strlen(cstr), 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                if sent <= 0 {
                    log?(.warn, "SSDP send failed")
                }

                var timeoutValue = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

                let start = Date()
                var buffer = [UInt8](repeating: 0, count: 2048)

                while Date().timeIntervalSince(start) < timeout {
                    var from = sockaddr_in()
                    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let received = withUnsafeMutablePointer(to: &from) { ptr -> ssize_t in
                        let sockPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
                        return buffer.withUnsafeMutableBytes { bytes in
                            guard let base = bytes.baseAddress else { return -1 }
                            return recvfrom(sock, base, bytes.count, 0, sockPtr, &fromLen)
                        }
                    }

                    if received > 0 {
                        let data = Data(buffer[0..<received])
                        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                            let ip = ipString(from: from)
                            let headers = parseHeaders(text)
                            let result = SSDPDiscoveryResult(
                                ip: ip,
                                st: headers["st"],
                                usn: headers["usn"],
                                location: headers["location"],
                                server: headers["server"],
                                cacheControl: headers["cache-control"]
                            )
                            results.append(result)
                            if let onResult = onResult {
                                Task { @MainActor in
                                    onResult(result)
                                }
                            }
                        }
                    }
                }

                close(sock)
                continuation.resume(returning: results)
            }
        }
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                headers[String(key)] = String(value)
            }
        }
        return headers
    }

    private static func ipString(from addr: sockaddr_in) -> String {
        var address = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ptr = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        if let ptr = ptr {
            return String(cString: ptr)
        }
        return ""
    }
}
