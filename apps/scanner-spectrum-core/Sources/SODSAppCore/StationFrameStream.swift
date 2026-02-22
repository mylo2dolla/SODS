import Foundation
import ScannerSpectrumCore

public struct StationFrameEnvelope: Decodable, Hashable, Sendable {
    public let t: Int64?
    public let frames: [SignalFrame]
}

public final class StationFrameStream {
    private let session: URLSession
    private let webSocketURL: URL
    private let authToken: String?
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared, authToken: String? = nil) throws {
        self.session = session
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: "/ws/frames", relativeTo: baseURL)?.absoluteURL else {
            throw StationClientError.invalidBaseURL
        }

        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        if components?.scheme == "https" {
            components?.scheme = "wss"
        } else {
            components?.scheme = "ws"
        }

        guard let webSocketURL = components?.url else {
            throw StationClientError.invalidBaseURL
        }

        self.webSocketURL = webSocketURL
    }

    public func stream() -> AsyncThrowingStream<StationFrameEnvelope, Error> {
        AsyncThrowingStream { continuation in
            var request = URLRequest(url: webSocketURL)
            if let token = authToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            task.resume()

            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .data(let rawData):
                            data = rawData
                        case .string(let text):
                            data = Data(text.utf8)
                        @unknown default:
                            continue
                        }

                        let envelope = try decoder.decode(StationFrameEnvelope.self, from: data)
                        continuation.yield(envelope)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                receiveTask.cancel()
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }
}
