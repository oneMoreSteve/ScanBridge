// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanBridge",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // Linked into the iOS app.
        .library(name: "ScanBridge", targets: ["ScanBridge"]),
        // Run on the Mac while debugging in the iOS Simulator: `swift run scanbridge-host`.
        .executable(name: "scanbridge-host", targets: ["ScanBridgeHost"]),
    ],
    targets: [
        .target(name: "ScanBridgeCore"),
        .target(
            name: "ScanBridge",
            dependencies: ["ScanBridgeCore"]
        ),
        .executableTarget(
            name: "ScanBridgeHost",
            dependencies: ["ScanBridgeCore"]
        ),
        .testTarget(
            name: "ScanBridgeCoreTests",
            dependencies: ["ScanBridgeCore"]
        ),
        .testTarget(
            name: "ScanBridgeTests",
            dependencies: ["ScanBridge"]
        ),
        .testTarget(
            name: "ScanBridgeHostTests",
            dependencies: ["ScanBridgeHost"]
        ),
    ]
)
