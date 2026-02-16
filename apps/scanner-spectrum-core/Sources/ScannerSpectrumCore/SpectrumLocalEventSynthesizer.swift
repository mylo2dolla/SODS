import Foundation

public final class SpectrumLocalEventSynthesizer {
    private var emittedBLEEventIDs: Set<String> = []
    private var emittedHostEventIDs: Set<String> = []
    private var lastTrim: Date = .distantPast
    public let localNodeID: String

    public init(localNodeID: String = "local-ios") {
        self.localNodeID = localNodeID
    }

    public func synthesize(
        blePeripherals: [BLEPeripheral],
        hosts: [HostEntry],
        devices: [Device],
        now: Date = Date()
    ) -> (events: [NormalizedEvent], frames: [SignalFrame]) {
        trimCachesIfNeeded(now: now)

        var events: [NormalizedEvent] = []
        var frames: [SignalFrame] = []

        for peripheral in blePeripherals {
            let summaryName = peripheral.name ?? peripheral.fingerprint.manufacturerCompanyName ?? "BLE device"
            let eventData: [String: JSONValue] = [
                "rssi": .number(Double(peripheral.rssi)),
                "ble_channel": .string(peripheral.fingerprint.serviceUUIDs.first ?? "0"),
                "device_id": .string("ble:\(peripheral.id.uuidString)"),
                "name": .string(summaryName)
            ]
            let event = NormalizedEvent(
                localNodeID: localNodeID,
                kind: "ble.seen",
                summary: "BLE seen \(summaryName)",
                data: eventData,
                deviceID: "ble:\(peripheral.id.uuidString)",
                eventTs: peripheral.lastSeen
            )
            if emittedBLEEventIDs.insert(event.id).inserted {
                events.append(event)
            }

            let frame = makeFrame(
                event: event,
                source: "ble.scan",
                frequency: 2402,
                rssi: Double(peripheral.rssi),
                channel: Int(peripheral.fingerprint.serviceUUIDs.first ?? "37") ?? 37,
                confidence: Double(peripheral.bleConfidence.score) / 100.0,
                strengthInferred: false,
                now: now
            )
            frames.append(frame)
        }

        let activeHosts = hosts.filter { $0.isAlive }
        for host in activeHosts {
            let deviceID = "host:\(host.ip)"
            let key = "\(deviceID)-\(host.openPorts.sorted())-\(host.vendor ?? "")"
            if !emittedHostEventIDs.insert(key).inserted {
                continue
            }
            let eventData: [String: JSONValue] = [
                "device_id": .string(deviceID),
                "ip": .string(host.ip),
                "ports": .array(host.openPorts.map { .number(Double($0)) }),
                "vendor": .string(host.vendor ?? ""),
                "channel": .string(host.openPorts.contains(443) ? "5" : "2"),
                "strength_inferred": .bool(true)
            ]
            let event = NormalizedEvent(
                localNodeID: localNodeID,
                kind: "wifi.host",
                summary: "Host alive \(host.ip)",
                data: eventData,
                deviceID: deviceID,
                eventTs: now
            )
            events.append(event)

            let inferredRSSI = host.openPorts.contains(554) ? -48.0 : -58.0
            let frame = makeFrame(
                event: event,
                source: "lan.scan",
                frequency: host.openPorts.contains(443) ? 5200 : 2412,
                rssi: inferredRSSI,
                channel: host.openPorts.contains(443) ? 36 : 6,
                confidence: Double(max(host.hostConfidence.score, host.vendorConfidenceScore)) / 100.0,
                strengthInferred: true,
                now: now
            )
            frames.append(frame)
        }

        for device in devices where device.discoveredViaOnvif {
            let deviceID = "onvif:\(device.ip)"
            let event = NormalizedEvent(
                localNodeID: localNodeID,
                kind: "node.onvif",
                summary: "ONVIF device \(device.ip)",
                data: [
                    "device_id": .string(deviceID),
                    "ip": .string(device.ip),
                    "rssi": .number(-45),
                    "channel": .string("control"),
                    "strength_inferred": .bool(true)
                ],
                deviceID: deviceID,
                eventTs: now
            )
            events.append(event)
            frames.append(
                makeFrame(
                    event: event,
                    source: "onvif.discovery",
                    frequency: 5800,
                    rssi: -45,
                    channel: 149,
                    confidence: 0.82,
                    strengthInferred: true,
                    now: now
                )
            )
        }

        return (events, frames)
    }

    private func makeFrame(
        event: NormalizedEvent,
        source: String,
        frequency: Int,
        rssi: Double,
        channel: Int,
        confidence: Double,
        strengthInferred: Bool = false,
        now: Date
    ) -> SignalFrame {
        let kind = SignalRenderKind.from(event: event)
        let color = SignalColor.typeFirstColor(
            renderKind: kind,
            deviceID: event.deviceID ?? event.nodeID,
            channel: event.signal.channel
        )
        let hsba = PlatformColorSupport.hsba(color)
        let frameColor = FrameColor(h: hsba.h * 360, s: hsba.s, l: hsba.b)
        let t = Int(now.timeIntervalSince1970 * 1000)

        let layoutSeed = abs((event.deviceID ?? event.nodeID).hashValue)
        let nx = Double(layoutSeed % 100) / 100.0
        let ny = Double((layoutSeed / 100) % 100) / 100.0

        return SignalFrame(
            t: t,
            source: source,
            nodeID: localNodeID,
            deviceID: event.deviceID ?? event.nodeID,
            channel: channel,
            frequency: frequency,
            rssi: rssi,
            x: nx,
            y: ny,
            z: min(1.0, max(0.15, confidence)),
            color: frameColor,
            glow: min(1.0, max(0.25, confidence)),
            persistence: 0.9,
            velocity: nil,
            confidence: min(1.0, max(0.1, confidence)),
            strengthInferred: strengthInferred
        )
    }

    private func trimCachesIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastTrim) > 30 else { return }
        lastTrim = now
        if emittedBLEEventIDs.count > 2000 {
            emittedBLEEventIDs.removeAll(keepingCapacity: true)
        }
        if emittedHostEventIDs.count > 2000 {
            emittedHostEventIDs.removeAll(keepingCapacity: true)
        }
    }
}
