// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SODSScannerMonetizationLogic",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SODSScannerMonetizationLogic",
            targets: ["SODSScannerMonetizationLogic"]
        ),
    ],
    targets: [
        .target(
            name: "SODSScannerMonetizationLogic",
            path: "SODSScanneriOS/Monetization",
            exclude: [
                "SubscriptionCache.swift",
                "SubscriptionManager.swift",
            ],
            sources: [
                "SubscriptionModels.swift",
            ]
        ),
        .testTarget(
            name: "SODSScannerMonetizationLogicTests",
            dependencies: ["SODSScannerMonetizationLogic"],
            path: "Tests/SODSScannerMonetizationLogicTests"
        ),
    ]
)
