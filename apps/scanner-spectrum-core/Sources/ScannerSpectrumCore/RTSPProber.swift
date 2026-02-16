@preconcurrency import Foundation
@preconcurrency import Dispatch
import Network

public enum RTSPProber {
    private static let candidates: [String] = [
        "/",
        "/live",
        "/live.sdp",
        "/h264",
        "/h265",
        "/stream1",
        "/stream2",
        "/cam/realmonitor?channel=1&subtype=0",
        "/Streaming/Channels/101",
        "/Streaming/Channels/102",
        "/axis-media/media.amp",
        "/media/video1",
        "/ch0_0.h264",
        "/ch1/main/av_stream"
    ]

    public static func probe(
        ip: String,
        username: String,
        password: String,
        semaphore: AsyncSemaphore,
        log: ScannerCoreLogger? = nil
    ) async -> [RTSPProbeResult] {
        var results: [RTSPProbeResult] = []
        let baseHost = "rtsp://\(ip):554"

        let unauthURIs = candidates.map { path in
            baseHost + path
        }
        let authURIs: [String]
        if !username.isEmpty && !password.isEmpty {
            let userEscaped = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            let passEscaped = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            let authHost = "rtsp://\(userEscaped):\(passEscaped)@\(ip):554"
            authURIs = candidates.map { path in
                authHost + path
            }
        } else {
            authURIs = []
        }

        for uri in unauthURIs {
            await semaphore.wait()
            let result = await probeCandidate(uri: uri, authHeader: nil)
            await semaphore.signal()
            results.append(result)
            coreLog(log, result.success ? .info : .warn, "RTSP probe \(result.success ? "OK" : "FAIL") \(uri) status=\(result.statusCode.map(String.init) ?? "-")")
        }

        if !authURIs.isEmpty {
            let authHeader = basicAuthHeader(username: username, password: password)
            for uri in authURIs {
                await semaphore.wait()
                let result = await probeCandidate(uri: uri, authHeader: authHeader)
                await semaphore.signal()
                results.append(result)
                coreLog(log, result.success ? .info : .warn, "RTSP probe \(result.success ? "OK" : "FAIL") \(uri) status=\(result.statusCode.map(String.init) ?? "-")")
            }
        }

        return results
    }

    private static func probeCandidate(uri: String, authHeader: String?) async -> RTSPProbeResult {
        guard let components = URLComponents(string: uri), let host = components.host else {
            return RTSPProbeResult(uri: uri, statusCode: nil, server: nil, hasVideo: false, codecHints: [], success: false, error: "Invalid URI")
        }
        let port = UInt16(components.port ?? 554)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return RTSPProbeResult(uri: uri, statusCode: nil, server: nil, hasVideo: false, codecHints: [], success: false, error: "Invalid port")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let connected = await waitForReady(connection: connection, timeout: 1.0)
        if !connected {
            connection.cancel()
            return RTSPProbeResult(uri: uri, statusCode: nil, server: nil, hasVideo: false, codecHints: [], success: false, error: "Connect timeout")
        }

        let optionsRequest = buildRequest(method: "OPTIONS", uri: uri, cseq: 1, authHeader: authHeader, accept: nil)
        _ = await sendAndRead(connection: connection, request: optionsRequest, timeout: 1.5)

        let describeRequest = buildRequest(method: "DESCRIBE", uri: uri, cseq: 2, authHeader: authHeader, accept: "application/sdp")
        guard let responseData = await sendAndRead(connection: connection, request: describeRequest, timeout: 1.5) else {
            connection.cancel()
            return RTSPProbeResult(uri: uri, statusCode: nil, server: nil, hasVideo: false, codecHints: [], success: false, error: "No response")
        }

        let responseText = String(data: responseData, encoding: .utf8) ?? String(data: responseData, encoding: .isoLatin1) ?? ""
        let parsed = parseResponse(responseText)
        let sdp = parsed.body
        let hasVideo = sdp.contains("m=video")
        let codecHints = extractCodecs(from: sdp)
        let success = parsed.statusCode == 200 && hasVideo
        connection.cancel()

        return RTSPProbeResult(
            uri: uri,
            statusCode: parsed.statusCode,
            server: parsed.server,
            hasVideo: hasVideo,
            codecHints: codecHints,
            success: success,
            error: success ? nil : "RTSP describe failed"
        )
    }

    private static func buildRequest(method: String, uri: String, cseq: Int, authHeader: String?, accept: String?) -> Data {
        var lines: [String] = []
        lines.append("\(method) \(uri) RTSP/1.0")
        lines.append("CSeq: \(cseq)")
        lines.append("User-Agent: SODS")
        if let accept = accept {
            lines.append("Accept: \(accept)")
        }
        if let authHeader = authHeader {
            lines.append("Authorization: \(authHeader)")
        }
        lines.append("\r\n")
        let text = lines.joined(separator: "\r\n")
        return Data(text.utf8)
    }

    private static func basicAuthHeader(username: String, password: String) -> String {
        let token = "\(username):\(password)"
        let data = Data(token.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private static func waitForReady(connection: NWConnection, timeout: TimeInterval) async -> Bool {
        let finishState = LocalFinishState()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ success: Bool) {
                finishState.lock.lock()
                if finishState.finished {
                    finishState.lock.unlock()
                    return
                }
                finishState.finished = true
                finishState.lock.unlock()
                continuation.resume(returning: success)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    private static func sendAndRead(connection: NWConnection, request: Data, timeout: TimeInterval) async -> Data? {
        let sent = await send(connection: connection, data: request)
        guard sent else { return nil }
        return await readAvailable(connection: connection, timeout: timeout)
    }

    private static func send(connection: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private static func readAvailable(connection: NWConnection, timeout: TimeInterval) async -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            if let chunk = await receiveOnce(connection: connection, timeout: remaining) {
                buffer.append(chunk)
                if buffer.containsHeaderTerminator(), buffer.hasCompleteBody() {
                    break
                }
            } else {
                break
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private static func receiveOnce(connection: NWConnection, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            var didFinish = false
            let work = DispatchWorkItem {
                if !didFinish {
                    didFinish = true
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if didFinish { return }
                didFinish = true
                DispatchQueue.global(qos: .utility).async {
                    work.cancel()
                }
                if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func parseResponse(_ response: String) -> (statusCode: Int?, server: String?, body: String) {
        let parts = response.components(separatedBy: "\r\n\r\n")
        let headerText = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        var statusCode: Int?
        var server: String?

        let lines = headerText.components(separatedBy: "\r\n")
        if let statusLine = lines.first {
            let pieces = statusLine.split(separator: " ")
            if pieces.count >= 2 {
                statusCode = Int(pieces[1])
            }
        }
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("server:") {
                server = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            }
        }
        return (statusCode, server, body)
    }

    private static func extractCodecs(from sdp: String) -> [String] {
        var codecs: [String] = []
        let upper = sdp.uppercased()
        if upper.contains("H264") || upper.contains("H.264") {
            codecs.append("H264")
        }
        if upper.contains("H265") || upper.contains("H.265") || upper.contains("HEVC") {
            codecs.append("H265")
        }
        return codecs
    }
}

private extension Data {
    func containsHeaderTerminator() -> Bool {
        range(of: Data("\r\n\r\n".utf8)) != nil
    }

    func hasCompleteBody() -> Bool {
        guard let headerRange = range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = self[..<headerRange.lowerBound]
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength: Int?
        for line in headerText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                contentLength = Int(value ?? "")
            }
        }
        guard let length = contentLength else { return true }
        let bodyStart = headerRange.upperBound
        let bodyLength = count - bodyStart
        return bodyLength >= length
    }
}

private final class LocalFinishState {
    var finished = false
    let lock = NSLock()
}
