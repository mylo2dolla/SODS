import Foundation

public enum SignalRenderKind: String, CaseIterable, Sendable {
    case ble
    case wifi
    case node
    case tool
    case error
    case generic

    public static func from(event: NormalizedEvent) -> SignalRenderKind {
        let kind = event.kind.lowercased()
        if kind.contains("ble") { return .ble }
        if kind.contains("wifi") || kind.contains("net") || kind.contains("host") { return .wifi }
        if kind.contains("node") { return .node }
        if kind.contains("tool") || kind.contains("action") || kind.contains("command") || kind.contains("runbook") || kind.contains("cmd") || event.signal.tags.contains("tool") {
            return .tool
        }
        if kind.contains("error") || event.signal.tags.contains("error") {
            return .error
        }
        return .generic
    }

    public static func from(source: String) -> SignalRenderKind {
        let source = source.lowercased()
        if source.contains("ble") { return .ble }
        if source.contains("wifi") || source.contains("net") || source.contains("host") { return .wifi }
        if source.contains("node") { return .node }
        if source.contains("tool") || source.contains("action") || source.contains("command") { return .tool }
        if source.contains("error") { return .error }
        return .generic
    }

    public var label: String {
        switch self {
        case .ble: return "BLE"
        case .wifi: return "Wi-Fi"
        case .node: return "Node"
        case .tool: return "Action"
        case .error: return "Error"
        case .generic: return "Signal"
        }
    }
}

public enum SignalColor {
    public static func deviceColor(id: String, saturation: Double = 0.65, brightness: Double = 0.9) -> PlatformColor {
        let hue = stableHue(for: id)
        let s = max(0.2, min(1.0, saturation))
        let b = max(0.2, min(1.0, brightness))
        return PlatformColorSupport.fromHSB(h: hue, s: s, b: b)
    }

    public static func kindAccent(kind: String, channel: String? = nil) -> PlatformColor {
        let kind = kind.lowercased()
        let channelNumber = Int(channel ?? "")
        if kind.contains("ble") {
            return PlatformColorSupport.fromHSB(h: 0.54, s: 0.9, b: 1.0)
        }
        if kind.contains("wifi") || kind.contains("net") || kind.contains("host") {
            if let channelNumber, channelNumber > 0, channelNumber <= 14 {
                return PlatformColorSupport.fromHSB(h: 0.32, s: 0.9, b: 0.98)
            }
            return PlatformColorSupport.fromHSB(h: 0.64, s: 0.85, b: 0.98)
        }
        if kind.contains("rf") || kind.contains("sdr") {
            return PlatformColorSupport.fromHSB(h: 0.9, s: 0.85, b: 0.98)
        }
        if kind.contains("node") {
            return PlatformColorSupport.fromHSB(h: 0.03, s: 0.9, b: 0.98)
        }
        if kind.contains("tool") || kind.contains("action") || kind.contains("command") || kind.contains("runbook") || kind.contains("cmd") {
            return PlatformColorSupport.fromHSB(h: 0.78, s: 0.85, b: 0.95)
        }
        if kind.contains("error") {
            return PlatformColorSupport.fromHSB(h: 0.0, s: 0.95, b: 1.0)
        }
        return PlatformColorSupport.fromHSB(h: 0.1, s: 0.75, b: 0.95)
    }

    public static func renderKindAccent(renderKind: SignalRenderKind, channel: String? = nil) -> PlatformColor {
        switch renderKind {
        case .ble:
            return kindAccent(kind: "ble.seen", channel: channel)
        case .wifi:
            return kindAccent(kind: "wifi.status", channel: channel)
        case .node:
            return kindAccent(kind: "node.heartbeat", channel: channel)
        case .tool:
            return kindAccent(kind: "tool", channel: channel)
        case .error:
            return kindAccent(kind: "error", channel: channel)
        case .generic:
            return kindAccent(kind: "signal", channel: channel)
        }
    }

    public static func typeFirstColor(
        renderKind: SignalRenderKind,
        deviceID: String,
        channel: String? = nil,
        deviceBlend: Double = 0.22,
        strength: Double? = nil,
        saturation: Double? = nil,
        brightness: Double? = nil
    ) -> PlatformColor {
        let base = renderKindAccent(renderKind: renderKind, channel: channel)
        let tint = deviceColor(id: deviceID, saturation: 0.62, brightness: 0.92)
        let blended = PlatformColorSupport.mix(base, tint, ratio: deviceBlend)
        let resolved: PlatformColor
        if let strength {
            resolved = strengthLuminanceBoost(
                blended,
                strength: strength,
                floor: brightness == nil ? 0.48 : 0.42
            )
        } else {
            resolved = blended
        }
        return applyTone(resolved, saturation: saturation, brightness: brightness)
    }

    public static func strengthLuminanceBoost(_ color: PlatformColor, strength: Double, floor: Double = 0.45) -> PlatformColor {
        let hsba = PlatformColorSupport.hsba(color)
        let clampedStrength = max(0.0, min(1.0, strength))
        let baseline = max(0.2, min(1.0, floor))
        let targetBrightness = baseline + ((1.0 - baseline) * clampedStrength)
        let resolvedBrightness = max(0.2, min(1.0, (hsba.b * 0.42) + (targetBrightness * 0.58)))
        return PlatformColorSupport.fromHSB(h: hsba.h, s: hsba.s, b: resolvedBrightness, a: hsba.a)
    }

    private static func applyTone(_ color: PlatformColor, saturation: Double?, brightness: Double?) -> PlatformColor {
        guard saturation != nil || brightness != nil else { return color }
        let hsba = PlatformColorSupport.hsba(color)
        let sat = max(0.2, min(1.0, saturation ?? hsba.s))
        let bright = max(0.2, min(1.0, brightness ?? hsba.b))
        return PlatformColorSupport.fromHSB(h: hsba.h, s: sat, b: bright, a: hsba.a)
    }

    public static func stableHue(for string: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Double(hash % 360) / 360.0
    }
}
