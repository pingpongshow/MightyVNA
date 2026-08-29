// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MightyVNA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MightyVNA", targets: ["MightyVNA"]),
        .library(name: "VNACore", targets: ["VNACore"])
    ],
    targets: [
        // Pure-logic core: DSP, calibration, serial I/O, device drivers.
        .target(
            name: "VNACore",
            path: "Sources/VNACore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // SwiftUI application layer.
        .executableTarget(
            name: "MightyVNA",
            dependencies: ["VNACore"],
            path: "Sources/MightyVNA",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "VNACoreTests",
            dependencies: ["VNACore"],
            path: "Tests/VNACoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
