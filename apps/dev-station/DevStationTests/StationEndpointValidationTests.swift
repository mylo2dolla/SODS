import XCTest
@testable import DevStation

final class StationEndpointValidationTests: XCTestCase {
    func testProbeRecognizesStationStatusEnvelope() async {
        let baseURL = "http://127.0.0.1:9123"
        let fetcher = makeFetcher([
            "\(baseURL)/api/status": .success(.init(
                statusCode: 200,
                data: jsonData([
                    "station": ["ok": true],
                    "logger": ["ok": true],
                ])
            )),
        ])

        let result = await StationEndpointResolver.probeStationAPI(baseURL: baseURL, fetcher: fetcher)
        XCTAssertEqual(result, .stationOK)
    }

    func testProbeRejectsKnownNonStationService() async {
        let baseURL = "http://192.168.8.114:9123"
        let fetcher = makeFetcher([
            "\(baseURL)/api/status": .success(.init(statusCode: 404, data: Data())),
            "\(baseURL)/health": .success(.init(
                statusCode: 200,
                data: jsonData([
                    "ok": true,
                    "service": "strangelab-token",
                ])
            )),
        ])

        let result = await StationEndpointResolver.probeStationAPI(baseURL: baseURL, fetcher: fetcher)
        XCTAssertEqual(result, .nonStationService(serviceName: "strangelab-token"))
    }

    func testProbeMarksEndpointUnreachableWhenNoEndpointsRespond() async {
        let baseURL = "http://10.0.0.9:9123"
        let connectionError = URLError(.cannotConnectToHost)
        let fetcher = makeFetcher([
            "\(baseURL)/api/status": .failure(connectionError),
            "\(baseURL)/health": .failure(connectionError),
        ])

        let result = await StationEndpointResolver.probeStationAPI(baseURL: baseURL, fetcher: fetcher)
        XCTAssertEqual(result, .unreachable)
    }

    func testProbeMarksInvalidResponseWhenStatusPayloadIsMalformed() async {
        let baseURL = "http://127.0.0.1:9123"
        let fetcher = makeFetcher([
            "\(baseURL)/api/status": .success(.init(
                statusCode: 200,
                data: jsonData([
                    "foo": "bar",
                ])
            )),
            "\(baseURL)/health": .success(.init(
                statusCode: 200,
                data: jsonData([
                    "ok": true,
                ])
            )),
        ])

        let result = await StationEndpointResolver.probeStationAPI(baseURL: baseURL, fetcher: fetcher)
        XCTAssertEqual(result, .invalidResponse)
    }

    func testStartViewResolverAcceptsScanningAliases() {
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("scan"), .scanning)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("scanning"), .scanning)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("scanners"), .scanning)
    }

    func testStartViewResolverAcceptsAnalyzerAliases() {
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("analyzer"), .spectral)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("spectrum"), .spectral)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("spectral"), .spectral)
    }

    func testStartViewResolverAcceptsSystemManagerAliases() {
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("system"), .systemManager)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("taskmanager"), .systemManager)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("ram"), .systemManager)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("system-manager"), .systemManager)
    }

    func testStartViewResolverMatchesDisplayLabelsAndNormalizedLabels() {
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("Dashboard"), .dashboard)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("All Hosts"), .allHosts)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("all_hosts"), .allHosts)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("BLE-Discovery"), .ble)
        XCTAssertEqual(DevStationViewModeResolver.resolveStartView("System Manager"), .systemManager)
        XCTAssertNil(DevStationViewModeResolver.resolveStartView("definitely-not-a-view"))
    }

    private func makeFetcher(
        _ responses: [String: Result<StationEndpointResolver.ProbeHTTPResponse, Error>]
    ) -> StationEndpointResolver.ProbeFetcher {
        { url in
            guard let result = responses[url.absoluteString] else {
                throw URLError(.resourceUnavailable)
            }
            switch result {
            case .success(let response):
                return response
            case .failure(let error):
                throw error
            }
        }
    }

    private func jsonData(_ json: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }
}
