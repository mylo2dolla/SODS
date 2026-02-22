// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "scanner-spectrum-core",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ScannerSpectrumCore",
            targets: ["ScannerSpectrumCore"]
        ),
        .library(
            name: "SODSAppCore",
            targets: ["SODSAppCore"]
        )
    ],
    targets: [
        .target(
            name: "ScannerSpectrumCore",
            resources: [
                .process("Resources/OUI.txt"),
                .process("Resources/BLECompanyIDs.txt"),
                .process("Resources/BLEAssignedNumbers.txt"),
                .process("Resources/BLEServiceUUIDs.txt")
            ]
        ),
        .target(
            name: "SODSAppCore",
            dependencies: ["ScannerSpectrumCore"]
        ),
        .testTarget(
            name: "ScannerSpectrumCoreTests",
            dependencies: ["ScannerSpectrumCore"]
        )
    ]
)
