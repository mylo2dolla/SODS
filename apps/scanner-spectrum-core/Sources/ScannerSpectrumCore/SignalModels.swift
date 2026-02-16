import Foundation

public struct SignalFrame: Decodable, Hashable, Sendable {
    public let t: Int
    public let source: String
    public let nodeID: String
    public let deviceID: String
    public let channel: Int
    public let frequency: Int
    public let rssi: Double
    public let x: Double?
    public let y: Double?
    public let z: Double?
    public let color: FrameColor
    public let glow: Double?
    public let persistence: Double
    public let velocity: Double?
    public let confidence: Double
    public let strengthInferred: Bool?

    enum CodingKeys: String, CodingKey {
        case t, source, channel, frequency, rssi, x, y, z, color, glow, persistence, velocity, confidence
        case strengthInferred = "strength_inferred"
        case nodeID = "node_id"
        case deviceID = "device_id"
    }

    public init(
        t: Int,
        source: String,
        nodeID: String,
        deviceID: String,
        channel: Int,
        frequency: Int,
        rssi: Double,
        x: Double?,
        y: Double?,
        z: Double?,
        color: FrameColor,
        glow: Double?,
        persistence: Double,
        velocity: Double?,
        confidence: Double,
        strengthInferred: Bool? = nil
    ) {
        self.t = t
        self.source = source
        self.nodeID = nodeID
        self.deviceID = deviceID
        self.channel = channel
        self.frequency = frequency
        self.rssi = rssi
        self.x = x
        self.y = y
        self.z = z
        self.color = color
        self.glow = glow
        self.persistence = persistence
        self.velocity = velocity
        self.confidence = confidence
        self.strengthInferred = strengthInferred
    }
}

public struct FrameColor: Decodable, Hashable, Sendable {
    public let h: Double
    public let s: Double
    public let l: Double

    public init(h: Double, s: Double, l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }
}

public struct CanonicalEvent: Decodable, Hashable, Sendable {
    public let id: String?
    public let recvTs: Int
    public let eventTs: String
    public let nodeID: String
    public let kind: String
    public let severity: String
    public let summary: String
    public let data: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case recvTs = "recv_ts"
        case eventTs = "event_ts"
        case nodeID = "node_id"
        case kind
        case severity
        case summary
        case data
    }

    public init(id: String?, recvTs: Int, eventTs: String, nodeID: String, kind: String, severity: String, summary: String, data: [String: JSONValue]) {
        self.id = id
        self.recvTs = recvTs
        self.eventTs = eventTs
        self.nodeID = nodeID
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.data = data
    }
}

public struct NormalizedEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let recvTs: Date?
    public let eventTs: Date?
    public let nodeID: String
    public let kind: String
    public let severity: String
    public let summary: String
    public let data: [String: JSONValue]
    public let deviceID: String?
    public let signal: SignalMeta

    public init(from canonical: CanonicalEvent) {
        data = canonical.data
        kind = canonical.kind
        nodeID = canonical.nodeID
        severity = canonical.severity
        summary = canonical.summary
        recvTs = Date(timeIntervalSince1970: TimeInterval(canonical.recvTs) / 1000)
        eventTs = DateParser.parse(canonical.eventTs)
        let strength = SignalMeta.extractStrength(from: data)
        let channel = SignalMeta.extractChannel(from: data)
        let tags = SignalMeta.tags(from: kind)
        deviceID = SignalMeta.deviceID(from: data, kind: kind, nodeID: nodeID)
        signal = SignalMeta(strength: strength, channel: channel, tags: tags)
        if let id = canonical.id, !id.isEmpty {
            self.id = id
        } else {
            self.id = NormalizedEvent.deriveID(node: nodeID, kind: kind, ts: eventTs ?? recvTs, data: data)
        }
    }

    public init(localNodeID: String, kind: String, summary: String, data: [String: JSONValue], deviceID: String?, eventTs: Date = Date()) {
        self.nodeID = localNodeID
        self.kind = kind
        self.severity = "info"
        self.summary = summary
        self.data = data
        self.eventTs = eventTs
        self.recvTs = eventTs
        self.deviceID = deviceID
        let strength = SignalMeta.extractStrength(from: data)
        let channel = SignalMeta.extractChannel(from: data)
        let tags = SignalMeta.tags(from: kind)
        self.signal = SignalMeta(strength: strength, channel: channel, tags: tags)
        self.id = NormalizedEvent.deriveID(node: localNodeID, kind: kind, ts: eventTs, data: data)
    }

    public func dataValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = data[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static func deriveID(node: String, kind: String, ts: Date?, data: [String: JSONValue]) -> String {
        let base = "\(node)|\(kind)|\(ts?.timeIntervalSince1970 ?? 0)"
        let hash = data.map { "\($0.key)=\($0.value.stringValue ?? "")" }.sorted().joined(separator: "|")
        return "derived-\(base.hashValue)-\(hash.hashValue)"
    }
}

public struct SignalMeta: Hashable, Sendable {
    public let strength: Double?
    public let channel: String?
    public let tags: [String]

    public init(strength: Double?, channel: String?, tags: [String]) {
        self.strength = strength
        self.channel = channel
        self.tags = tags
    }

    public static func extractStrength(from data: [String: JSONValue]) -> Double? {
        let keys = ["rssi", "RSSI", "signal", "strength", "dbm", "level"]
        for key in keys {
            guard let value = data[key] else { continue }
            if let number = value.doubleValue {
                return number
            }
            if let string = value.stringValue, let number = Double(string) {
                return number
            }
        }
        return nil
    }

    public static func extractChannel(from data: [String: JSONValue]) -> String? {
        let keys = ["channel", "ch", "wifi_channel", "ble_channel"]
        for key in keys {
            if let value = data[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    public static func deviceID(from data: [String: JSONValue], kind: String, nodeID: String) -> String? {
        let lowerKind = kind.lowercased()
        let keys = [
            "target_id", "targetId", "target", "target_node", "targetNode", "to",
            "device_id", "deviceId", "device",
            "addr", "address",
            "mac", "mac_address",
            "bssid",
            "ble_addr"
        ]
        for key in keys {
            if let value = data[key]?.stringValue, !value.isEmpty {
                if kind.contains("ble") {
                    return value.hasPrefix("ble:") ? value : "ble:\(value)"
                }
                return value
            }
        }
        if lowerKind.contains("tool") || lowerKind.contains("action") || lowerKind.contains("command") || lowerKind.contains("runbook") || lowerKind.contains("cmd") {
            if nodeID != "unknown" {
                return "node:\(nodeID)"
            }
        }
        if nodeID != "unknown" {
            return "node:\(nodeID)"
        }
        return nil
    }

    public static func tags(from kind: String) -> [String] {
        let lowerKind = kind.lowercased()
        var tags: [String] = []
        if lowerKind.contains("ble") { tags.append("ble") }
        if lowerKind.contains("wifi") { tags.append("wifi") }
        if lowerKind.contains("node") { tags.append("node") }
        if lowerKind.contains("rf") || lowerKind.contains("sdr") { tags.append("rf") }
        if lowerKind.contains("error") { tags.append("error") }
        if lowerKind.contains("tool") || lowerKind.contains("action") || lowerKind.contains("command") || lowerKind.contains("runbook") || lowerKind.contains("cmd") {
            tags.append("tool")
        }
        return tags
    }
}

public enum JSONValue: Hashable, Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y", "on"].contains(lowered) {
                return true
            }
            if ["false", "0", "no", "n", "off"].contains(lowered) {
                return false
            }
            return nil
        case .number(let value):
            if value == 1 { return true }
            if value == 0 { return false }
            return nil
        default:
            return nil
        }
    }
}

public enum DateParser {
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let parsed = iso8601WithFractionalSeconds.date(from: string) {
            return parsed
        }
        return iso8601Fallback.date(from: string)
    }
}
