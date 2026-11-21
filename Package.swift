// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RawLabKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "RawLabKit",
            type: .static,
            targets: ["RawLabKit"]
        ),
    ],
    targets: [
        .target(
            name: "RawLabKit",
            path: "Shared/RawLabKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RawLabKitTests",
            dependencies: ["RawLabKit"],
            path: "tests/RawLabKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
