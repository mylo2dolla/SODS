import Foundation

public enum PlatformClientType: String, Codable, Sendable, CaseIterable {
    case ios
    case macos
}

public struct PlatformServiceCapabilities: Codable, Hashable, Sendable {
    public let scanner: Bool
    public let spectrum: Bool
    public let status: Bool
    public let nodes: Bool
    public let tools: Bool
    public let runbooks: Bool
    public let presets: Bool
    public let eventsRecent: Bool
    public let frameStream: Bool

    public let localStationProcess: Bool
    public let localFileReveal: Bool
    public let localShellExecution: Bool
    public let localUSBFlash: Bool

    public init(
        scanner: Bool,
        spectrum: Bool,
        status: Bool,
        nodes: Bool,
        tools: Bool,
        runbooks: Bool,
        presets: Bool,
        eventsRecent: Bool,
        frameStream: Bool,
        localStationProcess: Bool,
        localFileReveal: Bool,
        localShellExecution: Bool,
        localUSBFlash: Bool
    ) {
        self.scanner = scanner
        self.spectrum = spectrum
        self.status = status
        self.nodes = nodes
        self.tools = tools
        self.runbooks = runbooks
        self.presets = presets
        self.eventsRecent = eventsRecent
        self.frameStream = frameStream
        self.localStationProcess = localStationProcess
        self.localFileReveal = localFileReveal
        self.localShellExecution = localShellExecution
        self.localUSBFlash = localUSBFlash
    }

    public static let ios = PlatformServiceCapabilities(
        scanner: true,
        spectrum: true,
        status: true,
        nodes: true,
        tools: true,
        runbooks: true,
        presets: true,
        eventsRecent: true,
        frameStream: true,
        localStationProcess: false,
        localFileReveal: false,
        localShellExecution: false,
        localUSBFlash: false
    )

    public static let macos = PlatformServiceCapabilities(
        scanner: true,
        spectrum: true,
        status: true,
        nodes: true,
        tools: true,
        runbooks: true,
        presets: true,
        eventsRecent: true,
        frameStream: true,
        localStationProcess: true,
        localFileReveal: true,
        localShellExecution: true,
        localUSBFlash: true
    )
}

public struct FeatureCapabilityMatrix: Codable, Hashable, Sendable {
    public let client: PlatformClientType
    public let capabilities: PlatformServiceCapabilities

    public init(client: PlatformClientType, capabilities: PlatformServiceCapabilities) {
        self.client = client
        self.capabilities = capabilities
    }

    public static func localDefault(for client: PlatformClientType) -> FeatureCapabilityMatrix {
        switch client {
        case .ios:
            return FeatureCapabilityMatrix(client: .ios, capabilities: .ios)
        case .macos:
            return FeatureCapabilityMatrix(client: .macos, capabilities: .macos)
        }
    }
}

public struct AppCapabilitiesResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let client: PlatformClientType
    public let capabilities: PlatformServiceCapabilities

    public init(ok: Bool, client: PlatformClientType, capabilities: PlatformServiceCapabilities) {
        self.ok = ok
        self.client = client
        self.capabilities = capabilities
    }
}
