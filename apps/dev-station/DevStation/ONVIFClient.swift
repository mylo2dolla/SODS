import Foundation

struct ONVIFRtspResult {
    let rtspURI: String?
    let requiresAuth: Bool
    let errorMessage: String?
}

private struct ONVIFSoapResult {
    let xml: String?
    let requiresAuth: Bool
    let errorMessage: String?
}

final class ONVIFClient {
    private let semaphore: AsyncSemaphore
    private let timeout: TimeInterval = 4.0

    init(semaphore: AsyncSemaphore) {
        self.semaphore = semaphore
    }

    func fetchRtspURI(xaddrs: [String], username: String?, password: String?) async -> ONVIFRtspResult {
        let normalizedXAddrs = xaddrs.filter { !$0.isEmpty }
        guard let firstXAddr = normalizedXAddrs.first else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "No ONVIF XAddrs available.")
        }

        let mediaCandidates = normalizedXAddrs.filter { $0.lowercased().contains("media") && !$0.lowercased().contains("device") }
        let deviceServiceURL = URL(string: firstXAddr)

        let mediaServiceURL: URL?
        if let candidate = mediaCandidates.first, let url = URL(string: candidate) {
            mediaServiceURL = url
        } else if let deviceServiceURL = deviceServiceURL {
            let mediaResult = await getMediaXAddr(deviceServiceURL: deviceServiceURL, username: username, password: password)
            if mediaResult.requiresAuth {
                return mediaResult
            }
            if let xaddr = mediaResult.rtspURI, let url = URL(string: xaddr) {
                mediaServiceURL = url
            } else {
                return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "Media service XAddr not found.")
            }
        } else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "Invalid ONVIF XAddr URL.")
        }

        guard let mediaServiceURL = mediaServiceURL else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "Unable to resolve Media service URL.")
        }

        let profileResult = await getFirstProfileToken(mediaServiceURL: mediaServiceURL, username: username, password: password)
        if profileResult.requiresAuth {
            return profileResult
        }
        guard let profileToken = profileResult.rtspURI else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "No ONVIF media profiles available.")
        }

        let streamResult = await getStreamUri(mediaServiceURL: mediaServiceURL, profileToken: profileToken, username: username, password: password)
        return streamResult
    }

    private func getMediaXAddr(deviceServiceURL: URL, username: String?, password: String?) async -> ONVIFRtspResult {
        let body = """
        <tds:GetCapabilities xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\">
            <tds:Category>All</tds:Category>
        </tds:GetCapabilities>
        """

        let action = "http://www.onvif.org/ver10/device/wsdl/GetCapabilities"
        let response = await sendSOAPRequest(url: deviceServiceURL, action: action, body: body, username: username, password: password)
        if response.requiresAuth {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: true, errorMessage: response.errorMessage)
        }
        guard let xml = response.xml else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: response.errorMessage ?? "GetCapabilities returned no data.")
        }
        if let xaddr = extractTag("XAddr", from: xml) {
            return ONVIFRtspResult(rtspURI: xaddr, requiresAuth: false, errorMessage: nil)
        }
        return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "GetCapabilities response missing Media XAddr.")
    }

    private func getFirstProfileToken(mediaServiceURL: URL, username: String?, password: String?) async -> ONVIFRtspResult {
        let body = """
        <trt:GetProfiles xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" />
        """

        let action = "http://www.onvif.org/ver10/media/wsdl/GetProfiles"
        let response = await sendSOAPRequest(url: mediaServiceURL, action: action, body: body, username: username, password: password)
        if response.requiresAuth {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: true, errorMessage: response.errorMessage)
        }
        guard let xml = response.xml else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: response.errorMessage ?? "GetProfiles returned no data.")
        }

        if let token = extractFirstProfileToken(from: xml) {
            return ONVIFRtspResult(rtspURI: token, requiresAuth: false, errorMessage: nil)
        }

        return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "No profile token found.")
    }

    private func getStreamUri(mediaServiceURL: URL, profileToken: String, username: String?, password: String?) async -> ONVIFRtspResult {
        let body = """
        <trt:GetStreamUri xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\">
            <trt:StreamSetup>
                <tt:Stream>RTP-Unicast</tt:Stream>
                <tt:Transport>
                    <tt:Protocol>RTSP</tt:Protocol>
                </tt:Transport>
            </trt:StreamSetup>
            <trt:ProfileToken>\(profileToken)</trt:ProfileToken>
        </trt:GetStreamUri>
        """

        let action = "http://www.onvif.org/ver10/media/wsdl/GetStreamUri"
        let response = await sendSOAPRequest(url: mediaServiceURL, action: action, body: body, username: username, password: password)
        if response.requiresAuth {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: true, errorMessage: response.errorMessage)
        }
        guard let xml = response.xml else {
            return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: response.errorMessage ?? "GetStreamUri returned no data.")
        }

        if let uri = extractTag("Uri", from: xml) {
            return ONVIFRtspResult(rtspURI: uri, requiresAuth: false, errorMessage: nil)
        }

        return ONVIFRtspResult(rtspURI: nil, requiresAuth: false, errorMessage: "No RTSP URI found in response.")
    }

    private func sendSOAPRequest(url: URL, action: String, body: String, username: String?, password: String?) async -> ONVIFSoapResult {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let envelope = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">
            <s:Body>
                \(body)
            </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = envelope.data(using: .utf8)
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(action, forHTTPHeaderField: "SOAPAction")
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout

        let delegate = AuthURLSessionDelegate(username: username, password: password)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    return ONVIFSoapResult(xml: nil, requiresAuth: true, errorMessage: "HTTP 401 Unauthorized")
                }
                if !(200..<300).contains(http.statusCode) {
                    return ONVIFSoapResult(xml: nil, requiresAuth: false, errorMessage: "HTTP \(http.statusCode)")
                }
            }
            if let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                return ONVIFSoapResult(xml: xml, requiresAuth: false, errorMessage: nil)
            }
            return ONVIFSoapResult(xml: nil, requiresAuth: false, errorMessage: "Response decoding failed.")
        } catch {
            return ONVIFSoapResult(xml: nil, requiresAuth: false, errorMessage: error.localizedDescription)
        }
    }

    private func extractTag(_ tag: String, from xml: String) -> String? {
        let lower = xml.lowercased()
        let startToken = "<\(tag.lowercased())>"
        let endToken = "</\(tag.lowercased())>"
        guard let startRange = lower.range(of: startToken) else { return nil }
        guard let endRange = lower.range(of: endToken, range: startRange.upperBound..<lower.endIndex) else { return nil }
        return String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractFirstProfileToken(from xml: String) -> String? {
        let patterns = [
            "Profiles[^>]*token=\\\"([^\\\"]+)\\\"",
            "Profile[^>]*token=\\\"([^\\\"]+)\\\""
        ]
        for pattern in patterns {
            if let token = regexFirstMatch(pattern: pattern, in: xml) {
                return token
            }
        }
        return nil
    }

    private func regexFirstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
