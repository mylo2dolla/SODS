import XCTest
@testable import ScannerSpectrumCore

final class SynthesizerTests: XCTestCase {
    func testLocalSynthesizerDedupesBLEAndHostsAcrossPasses() {
        let now = Date(timeIntervalSince1970: 1_706_000_000)
        let synthesizer = SpectrumLocalEventSynthesizer(localNodeID: "ios-test-node")

        let ble = makePeripheral(now: now)
        let host = makeHost()
        let onvif = makeOnvifDevice()

        let first = synthesizer.synthesize(
            blePeripherals: [ble],
            hosts: [host],
            devices: [onvif],
            now: now
        )
        XCTAssertEqual(first.events.count, 3)
        XCTAssertEqual(first.frames.count, 3)
        XCTAssertEqual(Set(first.events.map(\.kind)), Set(["ble.seen", "wifi.host", "node.onvif"]))
        XCTAssertEqual(first.frames.first(where: { $0.source == "lan.scan" })?.strengthInferred, true)
        XCTAssertEqual(first.frames.first(where: { $0.source == "ble.scan" })?.strengthInferred, false)

        let second = synthesizer.synthesize(
            blePeripherals: [ble],
            hosts: [host],
            devices: [onvif],
            now: now
        )
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.kind, "node.onvif")
        XCTAssertEqual(second.frames.count, 2)
        XCTAssertEqual(Set(second.frames.map(\.source)), Set(["ble.scan", "onvif.discovery"]))
    }

    func testNormalizedEventTransformsSignalAndDeviceFields() {
        let canonical = CanonicalEvent(
            id: nil,
            recvTs: 1_706_000_123_000,
            eventTs: "2024-01-26T10:00:00Z",
            nodeID: "node-a",
            kind: "wifi.scan",
            severity: "info",
            summary: "wifi",
            data: [
                "rssi": .string("-42"),
                "channel": .string("6"),
                "mac": .string("AA:BB:CC:DD:EE:FF"),
            ]
        )
        let normalized = NormalizedEvent(from: canonical)

        XCTAssertEqual(normalized.signal.strength, -42)
        XCTAssertEqual(normalized.signal.channel, "6")
        XCTAssertEqual(normalized.deviceID, "AA:BB:CC:DD:EE:FF")
        XCTAssertTrue(normalized.signal.tags.contains("wifi"))
        XCTAssertEqual(
            SignalMeta.deviceID(from: [:], kind: "tool.run", nodeID: "node-a"),
            "node:node-a"
        )
    }

    private func makePeripheral(now: Date) -> BLEPeripheral {
        let fingerprint = BLEAdFingerprint(
            localName: "Beacon",
            isConnectable: true,
            txPower: nil,
            serviceUUIDs: ["37"],
            manufacturerCompanyID: nil,
            manufacturerCompanyName: nil,
            manufacturerAssignmentDate: nil,
            manufacturerDataPrefixHex: nil,
            beaconHint: nil,
            servicesDecoded: [],
            unknownServices: []
        )
        return BLEPeripheral(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Beacon",
            rssi: -51,
            smoothedRSSI: -51,
            rssiHistory: [],
            serviceUUIDs: ["180D"],
            manufacturerDataHex: nil,
            fingerprint: fingerprint,
            fingerprintID: "fingerprint-a",
            bleConfidence: BLEConfidence(score: 86, level: .high, reasons: ["unit-test"]),
            lastSeen: now,
            provenance: nil
        )
    }

    private func makeHost() -> HostEntry {
        HostEntry(
            id: "host-192.168.1.20",
            ip: "192.168.1.20",
            isAlive: true,
            openPorts: [443, 554],
            hostname: "camera.local",
            macAddress: "00:11:22:33:44:55",
            vendor: "Vendor",
            vendorConfidenceScore: 80,
            vendorConfidenceReasons: ["oui"],
            hostConfidence: HostConfidence(score: 77, level: .high, reasons: ["alive", "ports"]),
            ssdpServer: nil,
            ssdpLocation: nil,
            ssdpST: nil,
            ssdpUSN: nil,
            bonjourServices: [],
            httpStatus: 200,
            httpServer: "nginx",
            httpAuth: nil,
            httpTitle: "Camera",
            provenance: nil
        )
    }

    private func makeOnvifDevice() -> Device {
        Device(
            id: "onvif-192.168.1.30",
            ip: "192.168.1.30",
            openPorts: [80],
            httpTitle: nil,
            macAddress: "AA:AA:AA:AA:AA:AA",
            vendor: "Vendor",
            hostConfidence: HostConfidence(score: 70, level: .medium, reasons: ["onvif"]),
            vendorConfidenceScore: 72,
            vendorConfidenceReasons: ["oui"],
            discoveredViaOnvif: true,
            onvifXAddrs: [],
            onvifTypes: nil,
            onvifScopes: nil,
            onvifRtspURI: nil,
            onvifRequiresAuth: false,
            onvifLastError: nil,
            username: "",
            password: "",
            rtspProbeInProgress: false,
            rtspProbeResults: [],
            bestRtspURI: nil,
            lastRtspProbeSummary: nil
        )
    }
}
