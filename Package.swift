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
        .library(
            name: "RawLabNativeTypes",
            type: .static,
            targets: ["RawLabNativeTypes"]
        ),
        .library(
            name: "RawLabNative",
            type: .static,
            targets: ["RawLabNative"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSony2Fuji",
            path: "lutools/include/sony2fuji/ffi"
        ),
        .target(
            name: "RawLabKit",
            path: "Shared/RawLabKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RawLabNativeTypes",
            dependencies: ["RawLabKit", "CSony2Fuji"],
            path: "Shared/RawLabNativeTypes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RawLabNative",
            dependencies: ["RawLabKit", "RawLabNativeTypes", "CSony2Fuji"],
            path: "Shared/RawLabNative",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RawLabKitTests",
            dependencies: ["RawLabKit", "RawLabNativeTypes"],
            path: "tests/RawLabKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
